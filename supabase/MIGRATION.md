# GEM → Supabase migration

Run these **in order** — later files depend on helpers defined earlier:

| File | What it does |
|---|---|
| `01_schema.sql` | Core tables, enums, indexes, `updated_at` triggers |
| `02_rls.sql` | Row-level security + helper functions + `gem_create_org()` |
| `03_design_docs.sql` | Mood boards, images, swatches, ideas, palette, décor, documents |
| `04_client_loop.sql` | Questionnaires, lead capture, signatures, messages + `gem_sign_document()` |
| `05_storage.sql` | Private `gem-media` bucket + per-org object policies |
| `gem-api.js` | Client data layer — returns the prototype's exact `db` shape |

**26 tables, 60 policies.** Every table is RLS-enabled with at least one policy, so nothing is reachable by default.

## 1. Set up the project

1. Create a Supabase project, then **SQL Editor → New query** and run `01` … `05` in order.
2. **Authentication → Providers**: enable **Email** (magic link). Turn off "Enable email signups" once your team is in, so the org stays closed.
3. Copy your project URL and **anon** key into the app:

```js
window.GEM_SUPABASE_URL = 'https://xxxx.supabase.co';
window.GEM_SUPABASE_ANON_KEY = 'eyJ...';   // anon key only — never the service_role key
```

The anon key is safe in client code *because* RLS is on; it grants nothing on its own. The **service_role** key bypasses RLS entirely — it must never reach the browser.

## 2. Bootstrap your org

Sign in once, then run in the browser console:

```js
await gemApi.createOrg('Glimmer Events Management');
```

This calls `gem_create_org()`, which creates the org and makes you its `owner` in one transaction.

To add a teammate: they sign in once (creating their `auth.users` row), then as owner you insert into `org_members` with their user id and a role — `planner`, `assistant`, or `viewer`.

To give a couple portal access: insert into `event_clients` with their user id, the `event_id`, and `can_edit` (true lets them manage their own guest list).

## 3. Swap the data layer

The UI view functions need **no changes** — `loadWorkspace()` returns the same shape they already render. Only the mutation call sites change.

Boot sequence, replacing the `localStorage` block:

```js
import { gemApi } from './gem-api.js';

let db;
async function boot(){
  if(!await gemApi.currentUser()) return showSignIn();
  db = await gemApi.loadWorkspace();
  setView('dashboard');
  gemApi.subscribe(async () => {           // desktop ↔ phone sync
    db = await gemApi.loadWorkspace();
    render();
  });
}
```

Then replace each `…; save();` with its API call:

| Prototype (localStorage) | Supabase |
|---|---|
| `lead.stage = col.dataset.stage; save();` | `await gemApi.setLeadStage(lead.id, col.dataset.stage);` |
| `db.leads.unshift({…}); save();` | `await gemApi.addLead({…});` |
| `item.done = !item.done; save();` | `await gemApi.toggleChecklist(item.id, !item.done);` |
| `g.rsvp = sel.value; …; save();` | `await gemApi.setGuestRsvp(g.id, sel.value);` |
| `g.tableId = tid; save();` | `const r = await gemApi.seatGuest(g.id, tid); if(!r.ok) toast(r.reason);` |
| `e.guests.push({…}); save();` | `await gemApi.addGuest(e.id, {…});` |
| `e.tables.push({…}); save();` | `await gemApi.addTable(e.id, {…});` |
| `db.vendors.push({…}); save();` | `await gemApi.addVendor({…});` |
| `v.status = sel.value; save();` | `await gemApi.setVendorStatus(v.id, sel.value);` |
| `db.invoices.unshift({…}); save();` | `await gemApi.addInvoice({…});` |

After a mutation, refresh with `db = await gemApi.loadWorkspace(); render();` — or let the realtime subscription do it.

Note `seatGuest()` enforces table capacity server-side and returns `{ok:false, reason}` — the same guard the prototype does in the browser, now where it can't be bypassed.

