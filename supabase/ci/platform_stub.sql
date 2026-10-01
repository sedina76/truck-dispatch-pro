-- supabase/ci/platform_stub.sql
--
-- Minimal Supabase platform stand-in for a DISPOSABLE plain-PostgreSQL test
-- cluster (CI / local throwaway only). Lets migrations 0001..0119 apply on
-- plain PostgreSQL. Provides only what they reference: the anon /
-- authenticated / service_role roles, auth.users + auth.uid()/role()/jwt(),
-- storage.buckets/objects + storage.foldername(), an extensions schema with
-- pgcrypto, and a no-op cron schema (pg_cron is not installable here).
-- Never run against Supabase.

do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon')          then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role')  then create role service_role nologin bypassrls; end if;
end $$;
grant usage on schema public to anon, authenticated, service_role;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists btree_gist;
-- migrations call gen_random_uuid()/digest()/crypt() unqualified too
create extension if not exists pgcrypto;  -- no-op if already present
do $$ begin execute format('alter database %I set search_path = public, extensions', current_database()); end $$;
set search_path = public, extensions;

create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  instance_id uuid,
  aud text,
  role text,
  email text unique,
  encrypted_password text,
  email_confirmed_at timestamptz,
  raw_app_meta_data jsonb default '{}'::jsonb,
  raw_user_meta_data jsonb default '{}'::jsonb,
  phone text,
  last_sign_in_at timestamptz,
  banned_until timestamptz,
  deleted_at timestamptz,
  is_sso_user boolean default false,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;
create or replace function auth.role() returns text language sql stable as $$
  select coalesce(auth.jwt() ->> 'role', current_user::text)
$$;
create or replace function auth.email() returns text language sql stable as $$
  select auth.jwt() ->> 'email'
$$;
grant execute on all functions in schema auth to anon, authenticated, service_role;

create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role;
create table if not exists storage.buckets (
  id text primary key,
  name text not null unique,
  owner uuid,
  public boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  avif_autodetection boolean default false,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid,
  owner_id text,
  metadata jsonb,
  path_tokens text[] generated always as (string_to_array(name, '/')) stored,
  version text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  last_accessed_at timestamptz default now()
);
alter table storage.objects enable row level security;
create or replace function storage.foldername(name text) returns text[] language sql immutable as $$
  select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1]
$$;
create or replace function storage.filename(name text) returns text language sql immutable as $$
  select (string_to_array(name, '/'))[array_length(string_to_array(name, '/'), 1)]
$$;
create or replace function storage.extension(name text) returns text language sql immutable as $$
  select reverse(split_part(reverse(storage.filename(name)), '.', 1))
$$;
grant all on storage.buckets, storage.objects to authenticated, service_role;
grant select on storage.buckets, storage.objects to anon;

create schema if not exists cron;
create table if not exists cron.job (jobid bigserial primary key, jobname text unique, schedule text, command text);
create or replace function cron.schedule(job_name text, schedule text, command text) returns bigint language plpgsql as $$
declare v bigint;
begin
  insert into cron.job(jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid into v;
  return v;
end $$;
create or replace function cron.unschedule(job_name text) returns boolean language plpgsql as $$
begin delete from cron.job where jobname = job_name; return found; end $$;

do $$ begin if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then create publication supabase_realtime; end if; end $$;
