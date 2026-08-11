# GEM — what's next

Written 6 Aug 2026. Updated the same day: migration 10 and step 2 are built and
running; steps 3–5 are not.

---

## 1 · Wedding-weekend sub-events  ← the main piece

A wedding is realistically four events: welcome party, rehearsal dinner,
ceremony + reception, farewell brunch. One couple, one contract, shared vendors,
one guest list with different subsets invited to each. The data model already
allows many events per client (`events.lead_id`); nothing in the UI says they
belong together.

**Decision taken:** sub-events under a primary, not flat events grouped by
client. The dashboard keeps one countdown to the wedding rather than four
competing ones, and the client file shows the weekend as a single block.

### Migration 10 — DONE, run against the live project, verify all true

`supabase/10_sub_events.sql`.

- `events.parent_event_id` (cascade), `event_role`, `sort_order`
- `event_role` is text + check, not an enum — `primary | welcome | rehearsal |
  ceremony | brunch | other`. A check constraint ties it to the parent:
  `parent_event_id is null` ⟺ `event_role = 'primary'`.
- `events_parent_guard` trigger keeps the tree **one level deep** — no
  self-parenting, no grandchildren, no cross-org parents. A check constraint
  cannot see other rows and the client file would recurse for ever.
- `guest_invites` (guest_id, event_id, org_id, **rsvp, table_id, meal**) with a
  unique on (guest_id, event_id) and a trigger refusing an invite for the
  guest's own event or a table_id from another room.
- `budget_lines.tag_event_id`, nullable.
- RLS on `guest_invites` mirroring `guests`.

**The one thing to know before touching RLS again.** `events` carries FORCE row
level security, so `security definer` does *not* exempt a function from the
`events` policy. `gem_is_event_client` now reads `events` to reach through
`parent_event_id`, so `events_read` can no longer call it — that pair is a cycle
and Postgres answers with `infinite recursion detected in policy for relation
events`, which stops the table reading for staff too. `events_read` is therefore
written inline, using the row's own `parent_event_id`. Every other table still
goes through the functions, which is what makes the portal show one weekend
without a policy per table. Do not "tidy" `events_read` back into a function call.

### Build order

1. ~~migration~~ — done
2. ~~parent/child in the events view and the client file~~ — done
3. ~~guest invitations (the RSVP grid gains a column per sub-event)~~ — done
4. ~~per-event seating~~ — done
5. ~~portal + printing~~ — done

### The three decisions, settled

- **Seating** — no schema change was needed. `events.floor`, `floor_items` and
  `seating_tables` are already keyed by `event_id` (migration 06), so each
  sub-event has its own room and tables already. What is left is a switcher on
  the seating screen, and reading the seat from `guest_invites.table_id` rather
  than `guests.table_id` when the event is a sub-event.
- **Guests** — the guest row stays owned by the **primary**, and its
  `rsvp`/`table_id` keep meaning "the ceremony and reception". `guest_invites`
  holds rows for sub-events only. No backfill, and the sync path stabilised in
  08/09 was left alone. The cost is that the RSVP grid reads its first column
  from `guests` and the rest from `guest_invites`.
- **Budget** — one budget for the weekend on the primary, with an optional
  `tag_event_id` per line. The column round-trips through sync already; the
  filter UI is not built.
- **Portal** — couples see the weekend as one timeline. Delivered by the
  `gem_is_event_client` / `gem_client_can_edit` reach-through above.

### What step 2 actually changed in `gem-artifact.html`

- Helpers next to `evById`: `EV_ROLES`, `evRole`, `roleLabel`, `evIsSub`,
  `evChildren`, `evPrimary`, `evBlock`, `evPrimaries`, `evPct`.
- `viewEvents` renders primaries only; sub-events ride inside the card. Progress
  is the whole block's.
- `viewEventDetail` gains the `.wknd-bar` switcher; `openEventModal(existing,
  parentId)` gains "Part of" and "Which event is it", hidden once an event has
  children of its own.
- Dashboard countdown uses `evPrimaries()` — a welcome party two days before the
  wedding must not win the countdown.
- Client file lists the block in `.wk-list`.
- Sync: `parent_event_id` / `event_role` / `sort_order` on the events payload,
  `tag_event_id` on budget lines, both directions.

