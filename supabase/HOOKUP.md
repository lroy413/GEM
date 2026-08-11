# Connecting GEM to Supabase — start to finish

Everything below is on your side. Work through it in order; each step is verifiable before you move on.

Roughly 45 minutes if nothing surprises you.

---

## Before you start

You need:
- A Supabase account (free tier is fine to begin)
- The `/supabase` folder from this project
- `gemevents.app` pointed at a host (see `deploy/PWA-SETUP.md`)

---

## 1 · Create the project

1. **supabase.com → New project**
2. Name it `gem-production`
3. **Choose a region close to you** — every request pays that round trip
4. Save the database password somewhere safe; you cannot see it again
5. Wait for provisioning (~2 minutes)

---

## 2 · Run the schema

**SQL Editor → New query.** Paste and run each file **in this order**, waiting for "Success" before the next:

| # | File | Creates |
|---|---|---|
| 1 | `01_schema.sql` | Core tables — orgs, leads, events, guests, vendors, invoices |
| 2 | `02_rls.sql` | Row-level security, helper functions, `gem_create_org()` |
| 3 | `03_design_docs.sql` | Mood boards, images, palette, décor, documents |
| 4 | `04_client_loop.sql` | Questionnaires, lead forms, signatures, messages |
| 5 | `05_storage.sql` | The private `gem-media` bucket and its policies |
| 6 | `06_app_parity.sql` | Client/venue detail, floor plan, vendor bookings, white-label settings |

**Order matters.** Files 3–5 call helper functions defined in file 2, and file 6 alters tables created in file 1.

File 6 exists because 01–05 were written before several features landed. Without it the app still runs, but every save quietly discards client addresses, venue details, the whole floor plan, vendor bookings and all your branding — there is nowhere to put them. It is safe to re-run.

### Check it worked
```sql
select count(*) as tables from information_schema.tables where table_schema='public';
select count(*) as policies from pg_policies where schemaname='public';
```
Expect **29 tables** and **61 policies** (26 tables / 56 policies before file 6). Fewer means a file didn't finish — re-run from wherever it stopped.

---

## 3 · Authentication

**Authentication → Providers → Email**
- Enable **Email**
- Turn ON **Confirm email**
- Magic links are the simplest option; there are no passwords for you to handle

**Authentication → URL Configuration**
- Site URL: `https://gemevents.app`
- Redirect URLs: `https://gemevents.app/**`

Add `http://localhost:8811/**` as a second redirect while you're testing locally.

> Once your team has accounts, come back and turn **off** "Enable email signups" so the org stays closed.

---

## 4 · Storage

**Storage** → confirm `gem-media` exists and is **not public**. `05_storage.sql` creates it, but check:

- File size limit: 10 MB
- Allowed types: jpeg, png, webp, heic, pdf

Photos are served through short-lived signed URLs, never a public link.

---

## 5 · Realtime (optional, for device sync)

**Database → Replication → `supabase_realtime`** → add: `leads`, `events`, `checklist_items`, `guests`, `messages`, `documents`.

Skip this if you only use one device; it can be enabled later.

---

## 6 · Get your keys

**Project Settings → API**

| Key | Where it goes |
|---|---|
| **Project URL** | The app |
| **anon / public** | The app |
| **service_role** | **Nowhere.** Never in the browser. |

The anon key is safe in client code *because* RLS is on — it grants nothing by itself. The service_role key bypasses every policy.

---

## 7 · Wire it into the app

Add this **above** the app's own script, in `index.html`:

```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script>
  window.GEM_SUPABASE_URL = 'https://YOURPROJECT.supabase.co';
  window.GEM_SUPABASE_ANON_KEY = 'eyJhbGci...';
</script>
```

Then send me those two values and I'll connect `gem-api.js` to the app — the view code doesn't change, because `loadWorkspace()` returns the same shape the app already renders. Only the ten save points move over.

---

## 8 · Create your studio

Sign in once at `https://gemevents.app`, then in the browser console:

```js
await gemApi.createOrg('Glimmer Events Management');
```

That creates the organisation and makes you its owner in a single transaction.

**Adding your team:** each person signs in once (which creates their account), then you add them from **Settings → Team & roles**, or directly:

```sql
insert into org_members (org_id, user_id, role)
values ('<org-id>', '<their-user-id>', 'planner');
```

**Giving a couple portal access:**

```sql
insert into event_clients (event_id, user_id, org_id, can_edit)
values ('<event-id>', '<their-user-id>', '<org-id>', true);
```

`can_edit` true lets them manage their own guest list.

---

## 9 · Move your existing data across

Anything you've entered in the prototype lives in that browser only.

1. **Settings → Data & storage → Download JSON** — do this *before* switching
2. Once connected, use **Import a backup** on the same page

Photos are the exception: they're stored as data inside the backup and will need re-uploading to Storage. There are unlikely to be many yet.

---

## 10 · Verify

Sign in on a second device and confirm:

- [ ] You see the same clients and events
- [ ] Creating a lead on one device appears on the other (if Realtime is on)
- [ ] Signing out and back in keeps your data
- [ ] A test client account sees **only** their event — no pipeline, no vendor fees, no budget

That last one is the important one. To test it properly, create a second account, add it to `event_clients` for one event, and sign in as them.

---

## Things that commonly go wrong

**"relation does not exist"** — a file ran out of order. Re-run from `02_rls.sql`.

**"permission denied for table"** — RLS is doing its job and you have no `org_members` row. Run `gem_create_org()` first.

**Nothing loads, no error** — almost always the redirect URL not matching. It must include the `/**` wildcard.

**Seeding data in the SQL Editor returns nothing** — `FORCE ROW LEVEL SECURITY` applies to the table owner too. Seed through the app as a signed-in user, or temporarily:
```sql
alter table leads no force row level security;
-- load your data
alter table leads force row level security;
```

**Photos won't display** — the bucket must stay private and be read through signed URLs. Making it public would expose every client's images.

---

## Costs

The free tier covers 500 MB database, 1 GB storage, 50,000 monthly active users. For a studio your size that's likely years away from mattering. The next tier is $25/month.

---

## What still isn't automatic after this

- **Payments** — Stripe is a separate integration
- **Email notifications** — Supabase sends auth emails only; task reminders need a scheduled function or a service like Resend
- **Offline sync** — the app works offline on one device, but reconciling edits made on two devices while both were offline is a further piece of work

Send me the project URL and anon key when you're through step 6 and I'll take it from there.
