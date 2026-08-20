-- ============================================================
-- GEM · 23 — the wedding party
-- Run AFTER 22_invoice_lines.sql. Safe to re-run.
--
-- A planner tracks the wedding party from the first meeting: who is standing
-- up, in what order they walk, whose side they are on. There was nowhere to
-- put any of it, so it lived in a planner's head or a spreadsheet beside the
-- app — which is the same as it not existing the week of the wedding.
--
-- One nullable column on guests, because a bridesmaid IS a guest. She RSVPs,
-- eats a meal, sits at a table and has a nut allergy like everybody else, and
-- a separate wedding_party table would mean two rows for one person and two
-- counts that start disagreeing the moment one of them is edited.
--
-- Free text rather than an enum. The app offers the conventional list —
-- including both forms of each role, because a wedding party is not a gendered
-- list — but a studio that files someone as "Dog of Honour" is not wrong, and
-- an enum would need a migration to say so. Processional order is derived in
-- the app from the role name; storing it would be a second thing to keep true.
-- ============================================================

alter table guests add column if not exists role text;

-- Partial: on a 200-guest wedding perhaps a dozen rows have one, and the query
-- that reads them always filters to non-null first.
create index if not exists guests_role_idx on guests(event_id, role)
  where role is not null and role <> '';

-- No policy changes: guests already carry org-scoped RLS from 02_rls.sql, and
-- this is a column on rows those policies already govern. A couple reading
-- their own guest list through the portal sees the roles too, which is correct
-- — it is their wedding party.

select
  (select count(*) from information_schema.columns
     where table_name = 'guests' and column_name = 'role')            = 1 as guest_role,
  (select is_nullable = 'YES' from information_schema.columns
     where table_name = 'guests' and column_name = 'role')                as role_nullable,
  (select count(*) from pg_indexes
     where indexname = 'guests_role_idx')                             = 1 as role_index,
  -- still exactly one row per guest: no second table was added
  (select count(*) from information_schema.tables
     where table_name = 'wedding_party')                              = 0 as no_parallel_table;
