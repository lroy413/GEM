-- ============================================================
-- GEM · 15 — GEM is not only for weddings
-- Run AFTER 14_client_invites.sql. Safe to re-run.
--
-- Everything so far assumed a wedding. leads.event_type existed, but the EVENT
-- itself had no type, so a corporate gala was rendered with a wedding's
-- vocabulary: rehearsal dinners in the sub-event list, "the couple" on the
-- task tabs, a farewell brunch nobody was having.
--
-- events.event_type fixes the data half. The app reads it to decide which
-- sub-event roles to offer and what to call the client.
--
-- A few generic roles are added alongside: a conference has sessions and a
-- keynote, a gala has a dinner, and 'afterparty' belongs to most of them.
-- 'custom' still covers anything this list will never guess.
-- ============================================================


-- ---------- 1 · the event's own type ----------
-- Free text with no check constraint on purpose. Studios run things nobody
-- planning this schema would think of, and a wrong guess here means an event
-- that cannot sync. The app offers a list; the column accepts what it is given.
alter table events add column if not exists event_type text not null default 'Wedding';

comment on column events.event_type is
  'Wedding | Corporate | Birthday | Anniversary | Gala | Conference | Shower | '
  'Graduation | Holiday | Memorial | Other — or anything else the studio types. '
  'Drives which sub-event roles the app offers and what it calls the client.';

create index if not exists events_type_idx on events (org_id, event_type);

-- Existing events inherit their client's type where there is one, so a studio
-- that has been using event_type on the lead does not have to redo it.
update events e
   set event_type = l.event_type
  from leads l
 where e.lead_id = l.id
   and coalesce(l.event_type,'') <> ''
   and e.event_type = 'Wedding'
   and l.event_type <> 'Wedding';


-- ---------- 2 · roles that are not about weddings ----------
alter table events drop constraint if exists events_role_chk;

alter table events add constraint events_role_chk check (event_role in (
  'primary',
  -- weddings
  'welcome','rehearsal','ceremony','reception','brunch','fitting','shower','party',
  -- shared across most types
  'tasting','walkthrough','photos','setup','dinner','afterparty',
  -- conferences and corporate
  'session','keynote','breakout','networking',
  -- anything else
  'custom','other'
));


-- ---------- verify ----------
select
  (select count(*) from information_schema.columns
     where table_name = 'events' and column_name = 'event_type')          = 1 as event_type_col,
  (select count(*) from pg_constraint where conname = 'events_role_chk')  = 1 as role_check,
  (select bool_and(pg_get_constraintdef(oid) like '%' || v || '%')
     from pg_constraint,
          unnest(array['session','keynote','breakout','networking',
                       'dinner','afterparty']) as v
    where conname = 'events_role_chk')                                        as new_roles_allowed,
  (select count(*) from pg_constraint
     where conname = 'events_role_parent_chk')                            = 1 as parent_rule_intact,
  (select array_agg(distinct event_type) from events)                         as types_in_use;
