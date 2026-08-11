-- ============================================================
-- GEM · 08 — unblock photo sync, and make automatic sync safe
-- Run AFTER 07_enum_parity.sql. Safe to re-run.
--
-- Two independent changes, both prerequisites:
--
--   1. The media policies assume every object is <org>/<event>/<file>. A
--      client photo belongs to a lead, which has no event, so the path has
--      to be <org>/leads/<lead>.jpg — and the policy's bare ::uuid cast on
--      the second segment raises 22P02 on the literal 'leads'. No lead photo
--      can be written until that cast is guarded.
--
--   2. Push is upsert-then-prune: it deletes any remote row the pushing
--      device doesn't have. Correct for a manual "make Supabase match this
--      device", destructive the moment it runs on a timer against two
--      devices. A compare-and-increment version turns that silent loss into
--      a refusal the app can act on.
-- ============================================================


-- ---------- 1 · a cast that denies instead of erroring ----------
-- A policy that raises cannot be caught by the caller: the whole statement
-- fails. Anything that isn't a uuid should simply not match.
create or replace function gem_uuid(t text)
returns uuid
language plpgsql
immutable
parallel safe
as $$
begin
  return t::uuid;
exception when others then
  return null;
end $$;

revoke execute on function gem_uuid(text) from public, anon;
grant  execute on function gem_uuid(text) to authenticated;


-- ---------- 2 · media policies, rewritten to tolerate lead paths ----------
-- Layout after this change:
--   <org_id>/<event_id>/<file>   event media — staff, plus that event's couple
--   <org_id>/leads/<lead_id>     client photos — staff only
drop policy if exists "gem media read"   on storage.objects;
drop policy if exists "gem media write"  on storage.objects;
drop policy if exists "gem media update" on storage.objects;
drop policy if exists "gem media delete" on storage.objects;

create policy "gem media read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'gem-media'
    and (
      gem_is_org_member(gem_uuid((storage.foldername(name))[1]))
      or (
        gem_uuid((storage.foldername(name))[2]) is not null
        and gem_is_event_client(gem_uuid((storage.foldername(name))[2]))
      )
    )
  );

create policy "gem media write"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'gem-media'
    and gem_is_org_member(gem_uuid((storage.foldername(name))[1]))
  );

create policy "gem media update"
  on storage.objects for update to authenticated
  using      (bucket_id = 'gem-media' and gem_is_org_member(gem_uuid((storage.foldername(name))[1])))
  with check (bucket_id = 'gem-media' and gem_is_org_member(gem_uuid((storage.foldername(name))[1])));

create policy "gem media delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'gem-media' and gem_is_org_member(gem_uuid((storage.foldername(name))[1])));


-- ---------- 3 · where a photo lives, once uploaded ----------
-- design_boards already has board_images.storage_path; leads gained
-- photo_path in file 06. Nothing further to add.


-- ---------- 4 · the sync guard ----------
alter table org_prefs add column if not exists sync_version bigint not null default 0;

-- Compare-and-increment, under a row lock, so two devices pushing at the same
-- moment cannot both believe they were first. The client sends the version it
-- last saw; a mismatch means someone else has written since, and the push is
-- refused rather than allowed to prune their work away.
create or replace function gem_claim_sync(p_org uuid, p_expect bigint)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare v bigint;
begin
  if not gem_has_org_role(p_org, array['owner','planner']::org_role[]) then
    raise exception 'Not permitted to sync this studio.' using errcode = '42501';
  end if;

  insert into org_prefs (org_id) values (p_org) on conflict (org_id) do nothing;
  select sync_version into v from org_prefs where org_id = p_org for update;

  -- p_expect null means "first push from this device, take what is there".
  if p_expect is not null and v <> p_expect then
    raise exception 'stale %', v using errcode = '55000';
  end if;

  update org_prefs set sync_version = sync_version + 1
   where org_id = p_org
   returning sync_version into v;
  return v;
end $$;

revoke execute on function gem_claim_sync(uuid, bigint) from public, anon;
grant  execute on function gem_claim_sync(uuid, bigint) to authenticated;


-- ---------- verify ----------
-- Expect every column true.
select
  (select count(*) from pg_proc where proname = 'gem_uuid')             = 1 as gem_uuid_fn,
  (select count(*) from pg_proc where proname = 'gem_claim_sync')       = 1 as claim_sync_fn,
  (select count(*) from information_schema.columns
     where table_name = 'org_prefs' and column_name = 'sync_version')   = 1 as sync_version_col,
  (select count(*) from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname like 'gem media%')                                = 4 as media_policies,
  gem_uuid('leads') is null                                                as bad_cast_is_null,
  gem_uuid('00000000-0000-0000-0000-000000000000') is not null              as good_cast_works;
