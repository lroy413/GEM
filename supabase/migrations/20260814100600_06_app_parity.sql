-- ============================================================
-- GEM · 06 — bring the schema level with the app
-- Run AFTER 05_storage.sql.
--
-- Files 01–05 were written before several features landed. Wiring the app to
-- the schema as it stands would silently drop, on every save:
--
--   · every client's partners, pronouns, postal address, lead source and photo
--   · every venue address, venue contact and site note
--   · the entire floor plan — room size, table shapes, positions, doors,
--     windows, backdrop and every other fixture
--   · vendor bookings (the directory/booking split), preferred flags, ratings
--   · all white-label settings — logo, colours, pipeline stages, templates,
--     custom fields
--
-- This file closes that gap. It is safe to re-run: every statement is
-- guarded, so a partial first run can simply be run again.
-- ============================================================


-- ---------- 1 · leads: the full client file ----------
-- The app's client screen edits all of these; the table held nine of them.
alter table leads add column if not exists partner_a         text    not null default '';
alter table leads add column if not exists partner_b         text    not null default '';
alter table leads add column if not exists pronouns_a        text    not null default '';
alter table leads add column if not exists pronouns_b        text    not null default '';
alter table leads add column if not exists alt_email         text    not null default '';
alter table leads add column if not exists preferred_contact text    not null default '';
alter table leads add column if not exists source            text    not null default '';
alter table leads add column if not exists address           jsonb   not null default '{}'::jsonb;
-- Storage object key inside the private gem-media bucket, never a public URL.
alter table leads add column if not exists photo_path        text;


-- ---------- 2 · events: venue detail and room ----------
alter table events add column if not exists start_time    text    not null default '';
alter table events add column if not exists venue_address jsonb   not null default '{}'::jsonb;
alter table events add column if not exists venue_contact jsonb   not null default '{}'::jsonb;
alter table events add column if not exists venue_notes   text    not null default '';
-- Room envelope and canvas preferences: { w, h, unit, snap, showChairs }.
-- The fixtures themselves are rows in floor_items below, not JSON, so they
-- can be queried and edited individually.
alter table events add column if not exists floor         jsonb   not null
  default '{"w":60,"h":40,"unit":"ft","snap":true,"showChairs":true}'::jsonb;


-- ---------- 3 · seating_tables: real geometry ----------
-- Dimensions are stored in FEET as numeric, matching the app's internal unit.
-- The UI collects inches (60" rounds, 8ft banquets) and converts on the way in,
-- so the room on screen matches the real room.
alter table seating_tables add column if not exists shape    text          not null default 'round';
alter table seating_tables add column if not exists w        numeric(6,2)  not null default 5;
alter table seating_tables add column if not exists h        numeric(6,2)  not null default 5;
alter table seating_tables add column if not exists x        numeric(6,2)  not null default 0;
alter table seating_tables add column if not exists y        numeric(6,2)  not null default 0;
alter table seating_tables add column if not exists rotation numeric(6,2)  not null default 0;

do $$ begin
  alter table seating_tables
    add constraint seating_tables_shape_chk check (shape in ('round','rect','oval','square'));
exception when duplicate_object then null;
end $$;


-- ---------- 4 · floor_items: doors, windows, backdrop, fixtures ----------
create table if not exists floor_items (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id)   on delete cascade,
  event_id    uuid not null references events(id) on delete cascade,
  kind        text not null,          -- door | double-door | window | fire-exit |
                                      -- backdrop | dance-floor | stage | bar |
                                      -- buffet | cake | gift | dj
  label       text not null default '',
  x           numeric(6,2) not null default 0,
  y           numeric(6,2) not null default 0,
  w           numeric(6,2) not null default 3,
  h           numeric(6,2) not null default 1,
  rotation    numeric(6,2) not null default 0,
  sort_order  int  not null default 0,
  created_at  timestamptz  not null default now()
);
create index if not exists floor_items_event_idx on floor_items(event_id);


-- ---------- 5 · vendors as a directory, bookings as the link ----------
-- A florist should exist once and be bookable to many events. The original
-- table carried event_id/status/fee on the vendor itself, so the same supplier
-- had to be duplicated per event and could never be reused or rated.
alter table vendors add column if not exists preferred boolean not null default false;
alter table vendors add column if not exists rating    int     not null default 0
  check (rating between 0 and 5);

