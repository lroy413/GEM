-- Tell Supabase that the migrations in supabase/migrations are ALREADY
-- applied to this project. They were run by hand in the SQL editor before the
-- repo was connected, so Supabase's ledger has never heard of them.
--
-- Run this ONCE, in the SQL editor, BEFORE the first push that Supabase acts
-- on. Without it the integration treats all twenty-one as pending.
--
-- Safe to re-run: on conflict do nothing.

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

-- What the ledger holds now, in the order it will apply anything new:
select version, name from supabase_migrations.schema_migrations order by version;
