"""Start-up steps for LLM Wiki's API on Railway, run before the API listens.

    1. wait for Postgres, Supabase Auth (through the gateway) and object storage
    2. apply LLM Wiki's database migrations, each once, in order, recorded with a checksum
    3. install the signup gate and write the signup policy and per-user quotas from the variables
    4. create the bucket and let the web app's origin read signed links from it
    5. create the owner account

LLM Wiki's hosted service applies its migrations with the Supabase CLI and creates its bucket by hand;
a one-click template has neither. Everything here is idempotent and runs on every start.

Uses only what the API image already ships (asyncpg, httpx, aioboto3). Secrets come from the environment
and are never printed; the owner's e-mail is masked.
"""

import asyncio
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import sys
import time
from pathlib import Path

import aioboto3
import asyncpg
import httpx
from botocore.exceptions import ClientError

TAG = "[llmwiki-api]"
MIGRATIONS = Path(os.environ.get("LLMWIKI_MIGRATIONS_DIR", "/opt/llmwiki-railway/migrations"))
GATE_SQL = Path(os.environ.get("LLMWIKI_GATE_SQL", "/opt/llmwiki-railway/gate.sql"))
NONCE_KEY = "llmwiki_railway_bootstrap_nonce"


def log(msg: str) -> None:
    print(f"{TAG} {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"{TAG} WARNING: {msg}", file=sys.stderr, flush=True)


def die(msg: str) -> "None":
    print(f"{TAG} FATAL: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, "").strip()
    if value:
        return value
    if default is None:
        die(f"missing required variable: {name}")
    return default


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def mint(role: str, secret: str) -> str:
    # Byte-identical to lib/mint-supabase-keys.mjs and the gateway's mint-keys.pl: Kong compares the
    # apikey header as a string.
    header = b64url(b'{"alg":"HS256","typ":"JWT"}')
    claims = b64url(('{"role":"%s","iss":"supabase","iat":1735689600,"exp":2082758400}' % role).encode())
    unsigned = f"{header}.{claims}"
    return f"{unsigned}.{b64url(hmac.new(secret.encode(), unsigned.encode(), hashlib.sha256).digest())}"


DEADLINE = time.monotonic() + int(os.environ.get("LLMWIKI_READY_TIMEOUT", "600"))


async def wait_for(what: str, probe) -> None:
    last = None
    while True:
        try:
            if await probe():
                log(f"{what} is ready")
                return
        except Exception as exc:  # noqa: BLE001 -- any failure means "not yet"
            last = type(exc).__name__
        if time.monotonic() > DEADLINE:
            die(f"{what} did not become ready in time{f' ({last})' if last else ''}")
        await asyncio.sleep(3)


# --------------------------------------------------------------------------------------------------
# database
# --------------------------------------------------------------------------------------------------
LEDGER = """
create schema if not exists llmwiki_railway;
revoke all on schema llmwiki_railway from public;
create table if not exists llmwiki_railway.migrations (
  name text primary key,
  sha256 text not null,
  applied_at timestamptz not null default now()
);
"""


async def migrate(conn: asyncpg.Connection) -> None:
    files = sorted(MIGRATIONS.glob("*.sql"), key=lambda p: p.name.encode())
    if not files:
        die(f"no migrations found in {MIGRATIONS}")
    await conn.execute(LEDGER)
    recorded = {r["name"]: r["sha256"] for r in await conn.fetch("select name, sha256 from llmwiki_railway.migrations")}
    if not recorded and await conn.fetchval("select to_regclass('public.knowledge_bases') is not null"):
        die("the database already holds LLM Wiki tables that this template did not create; refusing to "
            "apply migrations over them. Restore into an empty database, or record the applied migrations "
            "in llmwiki_railway.migrations first.")
    applied = 0
    for path in files:
        body = path.read_bytes()
        digest = hashlib.sha256(body).hexdigest()
        if path.name in recorded:
            if recorded[path.name] != digest:
                warn(f"migration {path.name} changed upstream after it was applied here; it is not run again")
            continue
        async with conn.transaction():
            await conn.execute(body.decode())
            await conn.execute("insert into llmwiki_railway.migrations (name, sha256) values ($1, $2)", path.name, digest)
        applied += 1
        log(f"applied migration {path.name}")
    log(f"database schema current ({len(files)} migrations, {applied} applied now)")


def signup_policy() -> tuple[str, list[str]]:
    mode = env("LLMWIKI_SIGNUP_MODE", "closed")
    if mode not in ("closed", "open"):
        die("LLMWIKI_SIGNUP_MODE must be closed or open")
    entries = []
    for raw in re.split(r"[\s,]+", os.environ.get("LLMWIKI_ALLOWED_SIGNUPS", "")):
        entry = raw.strip().lower()
        if not entry:
            continue
        if not re.fullmatch(r"[^@\s]*@[^@\s]+", entry):
            die(f'LLMWIKI_ALLOWED_SIGNUPS: "{entry}" is neither an e-mail address nor @domain')
        if entry not in entries:
            entries.append(entry)
    return mode, entries


def positive_int(name: str, default: int, ceiling: int) -> int:
    raw = env(name, str(default))
    if not raw.isdigit() or not 0 < int(raw) <= ceiling:
        die(f"{name} must be a whole number between 1 and {ceiling}")
    return int(raw)


async def policy(conn: asyncpg.Connection) -> None:
    await conn.execute(GATE_SQL.read_text())
    mode, entries = signup_policy()
    pages = positive_int("LLMWIKI_PAGE_LIMIT", 100_000, 2_000_000_000)
    storage = positive_int("LLMWIKI_STORAGE_LIMIT_BYTES", 10 * 1024**3, 2**62)
    async with conn.transaction():
        await conn.execute(
            "insert into llmwiki_railway.settings (key, value) values ('signup_mode', $1) "
            "on conflict (key) do update set value = excluded.value, updated_at = now()", mode)
        await conn.execute("delete from llmwiki_railway.signup_allowlist")
        for entry in entries:
            await conn.execute("insert into llmwiki_railway.signup_allowlist (entry) values ($1)", entry)
        # LLM Wiki keeps each account's limits on its users row; the column defaults are its hosted free
        # tier. On a self-hosted instance the variables decide, for new and existing accounts alike.
        await conn.execute(f"alter table public.users alter column page_limit set default {pages}")
        await conn.execute(f"alter table public.users alter column storage_limit_bytes set default {storage}")
        await conn.execute("update public.users set page_limit = $1, storage_limit_bytes = $2 "
                           "where page_limit <> $1 or storage_limit_bytes <> $2", pages, storage)
    log(f"signup: {mode}, {len(entries)} allowlist entr{'y' if len(entries) == 1 else 'ies'}; "
        f"per-user limits: {pages} pages, {storage} bytes")


# --------------------------------------------------------------------------------------------------
# object storage
# --------------------------------------------------------------------------------------------------
async def storage() -> None:
    bucket = env("S3_BUCKET")
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket):
        die("S3_BUCKET must be a valid bucket name")
    origin = env("APP_URL").rstrip("/")
    session = aioboto3.Session()

    async def reachable() -> bool:
        async with session.client("s3") as s3:
            try:
                await s3.head_bucket(Bucket=bucket)
            except ClientError as exc:
                status = exc.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
                if status == 404:
                    await s3.create_bucket(Bucket=bucket)
                    log(f"created bucket {bucket}")
                elif status == 403:
                    die("object storage refused the credentials (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)")
                else:
                    raise
        return True

    await wait_for("object storage", reachable)
    async with session.client("s3") as s3:
        # The browser loads documents (PDF pages, images) from signed links on the storage domain. Only the
        # web app's own origin may read them from script; nothing may write from a browser.
        await s3.put_bucket_cors(Bucket=bucket, CORSConfiguration={"CORSRules": [{
            "AllowedOrigins": [origin],
            "AllowedMethods": ["GET", "HEAD"],
            "AllowedHeaders": ["*"],
            "ExposeHeaders": ["Content-Length", "Content-Range", "Accept-Ranges", "ETag"],
            "MaxAgeSeconds": 3600,
        }]})
    log(f"bucket {bucket} ready; signed links readable from the web app's origin")


# --------------------------------------------------------------------------------------------------
# owner
# --------------------------------------------------------------------------------------------------
async def owner(conn: asyncpg.Connection, gateway: str, service_key: str) -> None:
    email = env("OWNER_EMAIL").lower()
    password = env("OWNER_PASSWORD")
    if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", email):
        die("OWNER_EMAIL must be an e-mail address; it is what the owner signs in with")
    if len(password) < 12:
        die("OWNER_PASSWORD must be at least 12 characters")
    masked = re.sub(r"^(.).*(@.*)$", r"\1***\2", email)
    headers = {"apikey": service_key, "Authorization": f"Bearer {service_key}"}

    async with httpx.AsyncClient(base_url=gateway, headers=headers, timeout=30) as http:
        async def call(method: str, path: str, body: dict | None = None) -> dict:
            res = await http.request(method, path, json=body)
            if res.status_code >= 300:
                code = ""
                try:
                    data = res.json()
                    code = f" ({data.get('error_code') or data.get('code') or data.get('error') or ''})"
                except ValueError:
                    pass
                raise RuntimeError(f"{method} {path.split('?')[0]} -> HTTP {res.status_code}{code}")
            return res.json() if res.content else {}

        # The claim is "an account with OWNER_EMAIL exists", so an allowlisted account can never stop the
        # owner from being created, and a redeploy never undoes a password change.
        existing = await conn.fetchval("select id::text from auth.users where lower(email) = $1", email)
        if existing:
            if os.environ.get("LLMWIKI_RESET_OWNER_PASSWORD", "").strip() == "true":
                await call("PUT", f"/auth/v1/admin/users/{existing}", {"password": password})
                warn("owner password reset from OWNER_PASSWORD. Remove LLMWIKI_RESET_OWNER_PASSWORD now, or every "
                     "redeploy will reset it again.")
            else:
                log("owner account exists from an earlier start; leaving it alone")
            return

        # The gate admits the owner by a one-time nonce: only its hash is stored, the insert consumes it,
        # and it is removed again whatever happens.
        nonce = secrets.token_hex(32)
        await conn.execute(
            "insert into llmwiki_railway.settings (key, value) values ('bootstrap_nonce_sha256', $1) "
            "on conflict (key) do update set value = excluded.value, updated_at = now()",
            hashlib.sha256(nonce.encode()).hexdigest())
        try:
            user = await call("POST", "/auth/v1/admin/users", {
                "email": email, "password": password, "email_confirm": True,
                "user_metadata": {NONCE_KEY: nonce},
            })
        finally:
            await conn.execute("delete from llmwiki_railway.settings where key = 'bootstrap_nonce_sha256'")
        if not user.get("id"):
            die("Supabase Auth did not return the new owner")
        log(f"owner account created for {masked}")


async def main() -> None:
    for name in ("JWT_SECRET", "DATABASE_URL", "SUPABASE_URL", "SUPABASE_INTERNAL_URL", "APP_URL", "API_URL",
                 "OWNER_EMAIL", "OWNER_PASSWORD", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "S3_BUCKET",
                 "AWS_ENDPOINT_URL_S3", "CONVERTER_URL", "CONVERTER_SECRET"):
        env(name)
    jwt_secret = env("JWT_SECRET")
    if len(jwt_secret) < 32:
        die("JWT_SECRET must be at least 32 characters")
    if len(env("CONVERTER_SECRET")) < 32:
        die("CONVERTER_SECRET must be at least 32 characters")
    anon, service = mint("anon", jwt_secret), mint("service_role", jwt_secret)
    gateway = env("SUPABASE_INTERNAL_URL").rstrip("/")
    dsn = env("DATABASE_URL")

    async def db_ok() -> bool:
        conn = await asyncpg.connect(dsn, timeout=5)
        await conn.close()
        return True

    async def auth_ok() -> bool:
        async with httpx.AsyncClient(timeout=5) as http:
            return (await http.get(f"{gateway}/auth/v1/health", headers={"apikey": anon})).status_code == 200

    await wait_for("the database", db_ok)
    # Supabase Auth creates the auth schema on its first start; the migrations add a trigger to auth.users.
    await wait_for("the gateway and Supabase Auth", auth_ok)
    await wait_for("the auth schema", lambda: _auth_schema(dsn))

    conn = await asyncpg.connect(dsn, timeout=10)
    try:
        await migrate(conn)
        await policy(conn)
        await storage()
        await owner(conn, gateway, service)
    finally:
        await conn.close()


async def _auth_schema(dsn: str) -> bool:
    conn = await asyncpg.connect(dsn, timeout=5)
    try:
        return bool(await conn.fetchval("select to_regclass('auth.users') is not null"))
    finally:
        await conn.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        die(f"start-up step failed: {type(exc).__name__}: {str(exc)[:300]}")
