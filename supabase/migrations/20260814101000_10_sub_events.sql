-- ============================================================
-- GEM · 10 — the wedding weekend
-- Run AFTER 09_sync_fixes.sql. Safe to re-run.
--
-- A wedding is four events: welcome party, rehearsal dinner, ceremony and
-- reception, farewell brunch. One couple, one contract, shared vendors, one
-- guest list with a different subset at each. The schema already allowed many
-- events per client (events.lead_id) but nothing said they belonged together,
-- so the dashboard counted down to four competing dates and the client file
-- listed them as strangers.
--
-- This file makes the weekend a block: a primary event with sub-events hanging
-- off it, and an invitation list that fans out from the primary's guest list.
--
-- What it does NOT do, deliberately:
--
--   · seating and floor plans need no change. events.floor, floor_items and
--     seating_tables are already keyed by event_id (migration 06), so every
--     sub-event gets its own room and its own tables for free. The remaining
--     work there is an event switcher in the UI.
--   · guests are not touched. A guest row stays owned by the PRIMARY event and
--     its rsvp/table_id keep meaning "the ceremony and reception". Invitations
--     to the other three live in guest_invites. One shape, one writer, no
--     backfill, and the sync path stabilised in 08/09 keeps working unchanged.
-- ============================================================


-- ---------- 1 · events: parent, role, order ----------
-- on delete cascade: the weekend is one block. Deleting the wedding takes the
-- rehearsal dinner with it, which is what a planner means by "cancel the job".
alter table events add column if not exists parent_event_id uuid
  references events(id) on delete cascade;

-- text + check rather than an enum, matching seating_tables.shape: a studio
-- that runs a second ceremony or a morning-after pool party should be a one
-- line change here, not an ALTER TYPE.
alter table events add column if not exists event_role text not null default 'primary';
alter table events add column if not exists sort_order int  not null default 0;

do $$ begin
  alter table events add constraint events_role_chk
    check (event_role in ('primary','welcome','rehearsal','ceremony','brunch','other'));
exception when duplicate_object then null;
end $$;

-- The two columns must agree. 'primary' does not mean "a wedding" — it means
-- "the top of its own block", so a standalone corporate gala is primary too.
do $$ begin
  alter table events add constraint events_role_parent_chk
    check ((parent_event_id is null) = (event_role = 'primary'));
exception when duplicate_object then null;
end $$;

create index if not exists events_parent_idx on events (parent_event_id, sort_order);

comment on column events.parent_event_id is
  'The primary event this one hangs off. Null on a primary. One level only.';
comment on column events.event_role is
  'primary | welcome | rehearsal | ceremony | brunch | other.';


-- ---------- 2 · keep the tree one level deep ----------
-- A check constraint cannot see other rows, so the shape guarantees that make
-- the UI safe to write live here instead: no self-parenting, no grandchildren,
-- no cross-org parents. Without these the client file can recurse for ever and
-- "the guests belong to the primary" stops having a single answer.
create or replace function gem_event_parent_guard() returns trigger
language plpgsql
as $$
declare p record;
begin
  if new.parent_event_id is null then
    -- Demoting a parent to standalone while it still has children would orphan
    -- them behind the role/parent check above.
    return new;
  end if;

  if new.parent_event_id = new.id then
    raise exception 'An event cannot be its own parent.' using errcode = '23514';
  end if;

  select id, org_id, parent_event_id into p from events where id = new.parent_event_id;
  if not found then
    raise exception 'Parent event % does not exist.', new.parent_event_id using errcode = '23503';
  end if;
  if p.org_id <> new.org_id then
    raise exception 'Parent event belongs to another studio.' using errcode = '23514';
  end if;
  if p.parent_event_id is not null then
    raise exception 'Sub-events are one level deep; % is already a sub-event.', p.id
      using errcode = '23514';
  end if;
  if exists (select 1 from events c where c.parent_event_id = new.id) then
    raise exception 'Event % has sub-events of its own and cannot become one.', new.id
      using errcode = '23514';
  end if;

  return new;
end $$;

drop trigger if exists events_parent_guard on events;
create trigger events_parent_guard before insert or update of parent_event_id, org_id on events
  for each row execute function gem_event_parent_guard();