### What steps 3 and 4 changed

The whole feature rests on one accessor pair next to `evPct`, and everything
else just calls it:

- `rosterFor(ev)` — a primary counts its whole guest list; a sub-event counts
  only those with an invitation.
- `gRsvp / gTable / gMeal / gSet(g, ev, k, v)` — read and write the rsvp, seat
  and meal for **that** event. Primary → the guest row. Sub-event → the
  invitation. No screen has to remember which.
- `db.invites` is a flat join list shaped like `db.bookings`. It is flat on
  purpose: nesting it under the guest would mean rewriting map keys in
  `sbMigrateIds()`, which is where the last two id bugs came from.

`seatedAt(ev, tid)` was the hinge — the floor plan, the table cards, the side
panel and both print sheets all go through it, so making it read invitations
made seating per-event in one edit.

The guest grid gains a tick-box column per sub-event, but only on the primary;
a sub-event shows its own list with its own RSVPs. Un-ticking someone drops
their seat and RSVP for that event, and leaves the wedding untouched.

Verified against the case that motivated it: Priya Sharma sits at the Head
Table for the wedding and the Barn Long Table for the welcome party, at once.

### What step 5 changed

- `viewPortal` anchors on `evPrimary(activeEvent())` whatever the planner has
  selected — a couple does not think of the welcome party as a separate login.
  The countdown stays on the wedding; the hero gains a chip per event.
- The weekend is listed **chronologically** in the portal, unlike the staff
  views, which lead with the primary. A couple reads their weekend forwards.
- "Your Day" becomes "Your Weekend": one timeline, each event a heading.
  Checklist, documents, questionnaires and the message thread all span the
  block, so nothing addressed to a sub-event is invisible to the couple.
- Print menu names the event it will print (`Rehearsal dinner · …`) and gains a
  **Weekend Running Order** sheet when sub-events exist — every event in date
  order with venue, attendance and running order on one page.

### Migration 11 — document labels

`documents.type` is a Postgres enum, so a new label is not a UI change: an
unknown value is rejected on push and the document silently fails to sync.
`supabase/11_doc_labels.sql` widens `doc_type` with invoice, venue, vendor,
client, insurance, permit, floorplan and timeline. **Run it before using the
upload button against a synced studio**, and keep `DOC_TYPES` in the app in step
with it.

Uploading a file the studio already holds now creates the document *around* the
file (title from the filename, a label, an event) rather than attaching to an
existing row — from the client file, or the Documents toolbar. The client file
also lists the whole weekend's paperwork now, not just the ceremony's.

### Two traps this cost time on

- **`sbMigrateIds()` must rewrite `parentId`.** It is a cross-reference like
  `leadId` and `tableId`. Left out, the first push sends a child pointing at an
  id that no longer exists. `guest_invites` will need the same for `guest_id`,
  `event_id` and `table_id` in step 3.
- **Events must be pushed parents-first.** `events_parent_guard` is a BEFORE ROW
  trigger, so it fires as each row lands rather than at end of statement; a child
  ahead of its parent is refused. The events payload is sorted accordingly.
- **Check a class name is free before styling it.** `.ev-switch` was already the
  active-event `<select>`; the new switcher rendered 230px wide and stacked until
  it was renamed `.wknd-bar`. One file, one namespace.

---

## 1b · Sweep results, 6 Aug 2026

All sixteen views, at 1440×900 and 375×812, with a primary active and with a
sub-event active: **no JS errors, no horizontal page overflow, every view
renders**. Seeded against a realistic weekend — four events, eighteen
invitations spread across them.

Fixed during the sweep: the invite tick-boxes were 24×24 on touch, below the
app's own 32px floor for coarse pointers; they now grow to 34px, matching the
stance `.r-act` already took. The guest print sheet's "N attending" count was
also still reading the raw guest list rather than the roster.

Remaining small-target counts on mobile are all pre-existing and none are new:
dashboard tick-boxes (24×24), vendor contact links, the seating inputs.

## 1c · Mobile pain points found and fixed, 6 Aug 2026

Audited by driving real workflows at 375×812 rather than eyeballing layouts.

