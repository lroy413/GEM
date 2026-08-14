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

Migrations **01–15 are all run** against the live project.

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

### Two traps that have caused real bugs

1. **`sbMigrateIds()` rewrites every id on the first push.** Anything holding a
   reference must be fixed there: `leadId`, `parentId`, `tagEventId`,
   `tableId`, and an invite's `guestId`/`eventId`/`tableId`. Miss one and the
   first push sends a row pointing at an id that no longer exists.
2. **Events must be pushed parents-first.** `events_parent_guard` is a BEFORE
   ROW trigger, so it fires as each row lands, not at end of statement. The
   payload is sorted accordingly.

---

## 3 · Things worth knowing before you change the UI

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
- **Per-event imagery** — the one remaining item from the dashboard review. The
  hero is where it belongs; the question of which event takes precedence is
  answered by the deck (date order) rather than by picking a favourite.
- **Drag to reorder the dashboard.** The modules are already an ordered list in
  prefs with up/down controls in Settings → Appearance; drag is a small change
  on top.
- **Realtime** — deliberately not doing it. Polling on focus plus a timer covers
  1–3 devices.
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
