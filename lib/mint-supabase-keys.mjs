// Mint the two Supabase API keys from the shared JWT secret.
//
// Self-hosted Supabase authenticates API calls with two HS256 JWTs, one for the `anon` role and one
// for `service_role`, both signed with JWT_SECRET. Railway can generate a random secret for a
// template but cannot sign a token with it, so every service that needs the keys derives them here
// at start-up instead of receiving them as variables.
//
// The claims are FIXED -- same issuer, same issued-at, same expiry, same key order -- so every
// container that runs this gets byte-identical tokens. That matters: Kong's key-auth compares the
// `apikey` header as a string, so an app and a gateway that minted "equivalent" tokens with
// different timestamps would reject each other. `images/kong/mint-keys.pl` reproduces these exact
// bytes, and `tests/static.sh` checks the two implementations agree.
//
// Usage: node mint-supabase-keys.mjs  -> prints `ANON_KEY=...` and `SERVICE_ROLE_KEY=...`
// The secret is read from the environment, never from argv.
import { createHmac } from "node:crypto";

const secret = process.env.JWT_SECRET ?? "";
if (secret.length < 32) {
  process.stderr.write("mint-supabase-keys: JWT_SECRET must be at least 32 characters\n");
  process.exit(2);
}

const b64url = (buf) =>
  Buffer.from(buf).toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");

const HEADER = '{"alg":"HS256","typ":"JWT"}';
const claims = (role) => `{"role":"${role}","iss":"supabase","iat":1735689600,"exp":2082758400}`;

function mint(role) {
  const unsigned = `${b64url(HEADER)}.${b64url(claims(role))}`;
  const sig = createHmac("sha256", secret).update(unsigned).digest();
  return `${unsigned}.${b64url(sig)}`;
}

process.stdout.write(`ANON_KEY=${mint("anon")}\nSERVICE_ROLE_KEY=${mint("service_role")}\n`);
