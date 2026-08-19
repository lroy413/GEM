-- ============================================================
-- GEM · 17 — a push claims the studio, it does not finish it
-- Run AFTER 16_event_photos.sql, and BEFORE the build that uses it.
-- Safe to re-run.
--
-- gem_claim_sync() incremented sync_version as its FIRST act and then handed
-- control back to the browser to write 27 tables. Anything that went wrong
-- after that — and for as long as migration 16 was outstanding, every single
-- events upsert did — left the studio marked as newer than it really was, with
-- some tables written, the prune never reached, and the local commit never run.
--
-- Every other device then behaved exactly as designed: the studio is ahead,
-- nothing local is pending, so pull. That is how a complete workspace gets
-- replaced by a half-written one.
--
-- The version now moves only when a run FINISHES. Begin takes a lease and
-- reports where the studio stands; commit is what makes the new state visible
-- to anyone else. A run that dies partway leaves the version exactly where it
-- was, so nobody is invited to come and fetch the wreckage.
-- ============================================================


-- ---------- 1 · who is mid-run ----------
-- A lease rather than a lock: a browser can be closed mid-push and there would
-- be nothing to release it. Five minutes is far longer than any real run and
-- short enough that a dead one clears itself.
alter table org_prefs add column if not exists sync_open_by uuid;
alter table org_prefs add column if not exists sync_open_at timestamptz;

comment on column org_prefs.sync_open_at is
  'When the in-flight push claimed the studio, or null. Treated as expired '
  'after 5 minutes: a browser closed mid-run cannot release its own lease.';


-- ---------- 2 · begin ----------
create or replace function gem_begin_sync(p_org uuid, p_expect bigint)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare v bigint; ob uuid; oa timestamptz;
begin
  if not gem_has_org_role(p_org, array['owner','planner']::org_role[]) then
    raise exception 'Not permitted to sync this studio.' using errcode = '42501';
  end if;

  insert into org_prefs (org_id) values (p_org) on conflict (org_id) do nothing;
  select sync_version, sync_open_by, sync_open_at
    into v, ob, oa
    from org_prefs where org_id = p_org for update;

  -- Same two refusals as before: a device with no version may only write into
  -- an empty studio, and a device at the wrong version must pull first.
  if p_expect is null then
    if v > 0 then
      raise exception 'unsynced %', v using errcode = '55000';
    end if;
  elsif v <> p_expect then
    raise exception 'stale %', v using errcode = '55000';
  end if;

  -- Somebody else is mid-push. Two devices writing the same 27 tables at once
  -- is how you get a studio that is neither one thing nor the other.
  if oa is not null and oa > now() - interval '5 minutes'
     and ob is distinct from auth.uid() then
    raise exception 'busy %', v using errcode = '55000';
  end if;

  update org_prefs
     set sync_open_by = auth.uid(), sync_open_at = now()
   where org_id = p_org;

  -- Deliberately UNCHANGED. Nothing else may act on this number until commit.
  return v;
end $$;


-- ---------- 3 · commit ----------
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


-- ---------- 4 · abort ----------
-- A push that fails should hand the studio back at once rather than making the
-- next device wait out the lease.
create or replace function gem_abort_sync(p_org uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not gem_has_org_role(p_org, array['owner','planner']::org_role[]) then
    raise exception 'Not permitted to sync this studio.' using errcode = '42501';
  end if;
  update org_prefs
     set sync_open_by = null, sync_open_at = null
   where org_id = p_org and sync_open_by = auth.uid();
end $$;


-- ---------- 5 · the old entry point stays ----------
-- A phone with the previous build cached by its service worker will keep
-- calling gem_claim_sync for a while, and it must not start failing. It keeps
-- its old behaviour — claim and bump in one step — and additionally clears any
-- lease it steps over, so the two generations cannot deadlock each other.
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

  if p_expect is null then
    if v > 0 then
      raise exception 'unsynced %', v using errcode = '55000';
    end if;
  elsif v <> p_expect then
    raise exception 'stale %', v using errcode = '55000';
  end if;

  update org_prefs
     set sync_version = sync_version + 1,
         sync_open_by  = null,
         sync_open_at  = null
   where org_id = p_org
   returning sync_version into v;
  return v;
end $$;

revoke execute on function gem_begin_sync(uuid, bigint)  from public, anon;
revoke execute on function gem_commit_sync(uuid, bigint) from public, anon;
revoke execute on function gem_abort_sync(uuid)          from public, anon;
revoke execute on function gem_claim_sync(uuid, bigint)  from public, anon;
grant  execute on function gem_begin_sync(uuid, bigint)  to authenticated;
grant  execute on function gem_commit_sync(uuid, bigint) to authenticated;
grant  execute on function gem_abort_sync(uuid)          to authenticated;
grant  execute on function gem_claim_sync(uuid, bigint)  to authenticated;


-- ---------- 6 · release anything already stuck ----------
update org_prefs set sync_open_by = null, sync_open_at = null
 where sync_open_at is not null and sync_open_at < now() - interval '5 minutes';


-- ---------- verify ----------
select
  (select count(*) from pg_proc where proname = 'gem_begin_sync')            = 1 as begin_fn,
  (select count(*) from pg_proc where proname = 'gem_commit_sync')           = 1 as commit_fn,
  (select count(*) from pg_proc where proname = 'gem_abort_sync')            = 1 as abort_fn,
  (select count(*) from pg_proc where proname = 'gem_claim_sync')            = 1 as legacy_fn_kept,
  (select count(*) from information_schema.columns
     where table_name = 'org_prefs' and column_name in ('sync_open_by','sync_open_at')) = 2 as lease_cols,
  -- begin must NOT touch the version; this is the whole migration in one line
  (select prosrc not like '%sync_version = sync_version + 1%' from pg_proc
     where proname = 'gem_begin_sync')                                           as begin_leaves_version,
  (select prosrc like '%sync_version = sync_version + 1%' from pg_proc
     where proname = 'gem_commit_sync')                                          as commit_moves_version,
  (select count(*) from org_prefs where sync_open_at is not null)                as runs_open_now;
