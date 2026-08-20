-- ============================================================
-- GEM · 26 — how a mood board is arranged
-- Run AFTER 25_guest_labels.sql. Safe to re-run.
--
-- A board is one composition, not three lists: a colour belongs between two
-- photographs if that is where the planner dragged it. Two things have to
-- survive that arrangement travelling to another device.
--
-- 1. A position that means the same thing across the three tables. Photos and
--    colours already had sort_order and notes did not, so notes get one. The
--    app writes a position that is unique across the WHOLE board once anything
--    has been arranged, which is also how the pull can tell an arranged board
--    from an old one: if every sort_order on the board is distinct, they are
--    wall positions; if they collide, they are the old per-list indexes and the
--    board is laid out photos-then-colours-then-notes as before.
--
-- 2. How wide a photograph is. One column or two — the only size a tile has,
--    because a colour chip does not need to be enormous and a note is as tall
--    as its sentence. A check keeps it to those two rather than letting a
--    future bug write 40 and blow the layout apart on every device at once.
-- ============================================================

alter table board_images add column if not exists span smallint not null default 1;

alter table board_images drop constraint if exists board_images_span_range;
alter table board_images add  constraint board_images_span_range
  check (span between 1 and 2);

alter table board_ideas add column if not exists sort_order int not null default 0;

create index if not exists board_ideas_order_idx on board_ideas (board_id, sort_order);

-- No policy changes: all three tables already carry org-scoped RLS from
-- 03_design_docs.sql and these are columns on rows those policies govern.

select
  (select count(*) from information_schema.columns
     where table_name = 'board_images' and column_name = 'span')        = 1 as image_span,
  (select count(*) from pg_constraint
     where conname = 'board_images_span_range')                         = 1 as span_check,
  (select count(*) from information_schema.columns
     where table_name = 'board_ideas' and column_name = 'sort_order')   = 1 as idea_order,
  (select count(*) from pg_indexes
     where indexname = 'board_ideas_order_idx')                         = 1 as idea_index,
  -- the other two already had one; this only makes sense if they still do
  (select count(*) from information_schema.columns
     where table_name = 'board_swatches' and column_name = 'sort_order') = 1 as swatch_order_still_there;
