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

Migrations **01–19 are all run** against the live project, each verifying all
true. **20 and 21 are not.**

**Migrations can be run before you ship them.** Postgres is installable in the
dev container; a shim for `auth.uid()`, `storage.foldername()` and the three
Supabase roles is enough to run the whole set end to end and exercise the
functions. That is how 17, 18 and 19 were checked. Do this rather than
reasoning about SQL.

`20_client_cover.sql` adds `leads.cover_path`, for the client file's own
banner. Unlike `16`, this one is safe to ship ahead of: the client asks the
database once whether the column is there and omits `cover_path` from the
payload until it has seen it, so a studio that has not run 21 simply does not
sync covers. That guard is `sbCoverCol()`, and it exists because the events
payload carried `photo_path` on every row whether or not an event had a cover,
which made PostgREST refuse *every* events push for weeks.

`21_venues.sql` carries the venue directory: a `venues` table, `events.venue_id`
as a nullable FK with `on delete set null`, and RLS matching the rest. Safe to
deploy ahead of — `sbVenueTbl()` probes for the table and the venues step is
dropped from the payload until it answers yes, and `sbPull()` asks for venues
separately so a 404 cannot fail the whole pull.

**19 was half-applied for a day.** The table landed and the policies, grants
and `gem_sync_health()` did not, because what reached the studio was an
abridged snippet rather than the file. If you are ever tempted to post "the
essentials" of a migration, don't: the front half of every one of these files
creates tables and the back half secures them.

**Verifying a function exists:** `to_regproc()` takes a bare NAME. Hand it a
signature with parentheses and it returns null whether or not the function is
there, which is how a healthy database was mistaken for a broken one. Use
`to_regprocedure('f(uuid)')`, or query `pg_proc` by `proname`.

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

- **Never index DEFAULT by position.** `normalize()` filled a missing `design`
  from `DEFAULT.events[i]` — the sample's palette, mood boards and décor handed
  to whatever event happened to sit at the same INDEX. After a pull that is the
  studio's own first event. Match the seed by id; the sample's content must
  only ever reach the sample's record.
- **`auth.uid()` is NULL in the Supabase SQL editor.** It runs as `postgres`,
  not as a signed-in user, so anything shaped like
  `where user_id = auth.uid()` matches nothing and the query returns "success,
  no rows" — which reads exactly like a clean bill of health. Pass the org id
  literally, or select it from `orgs`. Same class of mistake as `to_regproc`
  with a signature: a broken query whose failure is indistinguishable from a
  good answer.

- **A pull that writes preferences must also APPLY them.** `sbPull()` wrote the
  studio's branding into `settings` and stopped, so a new device kept the
  default gold and no logo until the next reload — indistinguishable from
  branding that had never synced. It calls `applyPrefs()`, `applyBrand()` and
  `paintIdentity()` now. It was also gated on `org_prefs.stages` being a
  non-empty array, so a studio that had never renamed a pipeline stage received
  NO preferences at all. Stages are one preference among many, not the test for
  whether the rest exist.
- **`margin-top:auto` plus `position:sticky` means nothing follows it in flow.**
  `.side-foot` therefore overlays the items above it whenever the list is long
  enough to scroll — Analytics and Tax Tool were unreachable on a phone — and
  no amount of `padding-bottom` on the scroller can push them clear, because
  the padding sits after an element that is already last. Below 860px it is
  `position:static` and scrolls with everything else.
  `scratchpad/navreach.mjs` opens every nav group, scrolls to the end and
  asserts that no `.nav-item` is behind the footer or the tab bar.

- **`pullLoss()` counts WORK, not records.** A device with nothing saved seeds
  the demo — one client, its events, four documents, six vendors — so counting
  raw lengths made a brand-new phone look like it was holding six vendors the
  studio had lost. The guard then refused the pull, at the one moment a new
  device most needs one, and left the planner looking at the sample believing
  it was their studio. The sample is never pushed, so the studio is *right* not
  to have it; anything compared against the server has to be filtered through
  `isSampleRecord()` first. `scratchpad/pullloss.mjs` covers the three cases
  that matter: sample only, real work the studio lacks, and both together.

- **A warning with no timeout needs a way out.** `sbSetStatus('warn', …)`
  deliberately never clears itself — a message about your data should not
  vanish while you are reading it — which meant on a phone it sat over the tab
  bar until the app was closed. Warnings are dismissible now, and the dismissed
  TEXT is remembered in `SB_MUTED` for the session, because auto-pull runs on
  focus and on a three-minute timer and would otherwise put it straight back. A
  different message still gets through; a reload still reports the condition.
