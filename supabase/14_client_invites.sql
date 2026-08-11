-- ============================================================
-- GEM · 14 — letting a couple into their own portal
-- Run AFTER 13_task_owner.sql. Safe to re-run.
--
-- event_clients has existed since migration 01 and RLS has always enforced it,
-- but NOTHING has ever written to it. A couple could sign in perfectly well and
-- see an empty app, because no row said which wedding was theirs. This is the
-- missing half.
--
-- The planner cannot do the linking from the browser: auth.users is not
-- readable by the anon key, so there is no way to turn an email address into a
-- user id client-side. So the invitation is stored against the EMAIL, and the
-- link is made server-side the first time that person signs in.
--
-- Seats: one shared login per couple, who may then invite one more person to
-- their own event. Two client seats per event, counted as claimed rows plus
-- outstanding invitations so the cap cannot be beaten by inviting twice.
-- ============================================================


-- ---------- 1 · the invitation ----------
create table if not exists event_client_invites (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id)   on delete cascade,
  event_id    uuid not null references events(id) on delete cascade,
  -- Lowercased on the way in; email comparison is case-insensitive and a
  -- mismatch here means an invitation that can never be claimed.
  email       text not null,
  can_edit    boolean not null default true,
  -- 'planner' invitations come from the studio, 'client' from the couple
  -- inviting their partner. Kept so the cap can tell them apart in support.
  source      text not null default 'planner' check (source in ('planner','client')),
  invited_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  claimed_at  timestamptz,
  claimed_by  uuid references auth.users(id) on delete set null,
  unique (event_id, email)
);
create index if not exists eci_email_idx on event_client_invites (lower(email)) where claimed_at is null;
create index if not exists eci_event_idx on event_client_invites (event_id);


-- ---------- 2 · how many people may see one event ----------
create or replace function gem_client_seats(p_event uuid)
returns int
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (select count(*) from event_clients c where c.event_id = p_event)
       + (select count(*) from event_client_invites i
           where i.event_id = p_event and i.claimed_at is null);
$$;

-- One shared login, plus one more the couple may add themselves.
create or replace function gem_client_seat_limit() returns int
language sql immutable as $$ select 2 $$;


-- ---------- 3 · the planner invites the couple ----------
create or replace function gem_invite_client(p_event uuid, p_email text, p_can_edit boolean default true)
returns event_client_invites
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_org uuid; v_email text; v_row event_client_invites;
begin
  v_email := lower(btrim(p_email));
  if v_email = '' or position('@' in v_email) = 0 then
    raise exception 'That does not look like an email address.' using errcode = '22023';
  end if;

  select org_id into v_org from events where id = p_event;
  if v_org is null then
    raise exception 'No such event.' using errcode = '23503';
  end if;
  if not gem_is_org_member(v_org) then
    raise exception 'Not permitted to invite to this event.' using errcode = '42501';
  end if;

  -- Re-inviting the same address is a resend, not a second seat.
  if not exists (select 1 from event_client_invites
                  where event_id = p_event and lower(email) = v_email)
     and gem_client_seats(p_event) >= gem_client_seat_limit() then
    raise exception 'This event already has % people with portal access.', gem_client_seat_limit()
      using errcode = '23505';
  end if;

  insert into event_client_invites (org_id, event_id, email, can_edit, source, invited_by)
  values (v_org, p_event, v_email, coalesce(p_can_edit, true), 'planner', auth.uid())
  on conflict (event_id, email) do update
    set can_edit = excluded.can_edit, invited_by = excluded.invited_by
  returning * into v_row;

  return v_row;
end $$;


-- ---------- 4 · the couple invites one more ----------
-- Called by a signed-in client, never by staff. They may only invite into an
-- event they themselves already have, and only up to the seat limit.
create or replace function gem_invite_partner(p_event uuid, p_email text)
returns event_client_invites
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_org uuid; v_email text; v_row event_client_invites;
begin
  v_email := lower(btrim(p_email));
  if v_email = '' or position('@' in v_email) = 0 then
    raise exception 'That does not look like an email address.' using errcode = '22023';
  end if;

  if not exists (select 1 from event_clients
                  where event_id = p_event and user_id = auth.uid()) then
    raise exception 'You do not have access to that event.' using errcode = '42501';
  end if;

  select org_id into v_org from events where id = p_event;

  if not exists (select 1 from event_client_invites
                  where event_id = p_event and lower(email) = v_email)
     and gem_client_seats(p_event) >= gem_client_seat_limit() then
    raise exception 'You can add one more person, and that seat is already taken.'
      using errcode = '23505';
  end if;

  -- A partner never gets more rights than the person who invited them.
  insert into event_client_invites (org_id, event_id, email, can_edit, source, invited_by)
  values (v_org, p_event, v_email,
          (select can_edit from event_clients where event_id = p_event and user_id = auth.uid()),
          'client', auth.uid())
  on conflict (event_id, email) do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from event_client_invites
     where event_id = p_event and lower(email) = v_email;
  end if;
  return v_row;
