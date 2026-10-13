-- ============================================================
-- GEM · 29 — more than one person at the same company
-- Run AFTER 28_sync_version_required.sql. Safe to re-run.
--
-- A vendor held exactly one contact name, email and phone; a venue held
-- exactly one coordinator. Real suppliers are small teams — the owner who
-- quotes, the coordinator who runs the day, the account that sends the
-- invoice — and planners were putting the second name in the notes field,
-- where nothing could dial it and no contact sheet could print it.
--
-- `people` is the list, jsonb beside spaces and address for the same reason
-- those are: it travels with its record, it is never queried across records,
-- and a row per contact would buy nothing but a join.
--
--   [{id, name, role, email, phone, note}, …]
--
-- The FIRST entry is the primary, and the app mirrors it back onto the
-- existing contact/email/phone columns on every write. Nothing that reads
-- those columns has to change — exports, the client bible, the directory and
-- the sync payload all keep working — and a studio that has not loaded the
-- new build yet still sees the right single contact.
-- ============================================================

alter table vendors add column if not exists people jsonb not null default '[]'::jsonb;
alter table venues  add column if not exists people jsonb not null default '[]'::jsonb;

-- A list, never an object: the app indexes [0] for the primary and would read
-- a stray object as an empty team without complaining.
alter table vendors drop constraint if exists vendors_people_is_array;
alter table vendors add  constraint vendors_people_is_array
  check (jsonb_typeof(people) = 'array');

alter table venues drop constraint if exists venues_people_is_array;
alter table venues add  constraint venues_people_is_array
  check (jsonb_typeof(people) = 'array');

-- Backfill from the single contact each record already had, so the first sync
-- after this does not look like every supplier lost their contact. Only where
-- there is something to carry: an empty contact becomes an empty list, not a
-- blank person nobody can tell apart from a real one.
update vendors
   set people = jsonb_build_array(jsonb_build_object(
         'id',    gen_random_uuid()::text,
         'name',  coalesce(contact,''),
         'role',  '',
         'email', coalesce(email,''),
         'phone', coalesce(phone,''),
         'note',  ''))
 where jsonb_array_length(people) = 0
   and (coalesce(contact,'') <> '' or coalesce(email,'') <> '' or coalesce(phone,'') <> '');

update venues
   set people = jsonb_build_array(jsonb_build_object(
         'id',    gen_random_uuid()::text,
         'name',  coalesce(contact->>'name',''),
         'role',  coalesce(contact->>'role',''),
         'email', coalesce(contact->>'email',''),
         'phone', coalesce(contact->>'phone',''),
         'note',  ''))
 where jsonb_array_length(people) = 0
   and coalesce(contact->>'name','') <> '';
