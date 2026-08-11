-- ============================================================
-- GEM · 09 — close the duplication hole, and let staff record both sides
-- Run AFTER 08_photos_and_sync.sql. Safe to re-run.
--
-- 1. gem_claim_sync treated "this device has never synced" as permission to
--    push into a populated studio. Two devices that each seeded their own
--    local copy therefore each held different uuids for the same records, and
--    the second push duplicated every table until it hit the first unique
--    constraint (invoices.number) and aborted mid-way. A device with no
--    version must pull before it can push.
--
-- 2. msg_staff_insert required sender_role = 'planner', so a planner could
--    never record the couple's side of a conversation — the app holds the
--    whole thread. Staff may now insert either role, still stamped with their
--    own user id; the client path stays strict.
-- ============================================================


-- ---------- 1 · a never-synced device must pull first ----------
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

  -- No version from the caller. That is only safe into an empty studio;
  -- otherwise this device has its own ids for records that already exist and
  -- a push would duplicate the lot.
  if p_expect is null then
    if v > 0 then
      raise exception 'unsynced %', v using errcode = '55000';
    end if;
  elsif v <> p_expect then
    raise exception 'stale %', v using errcode = '55000';
  end if;

  update org_prefs set sync_version = sync_version + 1
   where org_id = p_org
   returning sync_version into v;
  return v;
end $$;

revoke execute on function gem_claim_sync(uuid, bigint) from public, anon;
grant  execute on function gem_claim_sync(uuid, bigint) to authenticated;


-- ---------- 2 · staff may record either side of a thread ----------
-- sender_id is still forced to the inserting user, so authorship is never
-- forged; a 'client' message pushed by a planner is honestly the planner's
-- record of what was said. A couple in the portal still inserts only as
-- themselves, via msg_client_insert, which is unchanged.
drop policy if exists msg_staff_insert on messages;
create policy msg_staff_insert on messages
  for insert to authenticated
  with check (gem_is_org_member(org_id) and sender_id = auth.uid());


-- ---------- verify ----------
select
  (select count(*) from pg_policies
     where tablename = 'messages' and policyname = 'msg_staff_insert')      = 1 as staff_insert_policy,
  (select prosrc like '%unsynced%' from pg_proc
     where proname = 'gem_claim_sync')                                          as guard_updated;
