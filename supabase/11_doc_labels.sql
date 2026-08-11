-- ============================================================
-- GEM · 11 — file the paperwork you already have
-- Run AFTER 10_sub_events.sql. Safe to re-run.
--
-- The app can attach a file to a document, but every document had to be one of
-- contract | proposal | other. A planner's folder is not shaped like that: it
-- holds the venue's floor plan and fire certificate, a vendor's COI, the
-- client's own inspiration deck, a permit, a rider. Filed as "other" they are
-- findable only by remembering the title.
--
-- doc_type is an enum, so a new label is not a UI change — an unknown value is
-- rejected on push and the document silently fails to sync. Widening it here is
-- what lets the upload button offer anything useful.
--
-- The labels mix kind (contract, proposal, invoice) with subject (venue,
-- vendor, client) deliberately. That is how the paperwork is actually filed:
-- nobody looks for "the proposal" — they look for "the venue's thing".
-- ============================================================

-- ALTER TYPE ... ADD VALUE is transaction-safe from Postgres 12 onwards as
-- long as the new value is not used in the same transaction, which is why this
-- can sit in a plain migration file rather than needing to be run statement by
-- statement.
alter type doc_type add value if not exists 'invoice';
alter type doc_type add value if not exists 'venue';
alter type doc_type add value if not exists 'vendor';
alter type doc_type add value if not exists 'client';
alter type doc_type add value if not exists 'insurance';
alter type doc_type add value if not exists 'permit';
alter type doc_type add value if not exists 'floorplan';
alter type doc_type add value if not exists 'timeline';


-- ---------- verify ----------
-- Expect 11 labels: the original three plus the eight above.
select
  (select count(*) from pg_enum e
     join pg_type t on t.oid = e.enumtypid
    where t.typname = 'doc_type')                                    as labels,
  (select array_agg(e.enumlabel order by e.enumsortorder)
     from pg_enum e join pg_type t on t.oid = e.enumtypid
    where t.typname = 'doc_type')                                    as all_labels,
  (select count(*) from pg_enum e
     join pg_type t on t.oid = e.enumtypid
    where t.typname = 'doc_type'
      and e.enumlabel in ('venue','vendor','client','insurance',
                          'permit','floorplan','invoice','timeline')) = 8 as new_labels;
