# GEM — handoff

Last updated 14 Aug 2026. Live build `f28fd01f2450`; local, GitHub and
production are in sync.

GEM is a single-file event-planning app for a wedding-and-events studio. It
runs local-first in the browser and syncs to Supabase when connected.

---

## Start here

| | |
|---|---|
| Source of truth | `gem-artifact.html` — **never edit `index.html` directly** |
| Build | `python3 build.py` (wraps the artifact in a `<head>`) |
| Deploy | `git push origin main` — Cloudflare Workers Builds does the rest |
| Live | https://gemevents.app |
| Repo | `github.com/lroy413/GEM` (private) |
| Database | Supabase, project `dqntxdhzcieycifzjzwc` |
| Which build is live? | Settings → Data & storage → **App version**, or `curl -s https://gemevents.app/ \| grep gem-build` |

Migrations **01–16 are all run** against the live project — 16 on 19 Aug 2026,
verifying all true. The database is now ahead of production: `events.photo_path`
exists and nothing writes to it until this build ships, which is the safe
direction. Deploying before the migration would not have been: the events
payload carries that key on every row whether or not the event has a cover, so
PostgREST would have refused *every* events push.

This build also carries six bug fixes — `BUGS.md` is the report they came from.
One of them changes what the invoices payload contains: `lead_id` is finally
populated, having gone up null on every push since the first sync. That column
has existed since migration 01, so it needs nothing new — but it does mean the
first push after this build writes a join the database has never held.

---

## 1 · How deployment works

A push to `main` runs `npm run build` (→ `scripts/build-dist.mjs`, which
rebuilds `index.html` from the artifact and stages `dist/`) and then
`npx wrangler deploy`. A push to **any other branch** runs
`npx wrangler versions upload` instead: it exercises the whole build and
uploads a version **without touching production**. That is how to test a change
to the build itself.

`deploy.py` is a second, independent path to the same eight assets. It needs
`CLOUDFLARE_API_TOKEN` in the environment, or the macOS keychain:

```
security add-generic-password -U -s gem-cloudflare-deploy -a "$USER" -w
```

### Things that will bite you

- **Two settings drift unless pinned in `wrangler.jsonc`.** Wrangler enables
  preview URLs by default when a workers.dev route exists (`preview_urls:false`
  stops it), and it would detach the `gemevents.app` custom domain if a
  `routes` key were present but incomplete — hence no `routes` key at all.
- **A deploy check cannot byte-compare the response to the file.** Cloudflare
  Web Analytics injects a ~359-byte beacon `<script>` into HTML, and it is not
  reliably gated on the user agent. `deploy.py` strips the tag before hashing.
  Separately, the default `Python-urllib` agent is 403'd by bot protection.
  A stable-but-wrong hash repeating dozens of times is this, not a stuck
  rollout: a genuinely lagging edge changes its answer.
- `/offline.html` returning **307 → /offline** is correct.
  `html_handling: auto-trailing-slash` strips the extension and `sw.js`
  already caches `/offline`.
- The preview/dev server runs sandboxed and **cannot read the project
  directory**. Copy `gem-artifact.html` into a scratchpad and point `ROOT`
  there. Re-copy after each edit or the browser shows stale code.

---

## 2 · The data model, in the order it grew

Local state is one `db` object in `localStorage`; `normalize()` on boot fills
in anything a newer build expects. Everything below exists in both the local
shape and the Postgres schema.

- **leads** — the client file. Invoices join by `leadId`, **not by name**.
- **events** — `parent_event_id` makes a weekend: one primary with sub-events
  one level deep, enforced by `events_parent_guard`. `event_type` (Wedding,
  Corporate, Conference, Gala, Birthday…) decides which sub-event roles the app
  offers and what it calls the client — the couple, the client, the host, the
  family. `event_role` is constrained; `event_type` deliberately is not.
  `photo_path` is the event's own cover; `evPhoto()` falls back to the
  primary's and then the client's, so read a cover through it and never off
  `e.photo` directly.
- **guests** belong to the **primary**, and their `rsvp`/`tableId` mean "the
  main event". **guest_invites** carries an invitation to each sub-event with
  its own rsvp, seat and meal. `rosterFor(ev)` and `gRsvp/gTable/gMeal/gSet`
  are the only correct way to read or write these — never touch `g.rsvp`
  directly.
- **checklist_items** — `owner` is `planner` or `client`. The portal shows only
  client-owned items; existing rows default to planner, which is the safe
  direction. `note` is per-task.
- **seating_tables / floor_items** are already per-event, so each sub-event has
  its own room for free.
- **event_clients** + **event_client_invites** — portal access. See §4.

### Sync, in one paragraph

