-- ============================================================
-- GEM · 27 — the budget envelope
-- Run AFTER 26_board_arrangement.sql. Safe to re-run.
--
-- A budget used to be a list that added itself up: a category, an estimate
-- and an actual. The total was whatever the lines came to, so there was no
-- ceiling — and with no ceiling there is no UNALLOCATED, which is the number
-- a planner actually works from and the only thing that makes moving money
-- between categories a meaningful act rather than two unrelated edits.
--
-- Three groups of columns.
--
-- 1. The envelope itself, on the EVENT. One number per job: a planner quotes
--    a weekend as one budget, the same reason budget lines already hang off
--    the primary event and tag their sub-event rather than splitting.
--    budget_moves is the reallocation ledger, jsonb beside floor and
--    venue_address, because a move is only legible next to the two lines it
--    names. The app caps it at 200 entries so the row cannot grow forever.
--
-- 2. The third money column. `actual` conflated "contracted" with "paid",
--    which is why the budget could never answer what is owed or when. paid
--    and due_date separate them.
--
-- 3. What a line is FOR. group_key files it so a budget can roll up and a
--    template can propose a split; vendor_id backs it with a real booking;
--    per_head lets catering follow the guest list; client_visible and markup
--    are the private layer — both are written from now on, and neither is
--    read until the client portal work, so switching that on later costs no
--    second migration.
-- ============================================================

alter table budget_lines add column if not exists paid           numeric(12,2) not null default 0;
alter table budget_lines add column if not exists due_date       date;
alter table budget_lines add column if not exists vendor_id      uuid references vendors(id) on delete set null;
alter table budget_lines add column if not exists per_head       numeric(12,2);
alter table budget_lines add column if not exists client_visible boolean not null default true;
alter table budget_lines add column if not exists markup         numeric(12,2);
alter table budget_lines add column if not exists note           text not null default '';
alter table budget_lines add column if not exists group_key      text;

alter table events add column if not exists budget_total    numeric(12,2);
alter table events add column if not exists contingency_pct numeric(5,2) not null default 8;
alter table events add column if not exists budget_moves    jsonb not null default '[]'::jsonb;

-- A budget line is looked up by what it is owed and when far more often than
-- by anything else once cash flow lands, and always within one event.
create index if not exists budget_lines_due_idx on budget_lines (event_id, due_date);

-- Money is never negative here: a line that costs less is a smaller number,
-- not a credit. A check catches the sign error at the door rather than
-- letting one bad write quietly drag a studio's totals.
alter table budget_lines drop constraint if exists budget_lines_money_positive;
alter table budget_lines add  constraint budget_lines_money_positive
  check (estimated >= 0 and actual >= 0 and paid >= 0
         and (per_head is null or per_head >= 0));

alter table events drop constraint if exists events_budget_total_positive;
alter table events add  constraint events_budget_total_positive
  check (budget_total is null or budget_total >= 0);

alter table events drop constraint if exists events_contingency_range;
alter table events add  constraint events_contingency_range
  check (contingency_pct >= 0 and contingency_pct <= 90);

-- Existing rows predate group_key, so file them the way the app does on load.
-- Deliberately crude and deliberately additive: the line KEEPS its own name,
-- and anything unrecognised lands in 'other' where it is visible and editable
-- rather than guessed at.
update budget_lines set group_key = case
  when group_key is not null and group_key <> '' then group_key
  when category ~* '(cater|food|bar|drink|beverage|cake)'          then 'food'
  when category ~* '(venue|hall|rental|tent|marquee|linen|chair)'  then 'venue'
  when category ~* '(photo|video|film|cinema)'                     then 'media'
  when category ~* '(floral|flower|decor|décor|design|styling)'    then 'decor'
  when category ~* '(music|band|dj|entertain)'                     then 'music'
  when category ~* '(attire|dress|suit|beauty|hair|makeup)'        then 'attire'
  when category ~* '(station|invit|paper|signage|calligraph)'      then 'paper'
  when category ~* '(staff|planning|planner|fee|coordinat)'        then 'staff'
  when category ~* '(travel|transport|shuttle|hotel|accommodat)'   then 'travel'
  when category ~* '(conting|reserve|buffer|misc)'                 then 'reserve'
  else 'other' end
where group_key is null or group_key = '';
