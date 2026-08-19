-- ============================================================
-- GEM · 12 — the rest of the weekend, and room for whatever else
-- Run AFTER 11_doc_labels.sql. Safe to re-run.
--
-- Migration 10 allowed six roles: primary, welcome, rehearsal, ceremony,
-- brunch, other. A real wedding has more scheduled occasions than that — a
-- menu tasting, a venue walkthrough, a dress fitting, the shower, load-in the
-- day before — and every one of them is a separate date, venue and guest list.
-- Filed as "other" they are indistinguishable from each other in the switcher.
--
-- Two changes:
--   1. a wider list of the occasions planners actually schedule
--   2. 'custom' plus events.role_label, so a studio can name one itself rather
--      than wait for this list to grow again
--
-- event_role is text + check rather than an enum (see migration 10), so this
-- is a constraint swap and not an ALTER TYPE — no rewrite, no enum surgery.
-- ============================================================


-- ---------- 1 · a label for the ones this list will never guess ----------
alter table events add column if not exists role_label text not null default '';

comment on column events.role_label is
  'Display name when event_role = ''custom''. Ignored for the built-in roles.';


-- ---------- 2 · widen the role list ----------
-- Dropped and recreated rather than added to: a check constraint is a single
-- expression, so widening it means replacing it.
alter table events drop constraint if exists events_role_chk;

alter table events add constraint events_role_chk check (event_role in (
  'primary',      -- the top of its own block; never a sub-event
  'welcome',      -- welcome party / drinks
  'rehearsal',    -- rehearsal dinner
  'ceremony',     -- where the ceremony is its own venue
  'reception',    -- likewise the reception
  'brunch',       -- farewell brunch
  'tasting',      -- menu tasting with the caterer
  'walkthrough',  -- venue walkthrough / site visit
  'fitting',      -- dress or suit fitting
  'shower',       -- shower / engagement party
  'party',        -- bachelor / bachelorette / stag / hen
  'photos',       -- engagement or pre-wedding shoot
  'setup',        -- load-in, build, teardown
  'custom',       -- named by the studio in role_label
  'other'
));

-- The pairing rule from migration 10 is unchanged and still holds: a primary
-- has no parent, a sub-event does. Restated here only because dropping the
-- role check above could otherwise look like it relaxed that too.
--   check ((parent_event_id is null) = (event_role = 'primary'))


-- ---------- 3 · a custom role should actually carry a name ----------
-- Not enforced as a constraint: a half-filled form mid-edit would trip it, and
-- the app falls back to "Custom" for display. Recorded here so the intent is
-- visible to whoever reads the schema.


-- ---------- verify ----------
select
  (select count(*) from information_schema.columns
     where table_name = 'events' and column_name = 'role_label')        = 1 as role_label_col,
  (select count(*) from pg_constraint where conname = 'events_role_chk') = 1 as role_check,
  -- every new value must be accepted by the new constraint
  (select bool_and(
     pg_get_constraintdef(oid) like '%' || v || '%')
     from pg_constraint,
          unnest(array['tasting','walkthrough','fitting','shower','party',
                       'photos','setup','custom','reception']) as v
    where conname = 'events_role_chk')                                      as new_roles_allowed,
  (select count(*) from pg_constraint
     where conname = 'events_role_parent_chk')                          = 1 as parent_rule_intact;
