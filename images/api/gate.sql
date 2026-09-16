-- Who may create an account on this LLM Wiki instance, enforced by the database.
--
-- LLM Wiki signs people in with Supabase Auth, and Supabase Auth accepts any signup: the sign-up page
-- is linked from the login screen, and the gateway takes a signup posted to it directly. Every account
-- then gets its own wikis and upload quota on the deployer's database, storage and document converter.
--
-- This file puts the rule where every path to a new user converges, a BEFORE INSERT trigger on
-- auth.users (Google sign-in included). A new user is admitted when:
--
--   1. its user_metadata carries the one-time bootstrap nonce (the owner account, created by the
--      wrapper before the app listens; the nonce's hash is stored below and consumed by the insert)
--   2. the signup mode is 'open'
--   3. its e-mail address, or '@' and its domain, is on the signup allowlist
--
-- Everything else is refused. The mode and the allowlist are written on every start from
-- LLMWIKI_SIGNUP_MODE and LLMWIKI_ALLOWED_SIGNUPS, so the variables are the source of truth.
--
-- Idempotent; the api wrapper applies it on every start, after LLM Wiki's own migrations.

create schema if not exists llmwiki_railway;
revoke all on schema llmwiki_railway from public;

create table if not exists llmwiki_railway.settings (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);

create table if not exists llmwiki_railway.signup_allowlist (
  entry text primary key check (entry = lower(entry) and entry ~ '^[^@\s]*@[^@\s]+$')
);

create or replace function llmwiki_railway.gate_new_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_nonce text;
  v_email text := lower(coalesce(new.email, ''));
begin
  v_nonce := nullif(new.raw_user_meta_data ->> 'llmwiki_railway_bootstrap_nonce', '');
  if v_nonce is not null then
    new.raw_user_meta_data := new.raw_user_meta_data - 'llmwiki_railway_bootstrap_nonce';
    delete from llmwiki_railway.settings
    where key = 'bootstrap_nonce_sha256'
      and value = encode(sha256(convert_to(v_nonce, 'UTF8')), 'hex');
    if found then
      return new;
    end if;
  end if;

  if exists (select 1 from llmwiki_railway.settings where key = 'signup_mode' and value = 'open') then
    return new;
  end if;

  if v_email <> '' and exists (
    select 1 from llmwiki_railway.signup_allowlist
    where entry = v_email or entry = '@' || split_part(v_email, '@', 2)
  ) then
    return new;
  end if;

  raise exception 'Sign-up on this LLM Wiki instance is closed. Ask the owner to add your address.'
    using errcode = '42501';
end;
$$;

revoke all on function llmwiki_railway.gate_new_user() from public;

drop trigger if exists llmwiki_railway_gate_new_user on auth.users;
create trigger llmwiki_railway_gate_new_user
  before insert on auth.users
  for each row execute function llmwiki_railway.gate_new_user();

-- Supabase Auth writes a new user's metadata again right after the insert, from its in-memory copy, so
-- the nonce is also removed on update.
create or replace function llmwiki_railway.strip_gate_metadata()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.raw_user_meta_data ? 'llmwiki_railway_bootstrap_nonce' then
    new.raw_user_meta_data := new.raw_user_meta_data - 'llmwiki_railway_bootstrap_nonce';
  end if;
  return new;
end;
$$;

revoke all on function llmwiki_railway.strip_gate_metadata() from public;

drop trigger if exists llmwiki_railway_strip_gate_metadata on auth.users;
create trigger llmwiki_railway_strip_gate_metadata
  before update on auth.users
  for each row execute function llmwiki_railway.strip_gate_metadata();
