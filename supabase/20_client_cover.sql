-- ============================================================
-- GEM · 20 — a client file's own banner
-- Run AFTER 19_sync_runs.sql. Safe to re-run.
--
-- The client record already carries photo_path: a portrait, cropped to a
-- circle, shown as a tile in the card grid. The file's header was using that
-- same picture stretched across a wide band, which crops a phone photograph of
-- a couple straight through their faces. The header is now a separate picture
-- in its own shape (16:9, the same crop an event cover gets), defaulting to
-- the event's cover so nobody is asked for the same photograph twice.
--
-- Re-runnable. Adds one nullable column and nothing else — no policy changes,
-- because the object itself lives in the same gem-media bucket under the same
-- org/leads/<id> prefix that photo_path already uses, and is covered by the
-- storage policies from migration 05.
--
-- The client omits cover_path from its payload until it has seen the column,
-- so running this late is safe: covers simply do not sync until you do.

alter table public.leads add column if not exists cover_path text;

select
  exists (select 1 from information_schema.columns
          where table_schema='public' and table_name='leads'
            and column_name='cover_path')                        as cover_path_exists,
  exists (select 1 from information_schema.columns
          where table_schema='public' and table_name='leads'
            and column_name='photo_path')                        as photo_path_still_there;
