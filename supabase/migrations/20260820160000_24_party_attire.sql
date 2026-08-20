-- ============================================================
-- GEM · 24 — what the wedding party is wearing
-- Run AFTER 23_wedding_party.sql. Safe to re-run.
--
-- Eight dresses ordered from three shops in four sizes, one of which has not
-- arrived and nobody can remember whose. It is the single most common reason a
-- planner leaves the app for a spreadsheet, and the reason it needs to be here
-- rather than in a note field is that it is a CHAIN of states, not a tick:
-- ordered is not arrived, arrived is not altered, and knowing which link is
-- stuck is the whole job.
--
-- One jsonb column rather than five scalar ones. It is a value object hanging
-- off a guest — {item, size, status, due, note} — with no identity of its own:
-- nothing references it, nothing joins to it, and it is only ever read as part
-- of the guest who wears it. Same reasoning as invoices.items in 22.
--
-- Object, not array, and the check says so — the app reads it with dotted
-- access, and a jsonb array would fail in the browser rather than here where
-- the error is legible.
-- ============================================================

alter table guests add column if not exists attire jsonb not null default '{}'::jsonb;

alter table guests drop constraint if exists guests_attire_is_object;
alter table guests add  constraint guests_attire_is_object
  check (jsonb_typeof(attire) = 'object');

-- Only the wedding party has attire, and only some of them have it filled in,
-- so the index carries the handful of rows that do rather than every guest at
-- every wedding the studio has ever run.
create index if not exists guests_attire_idx on guests(event_id)
  where attire <> '{}'::jsonb;

-- No policy changes: guests already carry org-scoped RLS from 02_rls.sql and
-- this is a column on rows those policies govern. Worth knowing that a couple
-- reading their own guest list through the portal can read it too — which is
-- correct, it is their wedding party's attire, and the app shows them none of
-- it today.

select
  (select count(*) from information_schema.columns
     where table_name = 'guests' and column_name = 'attire')          = 1 as guest_attire,
  (select count(*) from pg_constraint
     where conname = 'guests_attire_is_object')                       = 1 as object_check,
  (select count(*) from pg_indexes
     where indexname = 'guests_attire_idx')                           = 1 as attire_index,
  -- 23 is still in place; this builds on it rather than replacing it
  (select count(*) from information_schema.columns
     where table_name = 'guests' and column_name = 'role')            = 1 as role_still_there;
