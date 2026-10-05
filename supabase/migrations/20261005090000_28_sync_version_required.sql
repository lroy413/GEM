-- ============================================================
-- GEM · 28 — a studio with history never accepts a push from a device
--            that has never seen it
-- Run AFTER 27_budget_envelope.sql. Safe to re-run.
--
-- The app has always carried this comment, in sbLooksReseeded():
--
--   "gem_claim_sync() cannot stop it, because that guard only refuses a
--    device with NO version at all."
--
-- It had the server backwards. Both gem_claim_sync and gem_commit_sync read:
--
--   if p_expect is not null and v <> p_expect then raise 'stale' ...
--
-- A null p_expect does not fail that test — it SKIPS it. So a device with no
-- stored version was not refused, it was waved through, and sbPush() prunes
-- every row its payload does not mention. A browser that evicted local storage
-- (Chrome does this under storage pressure, and "clear browsing data" does it
-- on request) left a device showing the seeded sample with no version to send,
-- which is exactly the shape of a push that replaces a studio with the demo
-- wedding. It has happened to two different people.
--
-- p_expect null has one legitimate meaning: the first push to a studio that
-- has no history. That is `sync_version = 0`, and it stays allowed. Against a
-- studio that HAS history, a device with no version must pull first — which is
-- what the app now does on its own, and what Settings › Connection › Pull does
-- on request.
--
-- The deliberate override is unaffected: "replace the studio with this device"
-- reads the current version and sends it, so it arrives as a versioned push
-- rather than a blank one. Loud stays possible; silent does not.
-- ============================================================

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

  -- No version, but this studio has history: this device has never seen the
  -- studio and must not replace it.
  if p_expect is null and coalesce(v,0) > 0 then
    raise exception 'This device has never synced with this studio — pull before pushing.'
      using errcode = '55001';
  end if;

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


create or replace function gem_commit_sync(p_org uuid, p_expect bigint)
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

  select sync_version into v from org_prefs where org_id = p_org for update;

  if p_expect is null and coalesce(v,0) > 0 then
    raise exception 'This device has never synced with this studio — pull before pushing.'
      using errcode = '55001';
  end if;

  -- Someone committed while this run was writing. Refusing here is the whole
  -- point: the version must never advance past a run that did not finish.
  if p_expect is not null and v <> p_expect then
    raise exception 'stale %', v using errcode = '55000';
  end if;

  update org_prefs
     set sync_version = sync_version + 1,
         sync_open_by = null,
         sync_open_at = null
   where org_id = p_org
   returning sync_version into v;
  return v;
end $$;

revoke execute on function gem_commit_sync(uuid, bigint) from public, anon;
grant  execute on function gem_commit_sync(uuid, bigint) to authenticated;
