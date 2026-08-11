-- ============================================================
-- GEM · Batch B — Closing the client loop
-- Run AFTER 03_design_docs.sql.
--
--   questionnaires  — intake forms a planner sends to a couple
--   lead_forms      — a PUBLIC capture form that creates leads
--   signatures      — the real signing record behind documents
--   messages        — a per-event thread between planner and couple
--
-- Note the deliberate asymmetry: lead_forms and their submissions are the
-- only place `anon` may touch anything, and even there it is INSERT-only
-- into a single table.
-- ============================================================

-- ---------- questionnaires ----------
create type questionnaire_status as enum ('draft','sent','partial','complete');
create type question_kind as enum ('short_text','long_text','choice','multi_choice','date','number','yes_no');

create table questionnaires (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  event_id    uuid references events(id) on delete cascade,
  lead_id     uuid references leads(id) on delete set null,
  title       text not null,
  intro       text,
  status      questionnaire_status not null default 'draft',
  sent_at     timestamptz,
  completed_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on questionnaires (org_id, status);
create index on questionnaires (event_id);

create table questions (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references orgs(id) on delete cascade,
  questionnaire_id uuid not null references questionnaires(id) on delete cascade,
  prompt           text not null,
  kind             question_kind not null default 'short_text',
  options          jsonb not null default '[]'::jsonb,   -- for choice kinds
  required         boolean not null default false,
  sort_order       int not null default 0
);
create index on questions (questionnaire_id, sort_order);

create table answers (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references orgs(id) on delete cascade,
  questionnaire_id uuid not null references questionnaires(id) on delete cascade,
  question_id      uuid not null references questions(id) on delete cascade,
  event_id         uuid references events(id) on delete cascade,
  value            text,
  answered_by      uuid references auth.users(id) on delete set null,
  answered_at      timestamptz not null default now(),
  unique (question_id, answered_by)
);
create index on answers (questionnaire_id);

-- ---------- public lead capture ----------
create table lead_forms (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  slug        text not null unique,       -- gimmerevents.com/inquire/<slug>
  title       text not null,
  intro       text,
  fields      jsonb not null default '[]'::jsonb,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create type submission_status as enum ('new','converted','archived','spam');

create table form_submissions (
  id          uuid primary key default gen_random_uuid(),
  form_id     uuid not null references lead_forms(id) on delete cascade,
  org_id      uuid not null references orgs(id) on delete cascade,
  payload     jsonb not null default '{}'::jsonb,
  names       text,
  email       text,
  phone       text,
  event_date  date,
  status      submission_status not null default 'new',
  lead_id     uuid references leads(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index on form_submissions (org_id, status);

-- ---------- signatures ----------
create table signatures (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  document_id  uuid not null references documents(id) on delete cascade,
  event_id     uuid references events(id) on delete cascade,
  signer_name  text not null,             -- typed, as consented to
  signer_email text,
  signed_by    uuid references auth.users(id) on delete set null,
  user_agent   text,
  signed_at    timestamptz not null default now(),
  unique (document_id, signed_by)
);
create index on signatures (document_id);

-- ---------- messages ----------
create type sender_role as enum ('planner','client');

create table messages (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete cascade,
  event_id    uuid not null references events(id) on delete cascade,
  sender_id   uuid references auth.users(id) on delete set null,
  sender_role sender_role not null,
  sender_name text not null,
  body        text not null check (length(btrim(body)) > 0),
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index on messages (event_id, created_at);

-- ---------- RLS ----------
alter table questionnaires   enable row level security;
alter table questions        enable row level security;
alter table answers          enable row level security;
alter table lead_forms       enable row level security;
alter table form_submissions enable row level security;
alter table signatures       enable row level security;
alter table messages         enable row level security;
alter table form_submissions force row level security;
alter table signatures       force row level security;

-- Questionnaires: staff manage; a client sees theirs once sent.
create policy q_read on questionnaires
  for select to authenticated
  using (
    gem_is_org_member(org_id)
    or (event_id is not null and gem_is_event_client(event_id) and status <> 'draft')
  );
create policy q_write on questionnaires
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

create policy questions_read on questions
  for select to authenticated
  using (exists (select 1 from questionnaires q
                 where q.id = questionnaire_id
                   and (gem_is_org_member(q.org_id)
                        or (q.event_id is not null and gem_is_event_client(q.event_id) and q.status <> 'draft'))));
create policy questions_write on questions
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

-- The couple answers; staff read. A client may only write their OWN answer
-- row, and only for a questionnaire attached to their event.
create policy answers_read on answers
  for select to authenticated
  using (gem_is_org_member(org_id)
         or (event_id is not null and gem_is_event_client(event_id)));
create policy answers_client_insert on answers
  for insert to authenticated
  with check (
    answered_by = auth.uid()
    and event_id is not null
    and gem_is_event_client(event_id)
  );
create policy answers_client_update on answers
  for update to authenticated
  using (answered_by = auth.uid() and event_id is not null and gem_is_event_client(event_id))
  with check (answered_by = auth.uid());
create policy answers_staff_write on answers
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

-- Lead forms: staff manage. The public may READ an active form (to render
-- it) and INSERT a submission — nothing else.
create policy forms_staff on lead_forms
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));
create policy forms_public_read on lead_forms
  for select to anon using (active);

create policy submissions_staff on form_submissions
  for all to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));
create policy submissions_public_insert on form_submissions
  for insert to anon
  with check (
    status = 'new' and lead_id is null
    and exists (select 1 from lead_forms f
                where f.id = form_id and f.active and f.org_id = form_submissions.org_id)
  );
-- anon may insert but must never read back what others submitted.

-- Signatures: staff read; the client signs once, as themselves.
create policy sig_read on signatures
  for select to authenticated
  using (gem_is_org_member(org_id)
         or (event_id is not null and gem_is_event_client(event_id)));
create policy sig_client_insert on signatures
  for insert to authenticated
  with check (
    signed_by = auth.uid()
    and event_id is not null
    and gem_is_event_client(event_id)
    and exists (select 1 from documents d
                where d.id = document_id and d.status = 'sent' and d.event_id = signatures.event_id)
  );
create policy sig_staff_write on signatures
  for all to authenticated
  using (gem_has_org_role(org_id, array['owner','planner']::org_role[]))
  with check (gem_has_org_role(org_id, array['owner','planner']::org_role[]));

-- Messages: both sides of the thread, each posting only as themselves.
create policy msg_read on messages
  for select to authenticated
  using (gem_is_org_member(org_id) or gem_is_event_client(event_id));
create policy msg_staff_insert on messages
  for insert to authenticated
  with check (gem_is_org_member(org_id) and sender_role = 'planner' and sender_id = auth.uid());
create policy msg_client_insert on messages
  for insert to authenticated
  with check (gem_is_event_client(event_id) and sender_role = 'client' and sender_id = auth.uid());
create policy msg_staff_manage on messages
  for update to authenticated
  using (gem_is_org_member(org_id)) with check (gem_is_org_member(org_id));

create trigger questionnaires_touch before update on questionnaires
  for each row execute function touch_updated_at();

-- ---------- signing, atomically ----------
-- Recording a signature and flipping the document must not half-apply.
create or replace function gem_sign_document(p_document uuid, p_name text)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_doc documents%rowtype; v_at timestamptz := now();
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_doc from documents where id = p_document;
  if not found then raise exception 'document not found'; end if;
  if v_doc.status <> 'sent' then raise exception 'document is not awaiting signature'; end if;
  if v_doc.event_id is null or not gem_is_event_client(v_doc.event_id) then
    raise exception 'not permitted to sign this document';
  end if;
  if btrim(coalesce(p_name,'')) = '' then raise exception 'a signature name is required'; end if;

  insert into signatures (org_id, document_id, event_id, signer_name, signed_by, signed_at)
  values (v_doc.org_id, v_doc.id, v_doc.event_id, btrim(p_name), auth.uid(), v_at)
  on conflict (document_id, signed_by) do nothing;

  update documents set status = 'signed', signed_at = v_at where id = v_doc.id;
  return v_at;
end $$;

revoke execute on function gem_sign_document(uuid, text) from public, anon;
grant  execute on function gem_sign_document(uuid, text) to authenticated;