-- ---------- 3 · guest_invites: who is asked to what ----------
-- The point of the whole feature. Aunt Marjorie comes to the ceremony, not the
-- rehearsal dinner. A row here is an invitation to ONE sub-event, carrying its
-- own RSVP, its own seat in that room, and its own meal choice — the rehearsal
-- dinner is a different room with different people and a different menu.
--
-- No row exists for the primary event: that invitation is the guest row itself.
create table if not exists guest_invites (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id)           on delete cascade,
  guest_id    uuid not null references guests(id)         on delete cascade,
  event_id    uuid not null references events(id)         on delete cascade,
  table_id    uuid references seating_tables(id)          on delete set null,
  rsvp        rsvp_status not null default 'invited',
  meal        text,
  created_at  timestamptz not null default now(),
  unique (guest_id, event_id)
);
create index if not exists guest_invites_event_idx on guest_invites (event_id, rsvp);
create index if not exists guest_invites_guest_idx on guest_invites (guest_id);
create index if not exists guest_invites_table_idx on guest_invites (table_id);

-- Two things the table cannot say for itself. An invite to the guest's own
-- event would give the wedding two RSVPs that disagree; a table_id from
-- another room would seat someone at a table that is not in the building.
create or replace function gem_guest_invite_guard() returns trigger
language plpgsql
as $$
declare g record;
begin
  select event_id, org_id into g from guests where id = new.guest_id;
  if not found then
    raise exception 'Guest % does not exist.', new.guest_id using errcode = '23503';
  end if;
  if g.event_id = new.event_id then
    raise exception 'The guest row is already the invitation to its own event; no invite row needed.'
      using errcode = '23514';
  end if;
  if g.org_id <> new.org_id then
    raise exception 'Guest belongs to another studio.' using errcode = '23514';
  end if;
  if new.table_id is not null
     and not exists (select 1 from seating_tables t
                      where t.id = new.table_id and t.event_id = new.event_id) then
    raise exception 'Table % is not in event %.', new.table_id, new.event_id
      using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists guest_invites_guard on guest_invites;
create trigger guest_invites_guard before insert or update on guest_invites
  for each row execute function gem_guest_invite_guard();

comment on table guest_invites is
  'One invitation to one sub-event. The primary event''s invitation is the guests row itself.';


-- ---------- 4 · budget: one weekend, one number ----------
-- A planner quotes a weekend as a single figure, so the budget stays attached
-- to the primary event and a line may simply be tagged with the sub-event it
-- belongs to. Nullable, because most lines are the weekend's, not any one
-- night's. on delete set null: dropping the brunch should not silently delete
-- the money already spent on it.
alter table budget_lines add column if not exists tag_event_id uuid
  references events(id) on delete set null;
create index if not exists budget_lines_tag_idx on budget_lines (tag_event_id);

comment on column budget_lines.tag_event_id is
  'Optional sub-event this line is for. Null means the weekend as a whole.';


-- ---------- 5 · the portal sees one weekend ----------
-- event_clients attaches a couple to a single event. Left alone, a couple
-- attached to the wedding would be a stranger to their own rehearsal dinner:
-- no timeline, no checklist, no guest list, no messages — every per-event
-- policy in 02_rls.sql goes through these two functions.
--
-- Redefining them here to reach through parent_event_id fixes all of those at
-- once, and is why nothing below this line needs a policy of its own.
--
-- events_read must be rewritten first, and inline. events carries FORCE row
-- level security (02_rls.sql), so `security definer` does not exempt these
-- functions from the events policy — and the events policy calls them. Reading
-- events from inside gem_is_event_client while events_read calls
-- gem_is_event_client is a cycle, and Postgres answers it with
-- "infinite recursion detected in policy for relation events": the table stops
-- reading, for staff as well as couples.
--
-- A policy on events already has the row in scope, so it needs no second read
-- to find the parent. Inlining the check there breaks the cycle, and every
-- other table can then go on asking the functions.
drop policy if exists events_read on events;
create policy events_read on events
  for select to authenticated
  using (
    gem_is_org_member(org_id)
    or exists (
      select 1 from event_clients c
       where c.user_id = auth.uid()
         and (c.event_id = events.id or c.event_id = events.parent_event_id)
    )
  );

