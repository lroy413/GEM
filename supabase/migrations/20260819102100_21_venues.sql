-- ============================================================
-- GEM · 21 — a venue is a place, not a string
-- Run AFTER 20_client_cover.sql. Safe to re-run. NOT YET RUN — the venue
-- feature it belongs to is unfinished; this file is here, numbered, and inert.
--
-- Until now a venue was free text on each event, with its address, its
-- coordinator and its load-in rules in three more columns beside it. Every one
-- of those belongs to the PLACE, not to the night: a weekend at one estate
-- stored the same address four times over, with nothing recording that they
-- were the same address. Correct the coordinator's number and you edit it four
-- times, or you edit three and carry a wrong one into the day.
--
-- A venue is also not a vendor. A vendor is booked and paid — vendor_bookings
-- carries a status and a fee. A venue has properties you plan against: how many
-- it seats, which rooms, when you can load in, when the noise has to stop, and
-- whether there is anywhere to go if it rains. Filing it under Florals /
-- Catering would force fee semantics onto something that has none.
--
-- events.venue (text) STAYS, and stays authoritative when venue_id is null.
-- Studios type "TBD" and "their garden", and a place with no record is a normal
-- state rather than a missing one.
-- ============================================================


-- ---------- 1 · the place ----------
create table if not exists venues (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  name          text not null,
  kind          text not null default '',
  address       jsonb not null default '{}'::jsonb,
  contact       jsonb not null default '{}'::jsonb,
  website       text not null default '',
  seated        int  not null default 0,
  standing      int  not null default 0,
  -- Load-in, curfew, parking, power: the things that are true every time you
  -- work here, which is exactly what a per-event note could never accumulate.
  notes         text not null default '',
  -- [{id,name,seated,standing,note}] — the rooms. A jsonb array rather than a
  -- table because nothing joins to a room and nothing ever will; the floor plan
  -- keys on the event, not on this.
  spaces        jsonb not null default '[]'::jsonb,
  photo_path    text,
  preferred     boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists venues_org_idx on venues (org_id, name);
-- Deliberately NOT unique, and it was: a device that already holds a venue of
-- its own for a name the server also has would have its whole push rejected by
-- the constraint, because the upsert resolves on the primary key and cannot
-- see an expression index. Two rows called the same thing is a tidiness
-- problem; a push that fails is the failure mode this sync was rebuilt to
-- prevent. The client refuses a duplicate name at the point of typing, which
-- is where the question belongs.
drop index if exists venues_org_name_key;
create index if not exists venues_org_lname_idx on venues (org_id, lower(name));

comment on column venues.spaces is
  'Rooms within the venue: [{id,name,seated,standing,note}]. The event''s own '
  'floor plan is separate — this is what the place offers, not how one night '
  'is laid out.';
-- <org>/venues/<venueId> — the same shape as a lead photo, and covered by the
-- same policies from 08 without a change: segment 1 is the org, so staff read
-- and write it, and gem_uuid() returns null for the literal 'venues' segment,
-- so the couple branch simply never matches. Directory imagery is the studio's,
-- not the client's; a venue cover is deliberately NOT visible in the portal.
comment on column venues.photo_path is
  'Object key in the private gem-media bucket, <org>/venues/<venueId>, or null. '
  'Staff only — the client-read branch of the storage policy cannot match it.';

drop trigger if exists venues_touch on venues;
create trigger venues_touch before update on venues
  for each row execute function touch_updated_at();


-- ---------- 2 · the event points at it ----------
-- Nullable, and on delete set null: removing a venue from the directory must
-- not take the events with it. events.venue keeps the name either way, so an
-- event whose venue record is deleted still says where it is.
alter table events add column if not exists venue_id uuid references venues(id) on delete set null;
create index if not exists events_venue_idx on events (venue_id);


-- ---------- 3 · no backfill here, on purpose ----------
-- An earlier draft lifted one venue per distinct name per org straight out of
-- the events. It worked, and it was wrong: the app does the identical lift in
-- normalize() the moment it loads, with ids it owns, and then pushes them. Two
-- backfills means two rows per place with different ids — and, with the unique
-- index this file used to create, a push that 409s and takes the studio's sync
-- down with it. One source, and it is the device.
--
-- So a studio that runs this sees an empty venues table until the next push,
-- which is a few seconds later and carries the whole directory.

-- ---------- 4 · who may see a place ----------
alter table venues enable row level security;
alter table venues force  row level security;

drop policy if exists venues_read on venues;
-- Staff see the directory. A couple sees only the venue their own event is at
-- — they are told the address and the coordinator anyway, and gem_is_event_client
-- has reached through parent_event_id since 10, so a weekend works.
create policy venues_read on venues
  for select to authenticated
  using (
    gem_is_org_member(org_id)
    or exists (select 1 from events e
                where e.venue_id = venues.id
                  and gem_is_event_client(e.id))
  );

drop policy if exists venues_write on venues;
create policy venues_write on venues
  for all to authenticated
  using      (gem_has_org_role(org_id, array['owner','planner']::org_role[]))
  with check (gem_has_org_role(org_id, array['owner','planner']::org_role[]));


-- ---------- verify ----------
select
  (select count(*) from information_schema.tables
     where table_name = 'venues')                                        = 1 as venues_table,
  (select count(*) from information_schema.columns
     where table_name = 'events' and column_name = 'venue_id')           = 1 as events_venue_id,
  (select count(*) from pg_policies
     where schemaname = 'public' and tablename = 'venues')               = 2 as venue_policies,
  (select relrowsecurity and relforcerowsecurity from pg_class
     where relname = 'venues')                                               as rls_forced,
  (select count(*) from pg_indexes
     where tablename = 'venues' and indexname = 'venues_org_lname_idx') = 1 as name_index,
  (select count(*) from pg_indexes
     where tablename = 'venues' and indexname = 'venues_org_name_key')  = 0 as no_unique_index,
  -- expected to be 0 until the next push; the app carries the directory up
  (select count(*) from venues)                                             as venues_now;