- **Every form control was 12.5–13.5px.** Under 16px, iOS Safari zooms the page
  in the moment a field is focused and never zooms back — tap any input and the
  layout is stuck magnified until you pinch out by hand. Fixed in the existing
  `(pointer:coarse),(max-width:560px)` block. It needs `!important`: dozens of
  rules across the file set control text by class (`.ev-switch`,
  `.modal .field input`, `select.mini`…) and any one left under 16px
  re-introduces the zoom. Scoped to coarse pointers, so desktop is untouched —
  verified still 11px/12.5px at 1440.
- **The guest grid hid 563 of 908px on a phone with no cue it scrolled**, and
  the invite columns — the newest, most useful information — sat furthest
  right. The name column is now sticky on narrow screens, and a scroll shadow
  pinned with `background-attachment:local` fades out exactly at the end.
  Both scoped under 860px; at desktop widths the grid fits and pinning it just
  drew a divider that separated nothing.
- **No guest search.** The vendor directory had one; a 200-name guest list did
  not. Matches name, party, meal, dietary needs and email.
- **No bulk invite.** Inviting a guest list to the welcome party was one tap
  per guest. Each invite column header now toggles all — and because it acts on
  the rows *currently shown*, it composes with the search: type "Vance", hit
  `all`, and exactly that family is invited.

## 1d · Tap-to-seat and the dashboard, 6 Aug 2026

- **Seating on a phone.** Dragging has no touch equivalent, so a phone fell
  back to a dropdown per guest — a native picker and three taps, eighty times
  over. Now: tap the guest, tap the table. A sticky bar names who is in hand
  and offers Cancel; only valid drop targets stay lit; tapping Unseated lifts
  them; the same capacity guard applies and keeps the guest in hand so you can
  pick another table. The dropdown is hidden on touch now that it is redundant.
  Desktop keeps drag-and-drop, and gains tap-to-seat for free.
- **`seatInto(gid, tid)`** is now the single place the capacity rule and the
  per-event write live; drag, tap and the dropdown all call it.
- **Handlers were firing twice.** `render()` already re-wires the current view,
  so every `render(); wireSeating();` attached a second copy of each
  `addEventListener` handler — one full table produced two toasts. Stable 2×,
  not compounding, since each render replaces the nodes. Six redundant calls
  removed from `wireSeating`. **The same pattern exists elsewhere in the file**
  (`render(); wireGuests();` and friends); it is harmless where handlers are
  assigned with `.onclick=` because that overwrites, and only bites where
  `addEventListener` is used. Worth knowing before adding listeners anywhere.
- **The dashboard buried the useful part.** The getting-started panel rendered
  all seven steps including struck-through completed ones, pushing the first
  actionable card 610px down a phone screen. It now lists only what is left,
  two at a time, with an expander — 289px, and the count and bar still show
  progress.

## 1e · Sample data and client identity, 10 Aug 2026

**The sample wedding is read-only now.** It seeds on every fresh device with
the same fixed ids, and someone edited it believing it was their own project:
a device that has never pulled is refused by `gem_claim_sync` (migration 09),
so nothing they typed ever reached the studio. It is now badged **Sample** on
the event card, the client row and a banner across the workspace, and writes
are refused.

One capture-phase gate on `.main` does the enforcing, rather than a check in
forty handlers — `sampleBlock()`. Navigation, expanding, switching events,
printing and exporting all still work; only writes stop. `SAMPLE_SAFE` is the
allowlist. Row ✎/✕ actions check their own record id, so a sample row inside an
otherwise real list is blocked without locking the view. Verified: creating
your own event and editing it works normally while the sample stays locked.

Two ways out, both on the banner: **Use this as my project** (`adoptSample()`
clears the flags and empties the id lists — nothing is deleted) and **Remove
sample**.

**The "removed but still there" bug.** `removeSampleData()` matched records by
fixed id, and only honoured the `sample` flag for vendors and bookings. After
the first push `sbMigrateIds()` rewrites every sample id to a uuid and stamps
`sample:true`, so the id lists matched nothing: it deleted the sample vendors,
reported a count, and `hasSampleData()` then returned false — hiding the button
while the wedding sat there. Both now go through `sampleHit()`, which checks
flag **or** id, across every sample collection; removal also takes sub-events,
attached paperwork and invitations. Reproduced in the exact post-push state and
confirmed fixed.

