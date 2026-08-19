-- ============================================================
-- GEM · Batch D — Design Studio + Documents
-- Run AFTER 02_rls.sql.
--
-- Brings the schema back in line with the app: mood boards, board
-- images/swatches/ideas, the event colour palette, décor sign-off, and
-- the contracts/proposals the Documents module already renders.
--
-- Reference photos are NOT stored in the database. `storage_path` points
-- at an object in the `gem-media` Storage bucket; see 05_storage.sql.
-- ============================================================

-- ---------- design ----------
create table event_palette (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  event_id    uuid not null references events(id) on delete cascade,
  hex         text not null check (hex ~* '^#[0-9a-f]{6}$'),
  name        text not null,
  sort_order  int  not null default 0,
  created_at  timestamptz not null default now()
);
create index on event_palette (event_id, sort_order);

create table design_boards (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  event_id    uuid not null references events(id) on delete cascade,
  title       text not null,
  tone        text,                      -- CSS gradient used before a cover photo exists
  note        text,
  sort_order  int  not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on design_boards (event_id, sort_order);

create table board_images (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  board_id     uuid not null references design_boards(id) on delete cascade,
  event_id     uuid not null references events(id) on delete cascade,
  storage_path text not null,            -- object key in the gem-media bucket
  caption      text,
  width        int,
  height       int,
  bytes        int,
  sort_order   int not null default 0,
  created_at   timestamptz not null default now()
);
create index on board_images (board_id, sort_order);

create table board_swatches (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  board_id    uuid not null references design_boards(id) on delete cascade,
  hex         text not null check (hex ~* '^#[0-9a-f]{6}$'),
  name        text not null,
  sort_order  int  not null default 0
);
create index on board_swatches (board_id, sort_order);

create table board_ideas (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  board_id    uuid not null references design_boards(id) on delete cascade,
  body        text not null,
  created_at  timestamptz not null default now()
);
create index on board_ideas (board_id, created_at);

create type decor_status as enum ('sourcing','pending','approved','declined');

create table decor_items (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  event_id    uuid not null references events(id) on delete cascade,
  item        text not null,
  vendor      text,
  vendor_id   uuid references vendors(id) on delete set null,
  status      decor_status not null default 'sourcing',
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);
create index on decor_items (event_id, status);

-- ---------- documents ----------
create type doc_type   as enum ('contract','proposal','other');
create type doc_status as enum ('draft','sent','signed','declined','void');

create table documents (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  event_id    uuid references events(id) on delete cascade,
  lead_id     uuid references leads(id) on delete set null,
  title       text not null,
  type        doc_type   not null default 'proposal',
  status      doc_status not null default 'draft',
  amount      numeric(12,2) not null default 0,
  body        text,                       -- rendered terms shown to the signer
  sent_at     timestamptz,
  signed_at   timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on documents (org_id, status);
create index on documents (event_id);

create trigger boards_touch before update on design_boards for each row execute function touch_updated_at();
create trigger documents_touch before update on documents  for each row execute function touch_updated_at();

-- ---------- RLS ----------
alter table event_palette  enable row level security;
alter table design_boards  enable row level security;
alter table board_images   enable row level security;
alter table board_swatches enable row level security;
alter table board_ideas    enable row level security;
alter table decor_items    enable row level security;
alter table documents      enable row level security;
alter table documents      force  row level security;

-- Couples SEE the design work — that's the point of a mood board — but
-- only staff may change it.
create policy palette_read on event_palette
  for select to authenticated using (gem_can_read_event(org_id, event_id));
create policy palette_write on event_palette
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

create policy boards_read on design_boards
  for select to authenticated using (gem_can_read_event(org_id, event_id));
create policy boards_write on design_boards
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

create policy images_read on board_images
  for select to authenticated using (gem_can_read_event(org_id, event_id));
create policy images_write on board_images
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

-- Swatches and ideas hang off a board, so reachability follows the board.
create policy swatches_read on board_swatches
  for select to authenticated
  using (exists (select 1 from design_boards b
                 where b.id = board_id and gem_can_read_event(b.org_id, b.event_id)));
create policy swatches_write on board_swatches
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

create policy ideas_read on board_ideas
  for select to authenticated
  using (exists (select 1 from design_boards b
                 where b.id = board_id and gem_can_read_event(b.org_id, b.event_id)));
create policy ideas_write on board_ideas
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

-- Décor names vendors and pricing intent — staff only.
create policy decor_all on decor_items
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

-- A client sees their own documents, but never anything still in draft.
create policy documents_read on documents
  for select to authenticated
  using (
    gem_is_org_member(org_id)
    or (event_id is not null and gem_is_event_client(event_id) and status <> 'draft')
  );
create policy documents_write on documents
  for all to authenticated
  using (gem_has_org_role(org_id, array['owner','planner']::org_role[]))
  with check (gem_has_org_role(org_id, array['owner','planner']::org_role[]));