- **The tour is for a person's first time, not a browser's.** It used to fire
  whenever `gem-tour-done` was missing from localStorage, so signing in to an
  existing studio on a new phone replayed the whole thing. Taking the "I already
  have one" door marks it done outright, skipping counts the same as finishing,
  and `tourDone` rides in the synced prefs so a pull tells a fresh device the
  studio has already been shown around.
- **`position:sticky; bottom:0` sticks to the SCROLLPORT.** `.side-foot` lives
  inside a `height:100vh` sidebar, so `padding-bottom` on the container could
  never lift it clear of the tab bar — it has to be given the bar's height as
  its own `bottom`. That is why the settings gear was unreachable on a phone.

- **The phone navigates from the bottom.** `.tabbar` is five fixed tabs plus
  More, which opens the same drawer the desktop rail lives in — so there is one
  set of destinations, not two to keep in step. Deliberately NOT a horizontally
  scrolling row of nineteen: what is off the end of a scroller is invisible and
  you can never learn where a thing lives, which is why every platform's tab
  bar caps at five. The bar sits ABOVE the drawer on purpose (tapping More
  again closes it), so the drawer carries its own `padding-bottom` to keep its
  footer reachable, and `.main` carries the same to clear the bar.
- **`env(safe-area-inset-bottom)` on anything pinned to the bottom.** Without it
  the tab labels sit under the iPhone home indicator.
- **A scroll box inside a scrolling page is the worst thing on a touch screen.**
  `.tasks` scrolls on desktop and is `max-height:none` below 860px; what keeps
  the phone page bounded there is the render cap, not the box.
- **The To Do list renders at most 20 rows** (`TASK_CAP`), allocated in order of
  urgency — overdue, today, this week, later. A group past the budget still
  draws its heading and its true count, because "LATER 31" is information; it
  just does not draw thirty-one rows. A line at the foot says what was held
  back so the number on the badge and the rows on screen never disagree.

- **`1fr` is `minmax(auto, 1fr)`, and that `auto` is the column's MIN-CONTENT
  width.** Put one `white-space:nowrap` string in a grid cell and that column
  grows to fit the whole string, pushing every other column off the screen.
  It happened twice — the week strip and the month calendar — and on a phone it
  is invisible in testing unless you seed a long task title. Every grid whose
  cells hold user text wants `repeat(N, minmax(0, 1fr))` and `min-width:0` on
  the cell. `scripts`-free check: `scratchpad/fit.mjs` walks every screen at
  360/390/430 and reports anything past the right edge.
- **`text-overflow:ellipsis` does nothing to a flex container's own text.** It
  needs the text in a child that can shrink — `.cal-ev` had the label as a bare
  text node beside the dot, so it never clipped; it just widened.
- **A month grid cannot carry labels at phone width.** A cell is about fifty
  pixels, which holds a date and nothing else. Below 700px the chips are hidden,
  the day shows coloured dots, and `.cal-agenda` lists the same month in full
  underneath — built in the same loop as the grid so the two cannot drift.

- **Two faces, both inlined, both OFL.** Cormorant Garamond 600 for display,
  Karla 400–800 for everything else. Karla is a VARIABLE file — one 24KB woff2
  covers the whole weight axis, declared `font-weight:400 800` with
  `format('woff2-variations')`. Do not add per-weight faces; ask the variable
  file for the weight. The artifact CSP blocks font CDNs, so anything new has
  to be base64 in the same way.
- **An icon has to say what its screen does.** The first drawn set was
  internally consistent and still wrong — a diamond for Dashboard, a bulleted
  list for Guests, an abstract cluster for Vendors. They are literal now: a
  panel layout, a person with a tick, a tag, a photograph for the archive, a
  clipboard for questionnaires, an eye for the portal, a receipt for invoicing,
  a pie with a slice set aside for tax. And settings is a **gear** — testers
  did not know the lozenge opened settings. It is the one place where the
  universal symbol beats a house one.

- **Three surface tiers, and they mean something.** `PLATE` (imagery or deep
  ink, no border, `--radius-plate`) for the one thing you are meant to look at;
  `CARD` (hairline + contact shadow, `--radius`) for working surfaces; `RECESS`
  (`--sunk` fill, `--sunk-line` inset, no shadow, `--radius-sm`) for figures,
  empty states and clear days — things that support a card rather than compete
  with one. Before this everything was one surface, so nothing on a screen was
  more important than anything else. If you add a panel, pick a tier.
