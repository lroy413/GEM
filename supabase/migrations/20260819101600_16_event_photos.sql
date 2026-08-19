-- ============================================================
-- GEM · 16 — every event gets its own photograph
-- Run AFTER 15_event_types.sql. Safe to re-run.
--
-- The dashboard hero has drawn a photograph since the card stack landed, but
-- the only one available was leads.photo — the client's. A weekend is one
-- client and several events, so the deck showed the same picture four times:
-- the welcome party, the ceremony and the farewell brunch all wearing the
-- engagement portrait. The stack exists to make four events look like four
-- events, and a repeated image undoes exactly that.
--
-- events.photo_path is the other half. The app resolves a cover in the order
-- a planner would expect — the event's own, then its primary's, then the
-- client's — so a weekend photographed once still looks right everywhere and
-- a studio that shoots each night can say so.
--
-- No storage changes are needed. The object key is <org>/<eventId>/<eventId>,
-- which is the same shape as an existing board image, so the policies from
-- 05 and 08 already cover it: staff by org membership on the first path
-- segment, and that event's couple by gem_is_event_client() on the second.
-- Since 10 that function reaches through parent_event_id, so a couple
-- attached only to the primary can also see the rehearsal dinner's cover.
-- ============================================================


-- ---------- 1 · the column ----------
-- Nullable with no default: most events will never have one, and the app
-- reads null as "borrow the primary's, then the client's" rather than as an
-- error. Plain text, like leads.photo_path — it holds an object key inside
-- the gem-media bucket, not a URL, because URLs are signed per request.
alter table events add column if not exists photo_path text;

comment on column events.photo_path is
  'Object key in the private gem-media bucket, <org>/<eventId>/<eventId>, or '
  'null. The event''s own cover photo. Null means the app falls back to the '
  'primary event''s cover and then to leads.photo_path.';


-- ---------- verify ----------
select
  (select count(*) from information_schema.columns
     where table_name = 'events' and column_name = 'photo_path')          = 1 as photo_path_col,
  (select is_nullable = 'YES' from information_schema.columns
     where table_name = 'events' and column_name = 'photo_path')              as photo_path_nullable,
  -- The policies this column leans on, unchanged since 08.
  (select count(*) from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname like 'gem media%')                                  = 4 as media_policies,
  -- 10 redefined this to reach through parent_event_id; a sub-event's cover
  -- is only visible to the couple because it still does.
  (select count(*) from pg_proc where proname = 'gem_is_event_client')    >= 1 as client_fn_present,
  (select count(*) from events where photo_path is not null)                  as covers_set;
