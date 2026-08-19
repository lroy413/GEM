-- ============================================================
-- GEM · 13 — whose task is it, and what was said about it
-- Run AFTER 12_event_roles.sql. Safe to re-run.
--
-- A checklist item had no owner, which had two consequences:
--
--   · there was no way to give the couple a job. A planner who wanted them to
--     choose a first dance had to send a message and remember to chase it.
--   · the portal showed them EVERY item, including the studio's own internal
--     work — chase the florist, invoice the balance, confirm the load-in. The
--     couple was reading the planner's private worklist.
--
-- owner splits the two lists. RLS already lets a couple read the checklist of
-- an event they are attached to, so this is what makes that safe: the app
-- shows them only their own items, and the internal ones stop being their
-- business.
--
-- note is the running commentary on a single task — the thing that otherwise
-- ends up in a text message and is lost.
-- ============================================================


alter table checklist_items add column if not exists owner text not null default 'planner';
alter table checklist_items add column if not exists note  text not null default '';

do $$ begin
  alter table checklist_items add constraint checklist_owner_chk
    check (owner in ('planner','client'));
exception when duplicate_object then null;
end $$;

comment on column checklist_items.owner is
  'planner = the studio''s own work, never shown in the portal. client = assigned to the couple.';
comment on column checklist_items.note is
  'Free notes about this one task. Visible to the couple when owner = client.';

-- Existing rows keep the default, which is the safe direction: everything that
-- predates this stays internal rather than suddenly appearing in the portal.
create index if not exists checklist_owner_idx on checklist_items (event_id, owner, done);


-- ---------- verify ----------
select
  (select count(*) from information_schema.columns
     where table_name = 'checklist_items' and column_name = 'owner')     = 1 as owner_col,
  (select count(*) from information_schema.columns
     where table_name = 'checklist_items' and column_name = 'note')      = 1 as note_col,
  (select count(*) from pg_constraint
     where conname = 'checklist_owner_chk')                              = 1 as owner_check,
  (select count(*) from checklist_items where owner not in ('planner','client')) = 0 as all_rows_valid,
  (select count(*) from checklist_items where owner = 'client')                     as client_tasks_now;
