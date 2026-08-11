-- ============================================================
-- GEM · Row-Level Security
-- Run AFTER 01_schema.sql.
--
-- Model:
--   * Staff  — a row in org_members; sees everything in their org.
--   * Client — a couple/host with a row in event_clients; sees ONLY
--              their own event and its child records. Never sees
--              leads, vendor fees, other events, or the pipeline.
--
-- Every table below is deny-by-default: RLS is enabled and no row is
-- reachable unless a policy grants it.
-- ============================================================

-- ---------- helpers ----------
-- SECURITY DEFINER so these can read membership tables without
-- re-triggering RLS (which would recurse). search_path is pinned so a
-- caller cannot shadow the referenced tables.

create or replace function gem_is_org_member(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from org_members m
    where m.org_id = p_org and m.user_id = auth.uid()
  );
$$;

create or replace function gem_has_org_role(p_org uuid, p_roles org_role[])
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from org_members m
    where m.org_id = p_org
      and m.user_id = auth.uid()
      and m.role = any(p_roles)
  );
$$;

-- Client portal: is the current user attached to this event?
create or replace function gem_is_event_client(p_event uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from event_clients c
    where c.event_id = p_event and c.user_id = auth.uid()
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
    select 1 from event_clients c
    where c.event_id = p_event and c.user_id = auth.uid() and c.can_edit
  );
$$;

-- Staff-or-client read gate for anything hanging off an event.
create or replace function gem_can_read_event(p_org uuid, p_event uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select gem_is_org_member(p_org) or gem_is_event_client(p_event);
$$;

revoke execute on function gem_is_org_member(uuid)          from public, anon;
revoke execute on function gem_has_org_role(uuid, org_role[]) from public, anon;
revoke execute on function gem_is_event_client(uuid)        from public, anon;
revoke execute on function gem_client_can_edit(uuid)        from public, anon;
revoke execute on function gem_can_read_event(uuid, uuid)   from public, anon;
grant execute on function gem_is_org_member(uuid)           to authenticated;
grant execute on function gem_has_org_role(uuid, org_role[]) to authenticated;
grant execute on function gem_is_event_client(uuid)         to authenticated;
grant execute on function gem_client_can_edit(uuid)         to authenticated;
grant execute on function gem_can_read_event(uuid, uuid)    to authenticated;

-- ---------- enable RLS everywhere ----------
alter table orgs            enable row level security;
alter table org_members     enable row level security;
alter table leads           enable row level security;
alter table events          enable row level security;
alter table timeline_items  enable row level security;
alter table checklist_items enable row level security;
alter table budget_lines    enable row level security;
alter table seating_tables  enable row level security;
alter table guests          enable row level security;
alter table vendors         enable row level security;
alter table invoices        enable row level security;
alter table event_clients   enable row level security;

-- Force RLS even for the table owner, so a mistaken connection as the
-- owning role cannot quietly read across tenants.
alter table leads           force row level security;
alter table events          force row level security;
alter table guests          force row level security;
alter table invoices        force row level security;
alter table vendors         force row level security;

-- ---------- orgs ----------
create policy orgs_read on orgs
  for select to authenticated
  using (gem_is_org_member(id));

create policy orgs_update on orgs
  for update to authenticated
  using (gem_has_org_role(id, array['owner']::org_role[]))
  with check (gem_has_org_role(id, array['owner']::org_role[]));

-- ---------- org_members ----------
-- Direct `user_id = auth.uid()` (no helper) — reading your own row must
-- not depend on a function that reads this same table.
create policy members_read_self on org_members
  for select to authenticated
  using (user_id = auth.uid());

create policy members_read_org on org_members
  for select to authenticated
  using (gem_is_org_member(org_id));

create policy members_manage on org_members
  for all to authenticated
  using (gem_has_org_role(org_id, array['owner']::org_role[]))
  with check (gem_has_org_role(org_id, array['owner']::org_role[]));

-- ---------- leads (staff only — clients never see the pipeline) ----------
create policy leads_all on leads
  for all to authenticated
  using (gem_is_org_member(org_id))
  with check (gem_is_org_member(org_id));

-- ---------- events ----------
create policy events_read on events
  for select to authenticated
  using (gem_is_org_member(org_id) or gem_is_event_client(id));

create policy events_write on events
  for all to authenticated
  using (gem_is_org_member(org_id))
  with check (gem_is_org_member(org_id));

-- ---------- event children: staff full, client read (+ optional edit) ----------
create policy timeline_read on timeline_items
  for select to authenticated using (gem_can_read_event(org_id, event_id));
create policy timeline_write on timeline_items
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

create policy checklist_read on checklist_items
  for select to authenticated using (gem_can_read_event(org_id, event_id));
create policy checklist_write on checklist_items
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

-- Budget: staff only. Clients should not see internal margins.
create policy budget_all on budget_lines
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

create policy tables_read on seating_tables
  for select to authenticated using (gem_can_read_event(org_id, event_id));
create policy tables_write on seating_tables
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

-- Guests: couples typically DO manage their own list, so a client with
-- can_edit may write. Staff always may.
create policy guests_read on guests
  for select to authenticated using (gem_can_read_event(org_id, event_id));
create policy guests_insert on guests
  for insert to authenticated
  with check (gem_is_org_member(org_id) or gem_client_can_edit(event_id));
create policy guests_update on guests
  for update to authenticated
  using (gem_is_org_member(org_id) or gem_client_can_edit(event_id))
  with check (gem_is_org_member(org_id) or gem_client_can_edit(event_id));
create policy guests_delete on guests
  for delete to authenticated
  using (gem_is_org_member(org_id) or gem_client_can_edit(event_id));

-- Vendors: staff only (fees are commercially sensitive).
create policy vendors_all on vendors
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

-- Invoices: staff full; a client may read their own event's invoices.
create policy invoices_read on invoices
  for select to authenticated
  using (
    gem_is_org_member(org_id)
    or (event_id is not null and gem_is_event_client(event_id))
  );
create policy invoices_write on invoices
  for all to authenticated
  using (gem_has_org_role(org_id, array['owner','planner']::org_role[]))
  with check (gem_has_org_role(org_id, array['owner','planner']::org_role[]));

-- ---------- event_clients ----------
create policy event_clients_read on event_clients
  for select to authenticated
  using (user_id = auth.uid() or gem_is_org_member(org_id));
create policy event_clients_manage on event_clients
  for all to authenticated
  using (gem_has_org_role(org_id, array['owner','planner']::org_role[]))
  with check (gem_has_org_role(org_id, array['owner','planner']::org_role[]));

-- ---------- bootstrap: creating an org makes you its owner ----------
create or replace function gem_create_org(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  insert into orgs (name) values (p_name) returning id into v_id;
  insert into org_members (org_id, user_id, role) values (v_id, auth.uid(), 'owner');
  return v_id;
end $$;

revoke execute on function gem_create_org(text) from public, anon;
grant  execute on function gem_create_org(text) to authenticated;