## 4. Who can see what

| | Staff (`org_members`) | Client (`event_clients`) |
|---|---|---|
| Leads / pipeline | ✅ full | ❌ never |
| Their own event | ✅ | ✅ read |
| Timeline, checklist, tables | ✅ | ✅ read |
| Guest list | ✅ | ✅ read, ✎ write if `can_edit` |
| Budget lines | ✅ | ❌ (internal margins) |
| Vendors + fees | ✅ | ❌ (commercially sensitive) |
| Invoices | ✅ (owner/planner write) | ✅ read, own event only |
| Mood boards, photos, palette | ✅ | ✅ read (that's the point) |
| Décor + vendor pricing | ✅ | ❌ |
| Documents | ✅ | ✅ read once sent, never drafts |
| Signing a document | ✅ | ✅ own event, via `gem_sign_document()` |
| Questionnaires | ✅ | ✅ read once sent; answers only as themselves |
| Messages | ✅ | ✅ own event thread, posting only as `client` |
| Lead capture form | ✅ manage | 🌐 `anon` may read an active form and INSERT one submission — never read submissions back |
| Other orgs' data | ❌ | ❌ |

### Signing

`gem_sign_document(document_id, typed_name)` is the only way a document becomes signed. It runs as `SECURITY DEFINER` and refuses unless the caller is a client of that document's event **and** the document is currently `sent` — then it writes the signature row and flips the document in one transaction, so the two can never half-apply.

Every table is deny-by-default: RLS is enabled with no permissive fallback, so a table with no matching policy returns zero rows rather than leaking.


## Telling Supabase what is already applied

The repo is connected to Supabase, and the migrations now live in
`supabase/migrations/` with the timestamped names the CLI and the GitHub
integration expect. Pushing a new file there deploys it.

**Before the first push Supabase acts on, run `SEED_MIGRATION_LEDGER.sql`
once in the SQL editor.** All twenty-one were applied by hand before the repo
was connected, so `supabase_migrations.schema_migrations` has never heard of
them; without the seed the integration treats every one as pending.

That is not a tidiness step. **01-05 are not re-runnable.** They use bare
`create table`, `create type` and `create policy`, so a second pass errors with
"already exists". 06 onward were written defensively (`if not exists`,
`create or replace`, `drop policy if exists` first) and survive a re-run.
Applying the whole chain twice against a clean Postgres 16: first pass 21/21,
second pass 16/21, failing on 01, 02, 03, 04 and 05.

Nothing is destroyed by that failure — they error before writing — but the
deploy halts and the ledger is left disagreeing with the database.

**Never run `supabase db reset` against the linked project.** It drops the
database and rebuilds it from these files. Every row in the studio goes with it.

### Writing a new migration from here

- Name it `<YYYYMMDDHHMMSS>_<nn>_<what_it_does>.sql`, timestamp ascending.
- Make it re-runnable, the way 06-21 are. It costs a few characters and it is
  the difference between a failed deploy and a no-op.
- End it with a `select` of booleans that proves it did what it says.

## Gotchas

- **`FORCE ROW LEVEL SECURITY`** is on for `leads`, `events`, `guests`, `invoices`, `vendors`. This subjects the *table owner* to RLS too, so seeding data as `postgres` in the SQL Editor will be filtered. Seed through the API as a signed-in user, or temporarily `alter table … no force row level security` while loading, then turn it back on.
- **`service_role` still bypasses RLS** (it has `BYPASSRLS`), which is why that key must stay server-side only.
- **Helper functions are `SECURITY DEFINER` with a pinned `search_path`** — that's deliberate. Without the pin, a caller could shadow `org_members` and escalate.
- **Realtime** needs the tables added to the `supabase_realtime` publication (Database → Replication) before `subscribe()` fires.
- Dates are `date` columns; the prototype's `'2026-10-11'` strings map straight across.