Pushing is automatic: `save()` marks the device dirty and schedules a push four
seconds later. Pulling is automatic **only where it cannot lose anything** —
`sbSyncDown()` pulls when this device has never synced and holds nothing but the
sample, or when it is behind with nothing unsent. A device that is behind *and*
holding unsent edits is a real conflict and still asks a human. The dirty flag
lives in `localStorage`, not memory, because a phone edited offline and closed
would otherwise come back looking clean and get pulled over. `gem_claim_sync`
backs all of this from the server side: it refuses a push from a device that has
never pulled, which is what stops a fresh install overwriting the studio.

### Three traps that have caused real bugs

1. **`sbMigrateIds()` rewrites every id on the first push.** Anything holding a
   reference must be fixed there: `leadId`, `parentId`, `tagEventId`,
   `tableId`, and an invite's `guestId`/`eventId`/`tableId`. Miss one and the
   first push sends a row pointing at an id that no longer exists.
2. **Events must be pushed parents-first.** `events_parent_guard` is a BEFORE
   ROW trigger, so it fires as each row lands, not at end of statement. The
   payload is sorted accordingly.
3. **A photo is the one change that happens after its table was hashed.**
   `sbPush()` decides which tables to write by hashing each payload, and
   `mediaUpload()` stamps `photo_path` afterwards — so a table whose only
   change was a new picture hashed identical to last time and was skipped, and
   the path went nowhere until an unrelated edit pushed that table again. The
   four tables carrying a storage reference are re-hashed after the uploads and
   taken if they moved. Anything else stamped post-hash needs the same
   treatment, and the upsert chain has to be built after that check, not
   alongside it.

---

## 3 · Things worth knowing before you change the UI

- **The bible is one content model, three renderers.** `bibleBlocks()` builds a
  list of blocks; `bibleHtml()` prints them (and so makes the PDF),
  `bibleDocx()` packs them into a real `.docx`, and `bibleEmail()` writes the
  covering note. Add a section in `BIBLE_SECTIONS` and `bibleBlocks()` only —
  never in a renderer, which is where the two copies would drift apart.
  A section marked `planner:true` is withheld from a client's copy **whatever
  is ticked**, and that list follows `02_rls.sql`, not taste.
- **A `.docx` is a ZIP of XML, and `CT_RPr`/`CT_PPr` are sequences.** Element
  order inside `w:rPr` and `w:pPr` is part of the schema: Word forgives a wrong
  order, stricter readers reject the whole file. The order in `wRun()` and
  `wPara()` is the schema's; keep it.
- **Photographs are framed, not just shrunk.** `openPhotoCrop(file,opts,done)`
  hands back a square JPEG at whatever size `opts.out` asks for (512 by
  default) after the person has dragged and zoomed the picture under a fixed
  circle. What it exports is the **square** the circle sits in, not the circle:
  the same pixels serve the round avatar, the client card and the dashboard
  hero through `evPhoto()`, and each masks it its own way. Anything that takes
  a photograph of a person should go through it rather than calling
  `shrinkImage()` directly.
- **Replacing a photograph must null its `photoPath`.** `mediaUpload()` only
  sends records with pixels and no path, so a new picture left beside the old
  key never uploads and every other device keeps the old one. The event cover
  always did this; the client photo did not until 19 Aug.
- **Clients read as a list or as cards** (`prefs().clientView`, in the
  whitelist). Cards deliberately carry no edit/delete: `.r-act` is always
  visible in touch mode, which put a permanent ✕ on every face in the grid.
- **First run is a gate, then the tour.** `openWelcomeGate()` asks for an
  account or guest before anything else, and `closeModal()` refuses while it is
  up — a scrim click that quietly meant "guest" is the outcome it exists to
  prevent. It hands off to the tour on the way out, so the tour no longer
  starts on its own except when the question has already been answered
  (`gem-welcome`). A couple on the portal host is never asked, and neither is
  anyone already signed in. Both it and Settings › Connection sign in through
  `sbAuthGo()` — put anything that must happen on sign-in there, not in either
  screen.
- **`prefs()` rebuilds a whitelisted object.** A key not named there is written
  to storage and silently dropped on load. This cost an afternoon with
  `dashOrder`.
- **`render()` already re-wires the current view.** `render(); wireX();`
  double-attaches every `addEventListener` handler. Harmless with `.onclick=`,
  which overwrites; it bites with `addEventListener`.
- **Key layout rules to the container, not the viewport.** The checklist lives
  in the narrow right column of a two-column grid, so it is cramped at any
  window size; a `@media (max-width:700px)` rule never fired when it was
  needed and labels ended up painted under the pills. `.chk-scroll` is a
  container query now. The guest grid has the same shape and would be the next
  to show it.
