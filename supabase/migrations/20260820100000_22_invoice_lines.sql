-- ============================================================
-- GEM · 22 — an invoice is a document, not a ledger line
-- Run AFTER 21_venues.sql. Safe to re-run.
--
-- invoices carried a number, a client, one amount and a status. That is a row
-- in a report, not a thing you send: no lines, no tax, no terms, no record of
-- what has been paid against it. The app now builds a real invoice out of its
-- lines and derives the total from them, so those lines have to survive a pull
-- or the second device shows an invoice with a total and nothing under it.
--
-- Everything here is additive and nullable. `amount` stays authoritative and
-- keeps being written on every push — every existing reader (the dashboard
-- alert, the CSV export, the stat row) reads it, and an invoice whose stored
-- total disagreed with its own lines would be worse than one with no lines.
--
-- jsonb rather than an invoice_lines table on purpose. A line has no identity
-- of its own — nothing references it, nothing joins to it, and it is only ever
-- read as part of the invoice it belongs to. The same reasoning the floor plan
-- items and questionnaire answers already follow.
-- ============================================================

alter table invoices add column if not exists issued_date date;
alter table invoices add column if not exists notes       text        not null default '';
alter table invoices add column if not exists tax_rate    numeric(7,3) not null default 0;
alter table invoices add column if not exists items       jsonb       not null default '[]'::jsonb;
alter table invoices add column if not exists payments    jsonb       not null default '[]'::jsonb;
alter table invoices add column if not exists pay_link    text        not null default '';

-- The link between a document and the invoice it raised, in ONE direction.
-- Both directions would be a circular foreign key: the push upserts a table at
-- a time, so whichever went first would name a row that does not exist yet and
-- fail the whole table. Documents are upserted after invoices, so the pointer
-- lives on the document and the app rebuilds the other side on pull.
--
-- ON DELETE SET NULL, not CASCADE: deleting the paperwork must never delete
-- the money, and an invoice may carry payments the file knows nothing about.
alter table documents add column if not exists invoice_id uuid
  references invoices(id) on delete set null;

-- Looked up by the row that points at it, never scanned.
create index if not exists documents_invoice_idx on documents(invoice_id)
  where invoice_id is not null;

-- A jsonb column that is not an array will break the app's reduce() rather
-- than the database's insert, so refuse it here where the error is legible.
alter table invoices drop constraint if exists invoices_items_is_array;
alter table invoices add  constraint invoices_items_is_array
  check (jsonb_typeof(items) = 'array');
alter table invoices drop constraint if exists invoices_payments_is_array;
alter table invoices add  constraint invoices_payments_is_array
  check (jsonb_typeof(payments) = 'array');

-- No new policies: both tables already carry org-scoped RLS from 02_rls.sql,
-- and these are columns on rows those policies already govern. A couple reads
-- invoices through the same client policy as before — which is why the app
-- keeps drafts off the portal itself rather than relying on the database to.

select
  (select count(*) from information_schema.columns
     where table_name = 'invoices' and column_name = 'items')        = 1 as invoice_items,
  (select count(*) from information_schema.columns
     where table_name = 'invoices' and column_name = 'payments')     = 1 as invoice_payments,
  (select count(*) from information_schema.columns
     where table_name = 'invoices' and column_name = 'issued_date')  = 1 as issued_date,
  (select count(*) from information_schema.columns
     where table_name = 'invoices' and column_name = 'tax_rate')     = 1 as tax_rate,
  (select count(*) from information_schema.columns
     where table_name = 'documents' and column_name = 'invoice_id')  = 1 as document_invoice,
  (select count(*) from information_schema.columns
     where table_name = 'invoices' and column_name = 'document_id')  = 0 as no_reverse_link,
  (select count(*) from pg_constraint
     where conname = 'invoices_items_is_array')                      = 1 as items_array_check,
  (select count(*) from pg_indexes
     where indexname = 'documents_invoice_idx')                      = 1 as document_index;