create or replace function gem_is_event_client(p_event uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from events e
      join event_clients c
        on c.event_id = e.id or c.event_id = e.parent_event_id
     where e.id = p_event
       and c.user_id = auth.uid()
  );
$$;

create or replace function gem_client_can_edit(p_event uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from events e
      join event_clients c
        on c.event_id = e.id or c.event_id = e.parent_event_id
     where e.id = p_event
       and c.user_id = auth.uid()
       and c.can_edit
  );
$$;

revoke execute on function gem_is_event_client(uuid) from public, anon;
revoke execute on function gem_client_can_edit(uuid) from public, anon;
grant  execute on function gem_is_event_client(uuid) to authenticated;
grant  execute on function gem_client_can_edit(uuid) to authenticated;


-- ---------- 6 · row-level security on guest_invites ----------
-- Mirrors guests exactly: staff may do anything, a couple with can_edit may
-- work their own list, everyone else sees nothing. New tables default to
-- unrestricted, so without this block any authenticated user of the project
-- could read every studio's invitations.
alter table guest_invites enable row level security;
alter table guest_invites force  row level security;

drop policy if exists guest_invites_read   on guest_invites;
create policy guest_invites_read on guest_invites
  for select to authenticated
  using (gem_can_read_event(org_id, event_id));

drop policy if exists guest_invites_insert on guest_invites;
create policy guest_invites_insert on guest_invites
  for insert to authenticated
  with check (gem_is_org_member(org_id) or gem_client_can_edit(event_id));

drop policy if exists guest_invites_update on guest_invites;
create policy guest_invites_update on guest_invites
  for update to authenticated
  using      (gem_is_org_member(org_id) or gem_client_can_edit(event_id))
  with check (gem_is_org_member(org_id) or gem_client_can_edit(event_id));

drop policy if exists guest_invites_delete on guest_invites;
create policy guest_invites_delete on guest_invites
  for delete to authenticated
  using (gem_is_org_member(org_id) or gem_client_can_edit(event_id));


-- ---------- verify ----------
-- One query, because the SQL Editor only shows the last result.
-- Every column should read true.
select
  (select count(*) from information_schema.columns
     where table_name = 'events' and column_name = 'parent_event_id')      = 1 as events_parent,
  (select count(*) from information_schema.columns
     where table_name = 'events' and column_name = 'event_role')           = 1 as events_role,
  (select count(*) from information_schema.columns
     where table_name = 'events' and column_name = 'sort_order')           = 1 as events_sort,
  (select count(*) from pg_constraint
     where conname in ('events_role_chk','events_role_parent_chk'))        = 2 as events_checks,
  (select count(*) from pg_trigger
     where tgname = 'events_parent_guard')                                 = 1 as parent_guard,
  (select count(*) from information_schema.tables
     where table_name = 'guest_invites')                                   = 1 as guest_invites,
  (select count(*) from information_schema.columns
     where table_name = 'guest_invites' and column_name = 'table_id')      = 1 as invite_seating,
  (select count(*) from pg_trigger
     where tgname = 'guest_invites_guard')                                 = 1 as invite_guard,
  (select count(*) from information_schema.columns
     where table_name = 'budget_lines' and column_name = 'tag_event_id')   = 1 as budget_tag,
  (select count(*) from pg_policies
     where schemaname = 'public' and tablename = 'guest_invites')          = 4 as invite_policies,
  (select qual not like '%gem_is_event_client%' from pg_policies
     where schemaname = 'public' and tablename = 'events'
       and policyname = 'events_read')                                         as events_read_inlined,
  (select prosrc like '%parent_event_id%' from pg_proc
     where proname = 'gem_is_event_client')                                    as portal_reads_weekend,
  (select prosrc like '%parent_event_id%' from pg_proc
     where proname = 'gem_client_can_edit')                                    as portal_edits_weekend,
  (select relrowsecurity and relforcerowsecurity from pg_class
     where relname = 'guest_invites')                                          as invite_rls;