- **`openEditor` supports `showIf(vals)`** for conditional fields (hidden
  fields read as empty on save and skip `required`) and `onFieldChange` for a
  select whose *options* depend on another field.
- **When patching, anchor on unique surrounding context.** Two bugs came from a
  replace matching the backup-restore handler instead of the boot sequence.
- Check a class name is free before styling it — `.ev-switch` was already the
  active-event `<select>`.

---

## 4 · Client portal — built, never exercised

Migration 14 added the missing half. `event_clients` had existed since
migration 01 and RLS always enforced it, but **nothing ever wrote to it**, so a
couple could sign in and see an empty app.

The browser cannot turn an email into a user id (`auth.users` is not readable
with the anon key), so an invitation is stored against the address and claimed
server-side on first sign-in, matching the address in the caller's own token.
Two seats per event: the couple share one and may add one more themselves.
All writes go through security-definer functions; the table's own policy
refuses direct insert and update.

Planner UI is on the client file: address, copy link, invite, who has access,
revoke.

**Still to do, and all on the studio's side:**

1. Add `portal.gemevents.app` as a custom domain on the `gemevents` Worker.
   Only `gemevents.app` is attached today.
2. Set Settings → Branding → **Portal domain** to that host.
3. Supabase → Authentication → URL Configuration → add
   `https://portal.gemevents.app/**` or magic links bounce.
4. Supabase → Authentication → Emails → **SMTP**. The built-in mailer is capped
   at a handful an hour and lands in spam, which is fatal for a sign-in link.
   An invitation does **not** email anyone yet — it grants access to whoever
   signs in with that address.

---

## 5 · Never verified against live data

Everything here is reasoned about and unit-exercised locally, but has never
made a real round trip. These are the highest-value things to test next.

**`VERIFY.md` is the runbook for this section** — the same list, turned into
click-by-click steps with the SQL to confirm each one and a note on what a
failure points at. Its §F carries two things found while writing it: a couple's
*first* visit to the portal host lands on the studio's app, because portal-only
mode is decided from a local pref an empty browser does not have; and the
couple has no UI for inviting their partner, though the function behind it
exists.

- **`guest_invites` push → pull on a second device.** Do the invitations and
  the per-event seating survive?
- **A couple signing into the portal.** Migration 10 redefined
  `gem_is_event_client` / `gem_client_can_edit` to reach through
  `parent_event_id`, and everything the portal shows across a weekend rests on
  those two functions. Confirm a couple attached only to the primary can see
  the rehearsal dinner, and still cannot see leads or vendor fees.
- **The invite flow end to end** — `gem_invite_client`, claiming on first
  sign-in, `gem_invite_partner`, revoke.
- **A photo and a document**, pushed then pulled on a second device. Storage
  policies were fixed in migration 08; this is where a mistake would show.

---

## 6 · Open, not started

- **Branded email** — Resend or similar + SPF/DKIM on `gemevents.app`, then
  Supabase SMTP. Blocks the portal invitations being useful.
- **The portal's first thirty seconds.** Portal-only mode is decided at boot by
  matching `location.hostname` against `prefs().portalHost`, which is a local
  preference — so a couple's first ever visit to `portal.gemevents.app` gets the
  studio's dashboard, sample wedding and onboarding tour included. It rights
  itself on the second load, once a pull has brought the pref down. The portal
  host needs to know it is the portal without having been told by a previous
  visit. See `VERIFY.md` §F1.
- **Let the couple invite their partner.** `gem_invite_partner` and
  `sbInvitePartner()` both exist; nothing calls the wrapper, and the portal
  already tells the couple they can add someone. `VERIFY.md` §F2.
- **Realtime** — deliberately not doing it. Polling on focus plus a three-minute
  timer covers 1–3 devices. Both halves are wired now; for a long time only the
  focus half was, and it only *warned* rather than pulling.
- **PDF export** — print sheets go through the browser dialog, where every
  platform offers Save as PDF.

---

## 7 · Conventions

- ES5 style in the artifact: `var`, `function(){}`, no arrow functions or
  template literals. Match the surrounding code.
- Comments explain **why**, especially where something looks odd. If a line
  exists because of a bug, say which bug.
- Migrations are numbered, guarded so they can be re-run, and end with a single
  `select` of booleans — the SQL editor only shows the last result.
- Colours: `EVENT_TINTS` is assigned by position, not by hashing an id, because
  a hash collides. Every tint is ≥4.6:1 against the card.
- The sample wedding is **read-only** and badged. `sampleBlock()` is one
  capture-phase gate on `.main`; `SAMPLE_SAFE` is the allowlist of things that
  still work. "Use this as my project" adopts it; if a control mysteriously
  does nothing on a client or event, check for the sample banner first.