**Clients are joined by id, not by name.** Invoices stored the client as a name
string with no `leadId`, and the portal matched invoices against the *event
title*. Renaming a client silently orphaned their invoices — the money stopped
appearing on their file. Now:

- `invoicesForLead()`, `leadForEvent()`, `invoiceClientName()` are the joins;
  the name match survives only as a fallback for rows written before this.
- `normalize()` backfills `invoice.leadId` once, by the old name match.
- `propagateLeadRename()` updates cached names and any event titled with the
  old name; a deliberately-titled event is left alone.
- The invoice modal and editor pick a client from a list instead of taking free
  text, so the link is structural rather than typed.
- `lead_id` now goes up and comes back in sync — the column already existed in
  `01_schema.sql` and was never being written.

Verified: renaming a client updates clients, events, finance, portal, documents
and dashboard with no stale copies, and the invoices stay on the client file.

## 2 · Still unverified against live data

Attach a photo **and** a document, push, then pull on a second device. Every
other sync path has been confirmed against the real project; these two have only
been tested against a stubbed network. Storage policies were fixed in migration
08 — if anything there is wrong, this is where it shows.

Two more added by the sub-event work, both reasoned-about but not witnessed:

- **`guest_invites` has never made a real round trip.** The payload is built,
  ordered after `guests` and `seating_tables`, filtered against deleted guests,
  and its three foreign keys are rewritten in `sbMigrateIds()`. That is
  argument, not evidence. Push, then pull on a second device, and check the
  invitations and per-event seating survive.
- **The portal reach-through has never been exercised by an actual couple.**
  Migration 10 redefined `gem_is_event_client` / `gem_client_can_edit` to
  resolve through `parent_event_id`, and the verify query confirmed the
  function bodies changed — but no client user has logged in and read a
  sub-event's timeline, guest list or messages. Everything the portal now shows
  across the block depends on those two functions being right. Sign in as a
  couple attached only to the primary and confirm they can see the rehearsal
  dinner, and still cannot see leads or vendor fees.

---

## 3 · Smaller open items

- **Branded email** — Resend (or similar) + SPF/DKIM on `gemevents.app`, then
  Supabase → Auth → SMTP settings and email templates. Configuration, no code.
- **Portal hostname** — `portal.gemevents.app` still needs adding as a custom
  domain on the `gemevents` Worker. The app side is built: set it in
  Settings → Branding → Portal domain and that host boots portal-only.
- **Realtime** — deliberately not doing it. Polling on focus plus a timer covers
  1–3 devices; a WebSocket only earns its keep with several planners editing at
  once. Revisit if a second planner joins.
- **PDF export** — print sheets go through the browser dialog, where every
  platform offers Save as PDF. Bundling a PDF library isn't worth the weight.

---

## Notes for whoever picks this up

- Source of truth is `gem-artifact.html`; `build.py` wraps it into `index.html`.
  Never edit `index.html` directly.
- **This is a git repository as of 10 Aug 2026** — it was not before, and every
  version of the app existed only as the file on disk. `index.html` is
  committed deliberately alongside its source, so a deployed build is always
  recoverable and a future push-to-deploy needs no build step in CI. The
  identity is repo-local; nothing global was changed. No remote yet: the plan
  is a GitHub connector in Claude (authenticated in the app, so no credential
  on the Mac), then Cloudflare Workers Builds for push-to-deploy.
- Checked before the first commit: no keys are embedded anywhere. Every
  `service_role` / `eyJhbGciOi` hit is documentation warning *about* keys. The
  only live identifier is the Supabase project URL, which is a public endpoint
  — security rests on RLS and the anon key, which is entered in Settings and
  lives in localStorage, not in the source. **Make the GitHub repo private
  anyway**; the schema and client data model are the studio's business.
- **Deploy is now `git push origin main`.** Cloudflare Workers Builds watches
  `github.com/lroy413/GEM`; a push runs `npm run build` (→ `scripts/build-dist.mjs`,
  which rebuilds index.html from the artifact and stages `dist/`) then
  `npx wrangler deploy`. A push to any other branch runs
  `npx wrangler versions upload` instead — it exercises the whole build and
  uploads a version **without** touching production, which is the way to test a
  change to the build itself. Config lives in `wrangler.jsonc`.
