-- ============================================================
-- GEM · 25 — labels on a guest
-- Run AFTER 24_party_attire.sql. Safe to re-run.
--
-- `party` already answers one question: which family or group somebody arrives
-- with. It is a single value, so it cannot also say "out of town", "plus one
-- confirmed", "kids' table", "college", "bus from the hotel" — and a planner
-- sorting two hundred names needs all of those at once. Labels are that second
-- axis: any number of them, invented by the studio, and the thing the guest
-- list's filter bar is really for.
--
-- A jsonb array of strings rather than a labels table with a join. They have no
-- identity of their own — nothing references a label, nothing joins to it, and
-- it is only ever read as part of the guest who carries it. A join table would
-- buy referential tidiness at the cost of a second round trip on every pull,
-- for a value the app treats as text. Same reasoning as invoices.items in 22
-- and guests.attire in 24.
--
-- Array, not object, and the check says so: the app maps over it, and an object
-- arriving here would throw in the browser rather than here where the error is
-- legible.
-- ============================================================

alter table guests add column if not exists tags jsonb not null default '[]'::jsonb;

alter table guests drop constraint if exists guests_tags_is_array;
alter table guests add  constraint guests_tags_is_array
  check (jsonb_typeof(tags) = 'array');

-- Most guests carry none, so the index holds the ones that do rather than every
-- guest at every wedding the studio has ever run. jsonb_path_ops keeps it small
-- and answers the only question ever asked of it — does this guest carry this
-- label — through the @> operator.
create index if not exists guests_tags_idx on guests using gin (tags jsonb_path_ops)
  where tags <> '[]'::jsonb;

-- No policy changes: guests already carry org-scoped RLS from 02_rls.sql and
-- this is a column on rows those policies govern.

select
  (select count(*) from information_schema.columns
     where table_name = 'guests' and column_name = 'tags')            = 1 as guest_tags,
  (select count(*) from pg_constraint
     where conname = 'guests_tags_is_array')                          = 1 as array_check,
  (select count(*) from pg_indexes
     where indexname = 'guests_tags_idx')                             = 1 as tags_index,
  -- 24 is still in place; this builds on it rather than replacing it
  (select count(*) from information_schema.columns
     where table_name = 'guests' and column_name = 'attire')          = 1 as attire_still_there;