end $$;


-- ---------- 5 · claiming, on first sign-in ----------
-- The app calls this after every sign-in. It matches on the address in the
-- caller's own token, so one person cannot claim another's invitation.
create or replace function gem_claim_client_invites()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_email text; v_n int := 0;
begin
  v_email := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  if v_email = '' then return 0; end if;

  insert into event_clients (event_id, user_id, org_id, can_edit)
  select i.event_id, auth.uid(), i.org_id, i.can_edit
    from event_client_invites i
   where lower(i.email) = v_email
     and i.claimed_at is null
  on conflict (event_id, user_id) do nothing;

  update event_client_invites
     set claimed_at = now(), claimed_by = auth.uid()
   where lower(email) = v_email and claimed_at is null;
  get diagnostics v_n = row_count;

  return v_n;
end $$;


-- ---------- 6 · revoking ----------
create or replace function gem_revoke_client(p_event uuid, p_email text)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_org uuid; v_email text; v_n int := 0;
begin
  v_email := lower(btrim(p_email));
  select org_id into v_org from events where id = p_event;
  if not gem_is_org_member(v_org) then
    raise exception 'Not permitted.' using errcode = '42501';
  end if;

  -- The claimed access goes as well as the invitation, or revoking does
  -- nothing to someone who has already signed in.
  delete from event_clients c
   using event_client_invites i
   where i.event_id = p_event and lower(i.email) = v_email
     and c.event_id = i.event_id and c.user_id = i.claimed_by;
  delete from event_client_invites
   where event_id = p_event and lower(email) = v_email;
  get diagnostics v_n = row_count;
  return v_n;
end $$;


-- ---------- 7 · row-level security ----------
alter table event_client_invites enable row level security;
alter table event_client_invites force  row level security;

-- Staff see their studio's invitations; a couple sees only their own address,
-- so the portal can show "you invited x@y" without exposing the guest list of
-- every other wedding.
drop policy if exists eci_read on event_client_invites;
create policy eci_read on event_client_invites
  for select to authenticated
  using (gem_is_org_member(org_id)
         or lower(email) = lower(coalesce(auth.jwt() ->> 'email',''))
         or gem_is_event_client(event_id));

-- All writes go through the functions above, which check the caller and the
-- seat limit. No direct insert or update.
drop policy if exists eci_no_direct_write on event_client_invites;
create policy eci_no_direct_write on event_client_invites
  for all to authenticated using (false) with check (false);

revoke execute on function gem_invite_client(uuid, text, boolean) from public, anon;
revoke execute on function gem_invite_partner(uuid, text)         from public, anon;
revoke execute on function gem_claim_client_invites()             from public, anon;
revoke execute on function gem_revoke_client(uuid, text)          from public, anon;
revoke execute on function gem_client_seats(uuid)                 from public, anon;
grant  execute on function gem_invite_client(uuid, text, boolean) to authenticated;
grant  execute on function gem_invite_partner(uuid, text)         to authenticated;
grant  execute on function gem_claim_client_invites()             to authenticated;
grant  execute on function gem_revoke_client(uuid, text)          to authenticated;
grant  execute on function gem_client_seats(uuid)                 to authenticated;


-- ---------- verify ----------
select
  (select count(*) from information_schema.tables
     where table_name = 'event_client_invites')                        = 1 as invites_table,
  (select count(*) from pg_proc where proname in
     ('gem_invite_client','gem_invite_partner','gem_claim_client_invites',
      'gem_revoke_client','gem_client_seats','gem_client_seat_limit'))  = 6 as functions,
  (select count(*) from pg_policies
     where tablename = 'event_client_invites')                          = 2 as policies,
  (select relrowsecurity and relforcerowsecurity from pg_class
     where relname = 'event_client_invites')                                as rls_forced,
  (select gem_client_seat_limit())                                      = 2 as seat_limit_two;