create table if not exists vendor_bookings (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id)    on delete cascade,
  vendor_id   uuid not null references vendors(id) on delete cascade,
  event_id    uuid not null references events(id)  on delete cascade,
  status      vendor_status not null default 'quote',
  fee         numeric(12,2) not null default 0,
  notes       text not null default '',
  created_at  timestamptz   not null default now(),
  unique (vendor_id, event_id)
);
create index if not exists vendor_bookings_event_idx on vendor_bookings(event_id);

-- Fold any legacy per-event vendor rows into bookings, once.
insert into vendor_bookings (org_id, vendor_id, event_id, status, fee)
select v.org_id, v.id, v.event_id, v.status, v.fee
  from vendors v
 where v.event_id is not null
on conflict (vendor_id, event_id) do nothing;

-- vendors.event_id/status/fee are now vestigial. They are left in place rather
-- than dropped so this file stays non-destructive; the app reads bookings.
comment on column vendors.event_id is 'Legacy. Superseded by vendor_bookings.';
comment on column vendors.status   is 'Legacy. Superseded by vendor_bookings.status.';
comment on column vendors.fee      is 'Legacy. Superseded by vendor_bookings.fee.';


-- ---------- 6 · org_prefs: the white-label settings ----------
-- One row per org. Held as jsonb because this is a bag of studio preferences
-- the UI reads whole and rewrites whole — giving each a column would mean a
-- migration every time a setting is added.
create table if not exists org_prefs (
  org_id      uuid primary key references orgs(id) on delete cascade,
  prefs       jsonb not null default '{}'::jsonb,   -- name, accent, logo, landing, density…
  stages      jsonb not null default '[]'::jsonb,   -- pipeline stages, ordered
  templates   jsonb not null default '{}'::jsonb,   -- task countdowns, document templates
  fields      jsonb not null default '[]'::jsonb,   -- custom fields
  updated_at  timestamptz not null default now()
);


-- ---------- 7 · row-level security on everything new ----------
-- New tables default to unrestricted. Without this block they would be
-- readable by any authenticated user of the project, regardless of org.
alter table floor_items     enable row level security;
alter table floor_items     force  row level security;
alter table vendor_bookings enable row level security;
alter table vendor_bookings force  row level security;
alter table org_prefs       enable row level security;
alter table org_prefs       force  row level security;

-- Floor plan: mirrors seating_tables — a couple may look, only staff may edit.
drop policy if exists floor_items_read  on floor_items;
create policy floor_items_read on floor_items
  for select to authenticated using (gem_can_read_event(org_id, event_id));
drop policy if exists floor_items_write on floor_items;
create policy floor_items_write on floor_items
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

-- Bookings carry fees, so staff only — same stance as vendors.
drop policy if exists vendor_bookings_all on vendor_bookings;
create policy vendor_bookings_all on vendor_bookings
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

-- Settings: any member may read them (the UI needs the branding to paint),
-- only an owner or planner may change them.
drop policy if exists org_prefs_read on org_prefs;
create policy org_prefs_read on org_prefs
  for select to authenticated using (gem_is_org_member(org_id));
drop policy if exists org_prefs_write on org_prefs;
create policy org_prefs_write on org_prefs
  for all to authenticated
  using      (gem_has_org_role(org_id, array['owner','planner']::org_role[]))
  with check (gem_has_org_role(org_id, array['owner','planner']::org_role[]));


-- ---------- 8 · keep updated_at honest ----------
drop trigger if exists org_prefs_touch on org_prefs;
create trigger org_prefs_touch before update on org_prefs
  for each row execute function touch_updated_at();


-- ---------- verify ----------
-- One query, because the SQL Editor only shows the last result.
-- Expect: tables 29, policies 65+, and every check true.
select
  (select count(*) from information_schema.tables
     where table_schema = 'public')                                     as tables,
  (select count(*) from pg_policies where schemaname = 'public')        as policies,
  (select count(*) from information_schema.columns
     where table_name = 'leads' and column_name = 'address')       = 1  as leads_address,
  (select count(*) from information_schema.columns
     where table_name = 'events' and column_name = 'floor')        = 1  as events_floor,
  (select count(*) from information_schema.columns
     where table_name = 'seating_tables' and column_name = 'rotation') = 1 as tables_geometry,
  (select count(*) from information_schema.tables
     where table_name = 'floor_items')                             = 1  as floor_items,
  (select count(*) from information_schema.tables
     where table_name = 'vendor_bookings')                         = 1  as vendor_bookings,
  (select count(*) from information_schema.tables
     where table_name = 'org_prefs')                               = 1  as org_prefs,
  (select count(*) from pg_policies
     where schemaname = 'public'
       and tablename in ('floor_items','vendor_bookings','org_prefs')) = 5 as new_policies;
