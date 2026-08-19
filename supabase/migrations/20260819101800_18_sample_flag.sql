-- ============================================================
-- GEM · 18 — demo content is marked, and refused
-- Run AFTER 17_sync_two_phase.sql. Safe to re-run.
--
-- The sample wedding is recognised by a flag that lives only in the browser.
-- There is no column for it, so a copy that has been through Supabase and back
-- arrives as ordinary rows: Settings reports "no sample data", the banner stops
-- appearing, Remove finds nothing to remove, and Priya & Sam sits on the
-- dashboard indistinguishable from real work. That is what happened here, and
-- it is why twelve demo vendors had to be deleted by hand.
--
-- Be straight about what this does and does not fix. The thing that actually
-- stops demo content reaching a studio is the client no longer sending it, and
-- that already shipped. What this adds:
--
--   · a place for the flag to live, so it survives a round trip
--   · a REFUSAL, so it can never be true — belt to the client's braces, and a
--     hard stop if some future path of ours forgets to filter
--   · one query that answers "is any demo content in here", which took an
--     afternoon of reading rows to answer today
--
-- What it does NOT do: protect against an OLD build. A client that predates
-- the filter simply never mentions this column, the default applies, and its
-- rows land looking real. Only upgrading fixes that.
-- ============================================================


-- ---------- 1 · a place for the flag ----------
-- The three that can stand on their own. Everything else in the sample hangs
-- off a lead or an event and goes when they go.
alter table leads   add column if not exists sample boolean not null default false;
alter table events  add column if not exists sample boolean not null default false;
alter table vendors add column if not exists sample boolean not null default false;

comment on column leads.sample is
  'True only if demo content ever reached this table. A check constraint makes '
  'that impossible, so it should read false forever — a tripwire, not a state.';


-- ---------- 2 · the refusal ----------
-- Not a policy: policies are per-role and this must hold for every writer, the
-- table owner included. A check constraint is the one thing nothing bypasses.
alter table leads   drop constraint if exists leads_not_sample;
alter table events  drop constraint if exists events_not_sample;
alter table vendors drop constraint if exists vendors_not_sample;

alter table leads   add constraint leads_not_sample   check (sample = false);
alter table events  add constraint events_not_sample  check (sample = false);
alter table vendors add constraint vendors_not_sample check (sample = false);


-- ---------- 3 · the question, answerable in one line ----------
create or replace function gem_demo_audit(p_org uuid)
returns table (kind text, id uuid, label text, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
  -- The demo ships with these exact names on every device, so a studio holding
  -- them is holding demo content whatever the flag says. Reported, never
  -- deleted: a studio may legitimately have a client called Priya & Sam.
  select 'lead', l.id, l.names, l.created_at
    from leads l
   where l.org_id = p_org and (l.sample or l.names = 'Priya & Sam')
  union all
  select 'event', e.id, e.title, e.created_at
    from events e
   where e.org_id = p_org and (e.sample or e.title = 'Priya & Sam')
  union all
  select 'vendor', v.id, v.name, v.created_at
    from vendors v
   where v.org_id = p_org and (v.sample or v.name in (
     'Fern & Fable Florals','Hearth & Vine Catering','Aurelio Photography',
     'The Copper Quartet','Lumen Event Rentals','Gilded Cake Studio'))
  order by 1, 4;
$$;

revoke execute on function gem_demo_audit(uuid) from public, anon;
grant  execute on function gem_demo_audit(uuid) to authenticated;

comment on function gem_demo_audit(uuid) is
  'Everything in a studio that looks like the demo wedding, by flag or by the '
  'names it ships with. Reports only — deleting is a judgement call.';


-- ---------- verify ----------
select
  (select count(*) from information_schema.columns
     where table_name in ('leads','events','vendors') and column_name = 'sample') = 3 as flag_cols,
  (select count(*) from pg_constraint
     where conname in ('leads_not_sample','events_not_sample','vendors_not_sample')) = 3 as refusals,
  (select count(*) from pg_proc where proname = 'gem_demo_audit')                   = 1 as audit_fn,
  -- the tripwire itself: all three must be false, forever
  (select count(*) from leads   where sample) = 0 as no_sample_leads,
  (select count(*) from events  where sample) = 0 as no_sample_events,
  (select count(*) from vendors where sample) = 0 as no_sample_vendors;