- **The house gold is a metal, and it stops reading as one when it fills a
  shape.** `var(--gold-grad)` across an event card banner, an archive tile or a
  venue tile is a slab of poster colour; all three were corrected to a pale
  wash or to tinted ink. Gold belongs in hairlines, marks and small type.
  Anything painted on it has to be re-checked for contrast — the event card's
  date chip was white on translucent black and became invisible.
- **The rail icons are drawn, not typed.** No font has nineteen geometric marks
  at one optical weight: the shade blocks (▥▤▧) came out dense and black while
  the part-circles (◐◑◒) rendered a third the size. They are inline SVG on one
  20×20 grid at one stroke weight now, in `<svg class="ic">`, and there is no
  font substitution left to defend against.
- **Case has a rule now.** Section and card headings are Title Case — they read
  as named parts of a document. Everything you *do* is sentence case: buttons,
  modal titles, row actions. It had drifted about half and half.

- **A day with nothing on it is information.** The week strip's `.quiet` cells
  go flat and unlifted on purpose, so the days that hold something are the ones
  the eye lands on — but `.quiet` came after `.today` at the same specificity
  and was flattening today along with the rest. `.wk-d.quiet.today` puts the
  ring back. Today is the anchor for reading every other column; it is marked
  whether or not it holds anything.

- **The venue directory is built by the DEVICE, never by the database.**
  Migration 21 deliberately has no backfill, and its name index is deliberately
  not unique. An earlier draft had both, and together they were a push that
  409s: `normalize()` lifts the same directory out of the same events with ids
  it owns, the upsert resolves on the primary key and cannot see an expression
  index, so a device pushing its own "The Glass Conservatory" hit the unique
  constraint the migration's own backfill had already satisfied. Two rows with
  the same name is a tidiness problem; a failed push is the failure this sync
  was rebuilt to prevent. The client refuses a duplicate name where it is
  typed, which is where the question belongs.
- **`VENUES_LIFTED` exists because the lift has to be written down.** The guard
  on rebuilding the directory is the existence of `d.venues`, so if the first
  lift is never saved, a studio that then adds one venue by hand has an array
  on the next load — and the guard sees it and never rebuilds the rest, quietly
  emptying the directory.
- **`.dh-band > *` sets `position:relative` at the same specificity and later
  in the sheet than anything you add for a child of the band.** A watermark
  written as `.vn-band-mark{position:absolute}` loses, becomes a flex item, and
  shoves the name to the far side. Qualify it: `.dh-band .vn-band-mark`.

- **The demo is recognised by fingerprint as well as by flag.** `sample` is a
  local boolean; a demo record that has been round-tripped through Supabase
  comes back as ordinary data, so Remove found nothing while six invented
  florists sat in a directory the studio was trying to start from scratch.
  `SAMPLE_PRINTS` holds name-plus-address for the six shipped vendors and for
  Priya & Sam, and `sampleHit()` consults it. Editing either field breaks the
  match, which is the point: once a record is genuinely theirs, it stays.
- **`removeSampleData()` works out what is going BEFORE it deletes anything.**
  `vendors` is one of the `SAMPLE_IDS` collections, so by the time the main
  loop has run there is nothing left to ask which vendors went — and the
  bookings that pointed at them survived as rows the screen cannot draw. Both
  `goneEvents` and `goneVendors` are built up front for that reason.
- **A list of kinds of thing is a list somebody will need to add to.** Vendor
  categories are a `combo` field — an input with a `<datalist>` behind it — and
  the suggestions are what we ship plus whatever the directory is already
  using. Nothing is stored and nothing needs curating: a category appears when
  it is typed and stops being offered when the last vendor filed under it goes.
- **A client has two pictures and they are not interchangeable.** `photo` is a
  portrait, cropped to a circle, shown as a medallion on the file and a tile in
  the grid. `cover` is the banner, cropped 16:9 exactly as an event cover is,
  and `leadCover()` falls back to the event's cover rather than to `evPhoto()`
  — which would hand back the portrait and reproduce the stretched header this
  replaced. The cover is a second media object on the same record, so it is
  keyed `<leadId>-cover` in `mediaItems()`.

