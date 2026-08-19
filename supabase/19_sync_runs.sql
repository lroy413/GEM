-- ============================================================
-- GEM · 19 — what the sync actually did
-- Run AFTER 18_sample_flag.sql. Safe to re-run.
--
-- Reconstructing the loss of a client file took an afternoon of reading rows
-- and inferring from two duplicated events, because nothing anywhere recorded
-- that a device wrote these counts at this time and deleted that many. Every
-- question worth asking — which device, how much did it send, did it finish,
-- what did it remove — had to be guessed at from the wreckage.
--
-- A row per attempt fixes that, and the shape of the table is chosen so the
-- most important state is the one that costs nothing to record: a run that
-- dies leaves a row with finished_at still null. An unfinished run is not an
-- error the client has to remember to report — it is simply a row nobody came
-- back to close.
-- ============================================================


create table if not exists sync_runs (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete cascade,
  user_id        uuid,
  device         text not null default '',
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  -- 'committed' · 'failed' · null while still open
  outcome        text,
  version_before bigint,
  version_after  bigint,
  tables_written int not null default 0,
  -- {leads:12, events:4, guests:210, …} exactly as the payload was built, so
  -- "this push carried no leads" is answerable after the fact
  counts         jsonb not null default '{}'::jsonb,
  -- tables whose prune was skipped because the payload was empty
  kept           text[] not null default '{}',
  note           text not null default ''
);
create index if not exists sync_runs_org_idx  on sync_runs (org_id, started_at desc);
-- The one query that matters, made cheap: what never finished?
create index if not exists sync_runs_open_idx on sync_runs (org_id)
  where finished_at is null;

comment on table sync_runs is
  'One row per push attempt. finished_at null means the run never came back — '
  'which is the state that caused the incident of 19 Aug 2026 and the state '
  'nothing was recording.';


-- ---------- who may see it ----------
alter table sync_runs enable row level security;
alter table sync_runs force  row level security;

drop policy if exists sync_runs_read on sync_runs;
create policy sync_runs_read on sync_runs
  for select to authenticated
  using (gem_is_org_member(org_id));

-- Anyone who may sync may record that they did. Writing a row is not a
-- privilege worth guarding more tightly than the sync itself.
drop policy if exists sync_runs_insert on sync_runs;
create policy sync_runs_insert on sync_runs
  for insert to authenticated
  with check (gem_has_org_role(org_id, array['owner','planner']::org_role[])
              and user_id = auth.uid());

-- A device may only close its own run. Otherwise a second device could mark
-- someone else's abandoned push as finished, which is the one lie this table
-- exists to prevent.
drop policy if exists sync_runs_update on sync_runs;
create policy sync_runs_update on sync_runs
  for update to authenticated
  using      (user_id = auth.uid() and gem_is_org_member(org_id))
  with check (user_id = auth.uid());


-- Every other table here leans on Supabase's default privileges for new tables
-- in public. That works, and it is an implicit dependency on a platform
-- default; this one says it out loud. Harmless where the defaults already
-- applied, and correct where they did not.
grant select, insert, update on sync_runs to authenticated;


-- ---------- the questions, pre-asked ----------
create or replace function gem_sync_health(p_org uuid)
returns table (
  runs_24h        bigint,
  unfinished_24h  bigint,
  last_committed  timestamptz,
  last_outcome    text,
  open_now        bigint
)
language sql
security definer
set search_path = public
as $$
  select
    (select count(*) from sync_runs where org_id = p_org and started_at > now() - interval '24 hours'),
    (select count(*) from sync_runs where org_id = p_org and started_at > now() - interval '24 hours'
        and finished_at is null),
    (select max(finished_at) from sync_runs where org_id = p_org and outcome = 'committed'),
    (select outcome from sync_runs where org_id = p_org order by started_at desc limit 1),
    (select count(*) from sync_runs where org_id = p_org and finished_at is null
        and started_at > now() - interval '1 hour');
$$;

revoke execute on function gem_sync_health(uuid) from public, anon;
grant  execute on function gem_sync_health(uuid) to authenticated;

comment on function gem_sync_health(uuid) is
  'Five numbers that say whether syncing is healthy. unfinished_24h above zero '
  'is the signal that pushes are dying partway — the condition that went '
  'unnoticed for as long as migration 16 was outstanding.';


-- ---------- verify ----------
select
  (select count(*) from information_schema.tables where table_name = 'sync_runs')     = 1 as runs_table,
  (select count(*) from pg_policies
     where schemaname = 'public' and tablename = 'sync_runs')                          = 3 as policies,
  (select relrowsecurity and relforcerowsecurity from pg_class where relname='sync_runs') as rls_forced,
  (select count(*) from pg_proc where proname = 'gem_sync_health')                     = 1 as health_fn,
  (select count(*) from pg_indexes
     where tablename = 'sync_runs' and indexname = 'sync_runs_open_idx')               = 1 as open_index,
  (select count(*) from sync_runs)                                                         as rows_now;
