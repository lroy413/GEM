-- ============================================================
-- GEM · Glimmer Events Management — schema
-- Run in Supabase SQL Editor (or `supabase db push`).
-- Multi-tenant: every row belongs to an org; RLS enforces isolation.
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- tenancy ----------
create table orgs (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_at  timestamptz not null default now()
);

create type org_role as enum ('owner','planner','assistant','viewer');

create table org_members (
  org_id      uuid not null references orgs(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        org_role not null default 'planner',
  created_at  timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index on org_members (user_id);

-- ---------- CRM ----------
create type lead_stage as enum ('inquiry','proposal','booked','planning','wrapped','lost');

create table leads (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  names       text not null,
  event_type  text not null default 'Wedding',
  event_date  date,
  venue       text,
  value       numeric(12,2) not null default 0,
  stage       lead_stage not null default 'inquiry',
  guest_count int not null default 0,
  email       text,
  phone       text,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on leads (org_id, stage);
create index on leads (org_id, event_date);

-- ---------- events ----------
create table events (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  lead_id     uuid references leads(id) on delete set null,
  title       text not null,
  event_date  date,
  venue       text,
  location    text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on events (org_id, event_date);

create table timeline_items (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  event_id    uuid not null references events(id) on delete cascade,
  at_time     text not null,            -- display time, e.g. '4:30 PM'
  sort_order  int  not null default 0,
  title       text not null,
  detail      text,
  created_at  timestamptz not null default now()
);
create index on timeline_items (event_id, sort_order);

create table checklist_items (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  event_id    uuid not null references events(id) on delete cascade,
  label       text not null,
  category    text,
  done        boolean not null default false,
  due_date    date,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);
create index on checklist_items (event_id, done);

create table budget_lines (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  event_id    uuid not null references events(id) on delete cascade,
  category    text not null,
  estimated   numeric(12,2) not null default 0,
  actual      numeric(12,2) not null default 0,
  sort_order  int not null default 0
);
create index on budget_lines (event_id);

-- ---------- guests & seating ----------
create table seating_tables (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  event_id    uuid not null references events(id) on delete cascade,
  name        text not null,
  seats       int not null default 8 check (seats > 0),
  sort_order  int not null default 0
);
create index on seating_tables (event_id);

create type rsvp_status as enum ('invited','pending','yes','no');

create table guests (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  event_id    uuid not null references events(id) on delete cascade,
  table_id    uuid references seating_tables(id) on delete set null,
  name        text not null,
  party       text,
  side        text,
  rsvp        rsvp_status not null default 'invited',
  meal        text,
  dietary     text,
  email       text,
  plus_ones   int not null default 0,
  created_at  timestamptz not null default now()
);
create index on guests (event_id, rsvp);
create index on guests (table_id);

-- ---------- vendors ----------
create type vendor_status as enum ('quote','contract-out','booked','passed');

create table vendors (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  event_id    uuid references events(id) on delete set null,
  name        text not null,
  category    text,
  contact     text,
  email       text,
  phone       text,
  status      vendor_status not null default 'quote',
  fee         numeric(12,2) not null default 0,
  notes       text,
  created_at  timestamptz not null default now()
);
create index on vendors (org_id, status);

-- ---------- invoicing ----------
create type invoice_status as enum ('draft','sent','due','paid','overdue','void');

create table invoices (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  event_id    uuid references events(id) on delete set null,
  lead_id     uuid references leads(id) on delete set null,
  number      text not null,
  client_name text not null,
  amount      numeric(12,2) not null default 0,
  due_date    date,
  paid_at     timestamptz,
  status      invoice_status not null default 'draft',
  created_at  timestamptz not null default now(),
  unique (org_id, number)
);
create index on invoices (org_id, status);

-- ---------- client portal access ----------
-- Lets a couple sign in and see ONLY their own event.
create table event_clients (
  event_id    uuid not null references events(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  org_id      uuid not null references orgs(id) on delete cascade,
  can_edit    boolean not null default false,
  created_at  timestamptz not null default now(),
  primary key (event_id, user_id)
);
create index on event_clients (user_id);

-- ---------- updated_at triggers ----------
create or replace function touch_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create trigger leads_touch  before update on leads  for each row execute function touch_updated_at();
create trigger events_touch before update on events for each row execute function touch_updated_at();