- **The archive is derived, not a state.** `archiveEvents()` is every primary
  whose date has passed, newest first; nothing is marked "done" and nothing has
  to be moved there. That means it is also the one screen where covers matter
  most, and where an event with no cover is most visible — `.arc-card` with no
  photograph puts the tint *under* ink rather than beside it, because
  `EVENT_TINTS` were drawn for dots and read as poster colour at card size.
- **The event's start time is a row on the timeline, and is not stored as one.**
  `tlRows(e)` merges a derived `{anchor:true}` row from `e.startTime` into
  `e.timeline`, and every surface that draws a running order goes through it —
  workspace, hero, portal, print, the bible. It carries no id and no row
  actions on purpose: it belongs to the field, so it moves when the field moves
  and cannot be deleted into disagreement with the header. It stands aside if
  the planner has already written a moment at that minute.
- **`toMinutes()` reads 24-hour times.** It used to fold the hour with `%12`
  whether or not a meridiem was present, so a legacy or pulled `16:00` sorted
  in at four in the morning. `normTime()` normalises anything typed in the app
  to `4:00 PM`, so this only ever showed up on data that arrived some other way.

- **Every push writes a row to `sync_runs`.** Opened after the claim, closed
  after the commit — so a run that dies leaves `finished_at` null and the
  unfinished state records itself, rather than depending on a client that is by
  definition no longer running. `gem_sync_health(org)` is the five numbers;
  `unfinished_24h` above zero means pushes are dying partway. Logging is never
  allowed to fail a sync: a studio without migration 19 simply gets no log.
- **The sample flag does not survive a round trip.** It is a local boolean with
  no column behind it, so a demo record pulled back from Supabase arrives as
  ordinary data: `hasSampleData()` goes quiet, the banner stops appearing and
  Remove finds nothing, while Priya & Sam is still on the dashboard. Migration
  18 gives it a column and a check constraint that keeps it false, which makes
  it a tripwire rather than a state. The thing that actually keeps demo content
  out of a studio is the client not sending it.
- **A push claims the studio, it does not finish it.** `sbBegin()` takes a
  lease and reports the version; `sbCommit()` moves it once the run is done;
  `sbAbort()` hands it back on failure. Never make the version move earlier
  than the last write — that is what invited every other device to come and
  fetch a half-written studio.
- **Deletion is explicit, and diffed against what THIS DEVICE last sent.**
  `gem-sb-sent` holds the id list per table from the last successful push; the
  rows retired are the ones that list holds and the payload no longer does.
  That is a different set from "everything the payload lacks", and the
  difference is the whole incident: a device holding a partial workspace lacks
  the other planner's client, and prune-by-difference read that as an
  instruction to delete it. Prune survives only behind the manual
  "make Supabase match this device" button, which is a person asking for a
  mirror. A first push after upgrading retires nothing, because nothing is
  recorded yet.
- **A page about one subject leads with that subject.** An event with a cover
  and a client with a photograph both put their own name on the picture and
  suppress the page title block (`.main.evfocus`), because otherwise the header
  says the same thing twice in a smaller voice. Without a picture the old head
  returns — an initials medallion is a finished answer, a grey slab is not.
- **A detail page is one gapped column** (`.detail-col`), not a margin per
  block. `evSection()` carries no margin of its own because in the event
  workspace `.ev-col` spaces it; dropped loose into a page it sat flush.
- **The title bar names the work, not the screen.** `pageHead(v)` returns
  `[eyebrow, headline, sub]` — the screen's own name goes in the eyebrow at
  label size, and the headline says what is true today (the countdown, what is
  in the pipeline, who has replied). A screen with nothing true to say returns
  an empty eyebrow and keeps its name as the headline rather than inventing
  something; add to `pageHead()`, not to `TITLES`.
- **The sidebar lock-up is a wordmark, not a tile.** A letter in a gilded
  square is what an app shows when no logo is set, so `applyBrand()` puts
  `no-logo` on `.brand` and the tile survives only in the collapsed rail and
  wherever a real logo exists. `.brand .sub` must never regain
  `text-overflow:ellipsis` — it was truncating the studio's own name.
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

- **Venue photographs in the portal.** A venue cover is filed under
  `<org>/venues/<id>`, and the storage policy's client branch reads the second
  path segment as an event id — `gem_uuid()` returns null for the literal
  `venues`, so the couple's branch never matches. That is deliberate: directory
  imagery is the studio's. If a venue photograph should ever appear in a
  portal, it needs its own policy rather than a moved file.
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