- Two things wrangler will do if you let it, both now pinned in `wrangler.jsonc`:
  it **enables preview URLs** by default when a workers.dev route exists (the
  Worker had them off; `preview_urls: false` restores that), and it would
  **detach the `gemevents.app` custom domain** if a `routes` key were present
  but incomplete — hence no `routes` key at all.
- `/offline.html` returning **307 → /offline** is correct, not a fault:
  `html_handling: auto-trailing-slash` strips the extension, and `sw.js`
  already caches `/offline` for exactly this reason.
- `deploy.py` still works and is unchanged — a second, independent path to the
  same eight assets. It needs `CLOUDFLARE_API_TOKEN` exported. It
  builds, uploads only the assets whose hash is not already in the store, cuts
  a new version of the `gemevents` Worker, and then polls the live site until
  three consecutive fetches hash-match the local `index.html` — edges disagree
  for a minute or two after a push. `--dry-run` shows the manifest and what
  would upload without writing anything.
- **The check cannot byte-compare the response to the file.** Cloudflare Web
  Analytics injects a ~359-byte beacon `<script>` into HTML on the way out, so
  the served page legitimately is not the uploaded asset. It is not reliably
  gated on the user agent either — the same agent got a clean body through curl
  and a beaconed one through urllib — so `verify()` strips the tag before
  hashing rather than trying to dodge the injection. Separately, the default
  `Python-urllib` agent is 403'd by bot protection, so the agent is named
  `GEM-deploy/1.0`. A stable-but-wrong hash repeating forty times is this, not
  a stuck rollout: a genuinely lagging edge changes its answer.
- `gemevents` is an **assets-only** Worker: no user script, `serve_directly`,
  SPA fallback to index.html. The deployed set is index.html, sw.js,
  manifest.webmanifest, offline.html and four icons — eight files. `_headers`
  and `download.html` are **not** deployed and `deploy.py` deliberately leaves
  them out; adding them would change live cache-control and security headers.
  Nothing currently sets `Service-Worker-Allowed` or `no-cache` on `sw.js`.
- There is no node, wrangler or docker on this machine, and the Cloudflare MCP
  sandbox blocks outbound `fetch`, so an agent cannot complete a deploy on its
  own — the asset bytes have nowhere to travel. Hence the script.
- **The MCP cannot substitute for the token.** Checked, not assumed: it returns
  `9109 Unauthorized` on `/user/tokens` and `/accounts/{id}/tokens`, so it
  cannot mint one; and the asset upload step authenticates with a short-lived
  session JWT in the `Authorization` header, which `cloudflare.request()` gives
  no way to set. Both halves of a self-service deploy are closed.
- **`deploy.py` now falls back to the macOS keychain**, so the token no longer
  dies with the terminal window it was exported in — which is what made a
  remote-driven deploy impossible. Store it once:

      security add-generic-password -U -s gem-cloudflare-deploy -a "$USER" -w

  Verified that `security find-generic-password -s gem-cloudflare-deploy -w`
  reads back headlessly with no GUI prompt (the item's ACL already contains
  `security`, since `security` created it), so an agent session can run the
  deploy. The login keychain must be unlocked — i.e. the Mac logged in.
- **When patching, anchor on unique surrounding context.** Two bugs this session
  came from a `replace(..., 1)` matching the backup-restore handler instead of
  the boot sequence, because both contain the same line.
- Photos are data URLs in memory, IndexedDB on disk. Document files are Blobs in
  IndexedDB only — never in memory. Both are keyed by record id, and
  `sbMigrateIds()` rewrites those ids on first push, so anything keyed that way
  must be re-keyed (`docRekey`) or it orphans.
- The preview/dev server runs sandboxed and **cannot read
  `/Users/ronin/Documents/GEM`** — pointing `serve.py` at the project returns 404
  for every file. Copy `gem-artifact.html` into the session scratchpad and set
  `ROOT` there. `.claude/launch.json` currently points at a scratchpad copy on
  port 8812; re-copy the file after each edit or the browser shows stale code.
