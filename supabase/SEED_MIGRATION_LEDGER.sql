-- Adopt an existing database into Supabase's migration ledger.
--
-- The twenty-one migrations in supabase/migrations were applied by hand in the
-- SQL editor long before the repo was connected, so Supabase has no record of
-- them. Without this, the integration treats all twenty-one as pending — and
-- 01-05 are not re-runnable, so the deploy would fail on the first one.
--
-- The ledger table itself does not exist until Supabase's own tooling applies
-- a migration for the first time, so this creates it. That is the same shape
-- the CLI creates; the extra nullable columns are what newer versions add, and
-- an unused nullable column cannot break anything.
--
-- Run once, in the SQL editor. Safe to re-run.

create schema if not exists supabase_migrations;

create table if not exists supabase_migrations.schema_migrations (
  version         text not null primary key,
  statements      text[],
  name            text,
  created_by      text,
  idempotency_key text
);

insert into supabase_migrations.schema_migrations (version, name)
values
  ('20260814100100','01_schema'),
  ('20260814100200','02_rls'),
  ('20260814100300','03_design_docs'),
  ('20260814100400','04_client_loop'),
  ('20260814100500','05_storage'),
  ('20260814100600','06_app_parity'),
  ('20260814100700','07_enum_parity'),
  ('20260814100800','08_photos_and_sync'),
  ('20260814100900','09_sync_fixes'),
  ('20260814101000','10_sub_events'),
  ('20260814101100','11_doc_labels'),
  ('20260814101200','12_event_roles'),
  ('20260814101300','13_task_owner'),
  ('20260814101400','14_client_invites'),
  ('20260814101500','15_event_types'),
  ('20260819101600','16_event_photos'),
  ('20260819101700','17_sync_two_phase'),
  ('20260819101800','18_sample_flag'),
  ('20260819101900','19_sync_runs'),
  ('20260819102000','20_client_cover'),
  ('20260819102100','21_venues')
on conflict (version) do nothing;

-- Expect 21 rows, ascending. Anything Supabase applies from here starts after
-- the last one.
select version, name from supabase_migrations.schema_migrations order by version;
