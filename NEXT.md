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

Migrations **01–21 are all run** against the live project, each verifying all
true.

**They live in `supabase/migrations/` now**, with the timestamped names the
Supabase CLI and the GitHub integration expect, because the repo is connected
to Supabase and pushing a migration there deploys it. `supabase/config.toml`
carries the project ref.

**Run `supabase/SEED_MIGRATION_LEDGER.sql` once before the first push Supabase
acts on.** It creates `supabase_migrations.schema_migrations` as well as
filling it: that table does not exist until Supabase's own tooling applies a
migration for the first time, and on this project nothing ever has. All
twenty-one were applied by hand in the SQL editor, so the ledger has no record
of them and the
integration would treat every one as pending. That matters more than it
sounds: **01–05 are not re-runnable** — bare `create table` / `create type` /
`create policy`, which error with "already exists" on a second pass. Only 06
onward were written defensively. Applying the chain twice against a clean
Postgres 16 gives 21/21 then 16/21. Nothing is destroyed, but the deploy halts.

**Never run `supabase db reset` against the linked project.** It rebuilds the
database from these files and takes the studio with it.

**Migrations can be run before you ship them.** Postgres is installable in the
dev container; a shim for `auth.uid()`, `auth.jwt()`, `storage.foldername()`,
a `storage.buckets` table with `file_size_limit`, and the three Supabase roles
is enough to run the whole chain end to end. Do this rather than reasoning
about SQL — it is how the 01–05 problem above was found.

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

- **A phone is not a narrow desktop.** Several places spent a lot of screen on
  very little: `.stat-row` went to ONE column below 560px, so four figures cost
  about 800px of scroll to say four numbers (two columns now, the whole row is
  170px); the drawer's wordmark block was 100px before any navigation. When
  something looks roomy on a phone, measure it — `getBoundingClientRect()` in a
  390px viewport — rather than trusting how it looks in a resized desktop
  window.
- **The studio's name is the SUBTITLE in the brand block**, not the wordmark.
  `.brand .name` is the short mark, which can be a single letter. Hiding the
  subtitle to save space — which I tried first — leaves a studio whose mark is
  "E" looking at a lone E. They sit on one row on mobile instead.
- **The dashboard's To Do is capped by a preference**, `prefs().todoRows`,
  default 10 with 15 and 20 in Settings › Appearance. The card also collapses,
  remembered in `gem-todo-shut`, because Waiting On lives underneath it and a
  full list pushed that off a phone screen entirely.

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
- **Every headed table becomes cards below 700px.** Nine screens render a
  five- or six-column table; all of them were wider than a 390px phone, so
  they scrolled sideways inside `.tbl-wrap` — Amount sat off the right edge and
  the client's name wrapped to three lines to make room. `labelCells()` runs
  once per `render()`, copies each `<th>`'s text onto the cells beneath it as
  `data-l`, and tags the table `.as-cards` (plus `.has-acts` when a row has
  actions, and `.cards-wrap` on the scroller so it can stop being one). CSS
  reads the labels back with `content:attr(data-l)`. Consequences worth
  knowing before you touch a table:
  - There is **no phone-only render**, so nothing can drift and rotating the
    phone re-lays out with no JavaScript at all.
  - A cell holding only an em-dash gets `.is-none` and disappears on a card —
    a table needs the empty cell to keep its column; a card does not.
  - The **first cell is the card's title**, so put what the row *is* in
    column one. A cell whose header is blank is treated as the action column
    and floats to the card's top-right corner.
  - A header `<th>` may carry a bulk control (the guest grid's invite
    columns); those stay as chips above the cards. Everything else in `thead`
    is hidden.
  - Only tables **with a header row** qualify. The one exception is the vendor
    team table, which has none and still overflowed; it declares
    `class="as-cards has-acts"` and its own `data-l` in the markup.
- **`uid()` is called before its own counter is initialised.** `normalize()`
  mints ids at load and runs above `var _uidSeq=0`, so the counter was
  `undefined` and `undefined++` is NaN — every id minted in that window had the
  literal string "NaN" where the collision guard belongs. Guarded inside
  `uid()` now. Ids already stored keep their NaN; they are still unique
  strings and rewriting them would break every reference.
- **Attire is a chain, not a tick.** `guest.attire` is `{item, size, status,
  due, note}` in one jsonb column (migration 24, object-checked) — a value
  object with no identity, the same reasoning as `invoices.items`. The states
  are `ATTIRE_STEPS`, and `attireStep()` returning an index is what lets the
  chip colour itself by progress and the summary count by stage. It is edited
  from the chip on the Wedding Party card, never from the guest form: eight
  dresses is eight modals if the only way in is the row's pencil. An empty
  record is deleted rather than stored, or every guest on a 200-name list
  carries a row of blanks to every device.
- **The rehearsal was already expressible.** A rehearsal is a sub-event with
  `role:'rehearsal'` and attendance is a row in `db.invites`; `rehearsals(e)`
  finds them and the party card adds the one action the app was missing —
  invite everyone standing up, in one tap. With no rehearsal on the weekend the
  bar offers to make one rather than hiding.
- **The wedding party is guests with a role, not a second list.** `guest.role`
  is free text; `PARTY_ROLES` supplies the conventional names — both forms of
  each, because a wedding party is not a gendered list — and the number beside
  each is the **processional order**, so the running order derives itself and
  nothing has to be dragged. `roleOrder()` sends an unrecognised role to the
  back rather than the front. `partyByRole()` groups for the card and the print
  sheet. Filing them separately would mean two rows for one person and two
  counts that disagree the week of the wedding — a bridesmaid RSVPs, eats and
  sits like everyone else. Migration 23 adds the column; `sbRoleCol()` probes
  for it the way `sbCoverCol()` does.
- **A card that lists something needs the action that adds to it.** The
  Wedding Party card had no way to put anyone in it — you scrolled past it to
  the guest list, found the person and edited a field. `openPartyAddModal()`
  does both cases in one action: pick a name already on the list (they get a
  role, not a second row) or type a new one (a guest is created with it). The
  picker deliberately offers only guests who are NOT already standing up, and
  `showIf` hides the name and party fields the moment an existing guest is
  chosen.
- **Silence is the good case.** The Wedding Party card printed "Attending"
  beside every name — which says nothing eight times, since standing up
  already implies coming. The RSVP now appears only when it is NOT a yes, and
  declined carries the warning colour. Same reasoning moved the side chip up
  to the role heading when a whole group shares one, instead of repeating it
  down the card.
- **Chips go in one right-aligned block, not loose in the row.** `.wp-tags`
  wraps them as a unit, so a person with an allergy and a person without still
  line up down the card — before it, `margin-left:auto` on the last chip put
  "Attending" alone on a second line and left rows 32px and 63px tall
  alternately. `.wp-role` is 230px because that is what the longest
  conventional role plus its count plus a side chip needs; narrower and
  "Honour Attendant" wraps while "Bridesmaid" does not.
- **The event switcher is context, not an action.** It sits in `#pgActions`
  with the buttons, which on the guest screen made four controls of equal
  weight wrap onto two ragged lines. Below 700px it takes its own full-width
  line — but only where the group also carries `.btn-icon`, i.e. only where
  there are enough actions to need it; breaking it out on Seating or Design
  costs a row to gain nothing. The `#pgActions:has(.btn-icon)` compaction that
  tucks Print/Edit beside the title now excludes groups holding a switcher or
  a primary button, or it squeezes the whole guest toolbar into the title's
  row.
- **A screen's primary action belongs at both ends of a long list.** Add guest
  lived only in the topbar, so on a 200-name list you scrolled up, added one
  and scrolled back. `#addGuestFoot` repeats it at the foot of the card, the
  way `.sec-actions` already does for Book a vendor.
- **The guest card is not the generic table card.** Below 700px `.g-tbl` gets
  its own layout: name and the RSVP picker on line one, the party quietly on
  line two with the row actions right-aligned beside it, and the facts as chips
  on line three. A chip needs no caption — nobody reads "Beef" and wonders
  which column it came from — so `.g-tbl td::before{display:none}` turns off
  the generic labels. Two traps in here: the generic
  `.as-cards td:not([data-l]):not(:first-child)` outranks `.g-tbl td.g-acts` on
  specificity and parked the actions on top of the RSVP (hence the
  `:not(.g-tbl)`), and the actions need their **own cell** rather than living
  inside Table, or they wedge against the word "Unseated".
- **Two dropdowns used to answer questions nobody had asked.** The meal picker
  offered Beef / Fish / Vegetarian / Kids to every studio in the world, and
  `guest.side` — a column that has existed since migration 01 and round-trips
  through Supabase already — was hardcoded to `'A'` on every guest the app ever
  added, so everyone belonged to partner 1. Both are real now:
  - `mealOptions(e)` is derived, never declared: the meals already used across
    this weekend's events and invitations. The field is a `combo`, so the first
    guest's meal is typed and the eightieth is picked. There is no menu screen
    to fill in first, and no option the studio did not put there.
  - `evHasSides(e)` gates the side control to weddings — a corporate gala has
    no sides and asking is a question with no right answer. `sideNames(e)` uses
    the couple's own first names from the client file. The default is "Both /
    neither", the only answer the app actually knows; it persists across "Save
    & add another", so a family is one tap then a run of names.
  - No migration: `guests.side` is already in the schema, the push already
    sends it and the pull already reads it. It was only ever the UI that was
    missing.
- **The phone bar's height is the buttons' height.** `.tab` is `min-height:44px`
  with the content filling it exactly; `.tabbar` carries no vertical padding of
  its own, so there is no strip that looks like the bar but does not answer a
  tap. Two things to know before shrinking it again: the icon size is NOT what
  makes it tall — the min-height does the measuring, so taking 2px off the icon
  costs legibility and saves nothing; and the safe-area inset is `max()`, never
  `+`, because a 34px home indicator already is the clearance and adding to it
  makes the bar 4px taller than the screen needs. 45px on a phone with no
  indicator, 79px with one.
- **`x.onclick = fn` hands the handler the click event.** Every function
  wired that way must therefore take no arguments, or refuse a DOM event.
  `openGuestModal(ev)` and `openSwatchModal(board)` both took one, so Add
  guest built a modal around a MouseEvent and Add colour said "Adding to ."
  and threw on save. Both are wrapped at the wiring now *and* guard
  themselves; `openTableModal`, `openVendorModal`, `openDocModal`,
  `openQuestionnaireModal`, `openLeadModal`, `openInvoiceModal`,
  `openBoardModal` and `openQuestionModal` take nothing and are safe bare.
- **The guest list has two modes** (`prefs().guestView`, in the whitelist):
  the grid, and a deck — `guestStack()` / `guestCard()`. The deck renders
  three cards from the same records with the same class names, so
  `wireGuests()` wires it without knowing it exists; position lives in
  `state.guestIdx` and is clamped by `guestIdx(n)` because a search can make
  the list shorter than the card you were on. Its swipe handlers are
  **assigned, not added** — `render()` re-wires the view and several callers
  still follow it with a `wireGuests()` of their own, so a stacking listener
  fires twice and one swipe dealt two cards.
- **An invoice is a document now** — `viewInvoiceDetail()` and
  `invDocMarkup()`. Things to know before you touch one:
  - **The lines are the record; the total is derived.** `invSub` → `invTax` →
    `invTotal`, and `invRecalc()` writes the answer back to `amount` on every
    change. Everything else in the app reads `amount` — the dashboard alert,
    the stat row, the CSV export, the Supabase column — so an invoice whose
    stored total disagreed with its own lines would be wrong everywhere at
    once. An invoice with no lines keeps `amount` as its own truth, which is
    every invoice written before this existed.
  - **Overdue is computed, not stored.** `invStatus()` compares the due date
    with `todayLocal()`; nothing writes `'over'` to disk, so an invoice does
    not become late because someone opened the app.
  - **`invDocMarkup(x, forPrint)` builds one document two ways** — the class
    prefix is the only difference (`iv-` on screen, `pi-` in the print frame).
    A studio whose PDF did not match its portal would have two invoices.
  - **A document labelled Invoice raises one**, via `invoiceForDoc()` — on
    creation, on upload, and on relabelling. Created only, never overwritten:
    once the invoice exists it may carry lines and payments the file knows
    nothing about. Deleting either side unlinks; neither cascades.
  - **The link goes one way on the wire.** `documents.invoice_id` only —
    documents are upserted after invoices, so the row it names exists by then.
    Both directions would be a circular foreign key that fails whichever table
    goes first. The pull rebuilds `invoice.docId` from the document side.
  - **Migration 22 carries the lines** (`items`, `payments`, `tax_rate`,
    `issued_date`, `notes`, `pay_link` as jsonb/scalars). `sbInvCols()` probes
    for it exactly as `sbCoverCol()` does, so a studio that has not run 22 can
    still push — naming a column the database lacks fails the whole table.
  - **Paying in the app means the studio's own checkout.** GEM never touches
    the money: `prefs().payLink` (or the invoice's own) is opened by a Pay
    button in the portal, and a balance with no link shows the terms instead.
    A real in-app card payment needs a payment processor and a server to hold
    its secret — neither exists here yet.
- **A 200-name guest list needs to be askable.** `party` was the only grouping
  and it holds one value, so it could not also say "out of town", "kids'
  table", "bus from the hotel". Two things were added together, because
  neither is useful alone:
  - **Labels** (`guest.tags`, an array, migration 25) — as many per guest as
    the studio wants, invented by them. Stored only when non-empty: an empty
    array on every guest is two hundred empty arrays in local storage, which
    is the same reasoning `attire` uses. `setTags()` is case-insensitively
    unique with the first spelling winning, so "Out of town" typed twice in
    two cases is one label rather than two that filter differently.
  - **A filter bar** — side, RSVP, group, label, seating, meal, invited-to,
    plus dietary-needs-only and wedding-party-only. `state.gFilter`, in memory
    and deliberately **not** saved: a filter that survives a reload is a guest
    list with half the names missing and nothing on screen saying why.
  - **`guestsShown(e)` is the single definition of who is on screen** — search
    first, then filter. The stat row, the meal counts, the bulk invite, the
    deck and "Label these N" all read it, so none of them can drift from what
    the list is showing.
  - **Tapping a set value clears it**, so no control needs an "off" of its
    own — which is what keeps the panel to one row per question. The active
    filters also appear as chips above the list whether or not the panel is
    open, each removing itself.
  - **"Label these N" is the point of the whole thing.** Filter to the twelve
    you mean, name them in one action. Labelling two hundred people one row
    editor at a time is how a field ends up never being used.
  - **A `tags` field type in `openEditor`**: a datalist is no good for several
    values in one field (picking one replaces what is typed), so the
    suggestions are buttons that append — and tapping one again removes it.
  - **The Labels column only exists once a label does** (`tagsUsed`), like the
    Role column. A column of em dashes is not a feature.
  - **Migration 25** adds `guests.tags jsonb not null default '[]'` with an
    is-array check and a partial `gin (tags jsonb_path_ops)` index, and
    `sbTagCol()` probes for it exactly as `sbAttireCol()` does. Verified
    against local Postgres: default, containment query, and the check refusing
    an object.
- **A phone pass over the project screens, from a real device.** Six separate
  complaints, all of them about weight and space rather than function.
  - **A checklist task cost 258px and three stacked lines** — name, then the
    date and category pills on an indented line of their own, then the edit and
    delete buttons on a third, because `.r-acts` is always visible on a touch
    screen and had nowhere left to wrap to. Two 32px bordered squares ended up
    the loudest thing in the row, louder than the tick box. Under 700px the row
    is a grid now: `"box lbl lbl" "box meta acts"`, so the name owns the full
    width, the date drops its pill and reads as plain muted text beside the one
    category chip, and the actions sit at the right of the meta line as quiet
    borderless glyphs. 83px, and six tasks fit where three did.
  - **`.modal-actions` had no `flex-wrap`.** Three buttons come to 358px inside
    a 315px row on a phone, and with `justify-content:flex-end` the FIRST one
    was painted 34px off the modal's left edge — "Save this checklist" arrived
    as "ave this checklist". That painted overflow is also what made the page
    drift sideways while scrolling a modal. Wrapping is the fix; below 560px
    the buttons also share the row evenly so a wrap does not read as debris.
  - **The new-event form asked where the event was three times**: a free-text
    "City / region" (`e.loc`), then the address's own City and State / region.
    `e.loc` is only ever a short display string, so it is derived from the
    address on save now and no longer asked for. An older event with a `loc`
    and no address seeds the City box rather than losing it.
  - **Inside a project, the page is about the project.** The `‹ All projects`
    link came off the top of the project screen — the nav, the switcher card
    and the Projects tab are three ways out already, and a fourth sitting above
    the headline said the screen was somewhere you pass through. `＋ Add a
    sub-event` moved from a bar above the content to a dashed offer at the foot
    (only when the project has no weekend; when it has one the bar stays,
    because then it is navigation). And with no cover photo the four figures
    come before the venue card: a photograph is a header, an address is a
    detail.
  - **Edit and Print are words again.** As `btn-icon` they lost their labels
    below 560px and became two unidentifiable marks in the corner. They are
    `btn-sm` now, and `#pgActions:not(:has(.ev-switch)):not(:has(.btn-gold))`
    keeps any purely-secondary group on the title's row instead of costing a
    row of its own — about 110px of blank, on the screen whose whole complaint
    was blank at the top.
  - **A project ran to 5.3 phone screens.** The timeline, the vendor team and
    the documents are 2,300px of it and none is what you open a project to
    check, so on a narrow first load they join the guest list in starting
    collapsed — 2.9 screens, everything one tap away, each section header
    acting as its own index. A default only; the moment anyone opens one it is
    remembered.
  - **The guest screen led with three buttons of equal weight** for one
    everyday action and two CSV utilities you use twice a year. The utilities
    moved to the foot of the list they act on, as words; they wire in
    `wireGuests()` now, because `wireActions()` runs before `render()` paints
    `#content`. And `evSwitcher()` is scoped to `evBlock(activeEvent())` — it
    used to list every event in the studio, which made it a second project
    switcher able to take you out of the project you were standing in. It
    answers "which night" now, and says nothing at all when there is one night.
  - **`.btn-gold` lost its `text-shadow`** and half its inner highlight.
    Embossed white-on-gold type is the single thing that made the primaries
    read as chunky rather than expensive. `.chk-tab.on` lost its solid gold
    fill for the same reason — a filter should not be the loudest thing on the
    screen.
  - `scratchpad/polish-test.mjs` covers all of it at 393 and 1400.
- **Why a form could still pan sideways on an iPhone, and what a time field
  should ask for.**
  - **`input[type=date]` was the culprit.** iOS Safari gives it an intrinsic
    minimum width from its own date format at the field's font size — and
    coarse pointers force 16px here to stop zoom-on-focus — so `width:100%`
    could not shrink it and the box ran past the modal's right edge. Because
    `.modal-scroll` is `overflow-y:auto`, its `overflow-x` resolves to `auto`
    too, and the whole form became horizontally scrollable: it drifted left and
    took the first characters off every label ("PART OF" reading as "T OF").
    Three rules, because any one alone leaves a way back in: `-webkit-appearance:
    none` on date/time/datetime-local so the control sizes like a text box,
    `min-width:0` on `.field` and its controls (grid and flex children default
    to `min-width:auto`), and `overflow-x:hidden` on `.modal-scroll` so no
    future field can pan a form again.
  - **The time field takes digits and a tap.** `fmt:'time'` boxes now render
    inside a `.t-row` with an AM/PM pair beside them. `inputmode="numeric"`
    was already there, so "430" off the number pad plus one tap is a whole
    time — nobody types letters, and nobody has to fall back on 17:30 to be
    unambiguous. The pair READS the box rather than holding a value of its
    own, so it is right whether the time was typed, tidied on blur or loaded
    off a record, and there is never a second opinion to keep in step. Empty
    box: the pair is muted, and a tap still answers ("morning" → 9:00 AM,
    "evening" → 5:00 PM) rather than being dropped. A range — a timeline
    moment's "9:00 AM – 10:00 PM" — has two halves and no single answer, so
    `.is-range` hides the pair instead of lying about one of them.
  - `scratchpad/time-test.mjs` covers both at 393 and 1400.
- **A template applied to a late booking used to arrive already overdue.** A
  template's offsets are "N days before the event", written for a job with a
  full run-up. Applied to a wedding seven weeks out, a twelve-month countdown
  put seventeen of its twenty-eight tasks in the past — a brand-new checklist
  whose first act was to show you seventeen overdue items. The only remedy on
  offer was a tick-box, on by default, that DELETED them, and "Book the venue"
  is not a task you skip because you booked late; it is a task you do now.
  - **`templateOffsets(items, evDate)`** fits the countdown to the time that is
    actually left. Everything that still fits keeps its exact day — a final
    walk-through is three days before the wedding whether the job was booked a
    year out or a month out, because those offsets are tied to the event and
    not to the runway. Only the prep work above them is squeezed, evenly and in
    its original order, into the gap between the last task that fits and today.
    Nothing lands in the past, nothing is thrown away, and the order a planner
    works in survives. Seventeen tasks landing in the next nine days is not a
    layout failure — it is what booking a wedding seven weeks out looks like.
  - **The tick-box is off by default now** and says what it does: "Leave out
    the tasks there is no longer time for". Dropping work is a choice, not the
    default.
  - **The modal's subtitle explains itself** rather than stating a rule that
    was not being followed: with a full run-up it still says dates are worked
    backwards from the date; when they are fitted it says which template, how
    much time is left, how many moved, and that nothing lands in the past. The
    preview shows the fitted dates, marked FITTED, so what is on screen is what
    gets added — `plan()` is the single place the dates come from.
  - Event with no date: the tasks arrive without due dates. Event today or
    already gone: everything is due now, and says so.
  - `scratchpad/tpl-test.mjs` covers a 51-day run-up, a 420-day one and the day
    itself, at 393 and 1400.
- **The venue band with a cover photo had two left margins on a phone.** Wide,
  `.has-cover` is one horizontal caption bar under the picture: where it is and
  how to get there on the left, the venue contact on the right. So `.vb-side`
  was given `padding:13px 26px 13px 0` — no left padding, correct for the right
  of a row. On a phone the row wraps into a stack and that padding is suddenly
  the wrong axis: the address sat 26px in and the venue contact sat hard
  against the card's edge, with nothing but air between the blocks. Two margins
  in one card is what makes a layout read as broken rather than merely narrow.
  - Below 700px the band is laid out as the stacked card it has become — one
    margin, `border-top` rules where there was only white space, and type at a
    size that survives arm's length (address 14px, contact name 16px). The two
    contact lines are a phone call and an email, so they get 14.5px and a 38px
    target rather than caption sizing.
  - **`.vb-banner` inherited `justify-content:space-between` from its row
    layout.** Turned into a column on a phone that pushes the title to the top
    — under the camera and close buttons — and the date to the bottom, with a
    void between. Both belong at the foot, where the scrim is darkest and the
    buttons are not. The scrim also starts at 34% opacity from the very top
    now: a poster is not a photograph, it is already full of high-contrast
    type, and white type over the top of one needs cover.
  - **`fmtPhone()`** — ten digits becomes "(770) 508-8488", eleven starting
    with a 1 is the same number wearing its country code. Anything else — an
    international number, an extension, a note in the field — is left exactly
    as typed, because guessing at a format we do not know is worse than the
    digits. Every place a number is DISPLAYED reads through it (venue contact,
    client file, client panel, vendor rows); the `tel:` href is always the
    stripped digits.
  - A solo project's `.vb-switch` is no longer rendered as an empty div, which
    was claiming a flex gap either side of itself.
  - `scratchpad/vb-test.mjs` covers with and without a cover, at 393 and 1400.
- **The calendar could be read and not written to, and its link out of a
  project did nothing.**
  - **"Open calendar ›" was dead on the one screen it matters on.** The week
    strip navigates by `[data-goto]`, which only `wireDashboard()` bound — and
    `wireDashboard()` only runs at the front door. On a project's dashboard the
    strip rendered and neither the link nor its quiet days did anything.
    `wireEvents()` binds it too now, and `[data-goto]` joined `SAMPLE_SAFE`
    because navigating is never a write.
  - **A day is a control.** Every cell carries `data-day` and opens
    `openDayModal(iso)`: what is on that day (events, leads, tasks with the
    project they belong to, invoices due) and `＋ Add a task`. The task is an
    ordinary checklist item on a project — so it shows in that project's list,
    its week strip, its overdue grouping and back on the calendar. There is no
    second kind of task and nothing to keep in step. The project select
    defaults to the active one and lists them all, because a studio calendar
    shows every job and the day you tapped may belong to another.
    `checklistCats()` suggests the categories this studio already uses.
  - **The month controls wrapped onto two rows** on a phone — "‹ Today" then a
    stranded "›" — once purely-secondary action groups started sharing the
    title's row. They are one `.btn-group` (`flex-wrap:nowrap`) at `btn-sm`
    now, and `.page-head{min-width:0}` lets a long title yield to them.
- **`theme-color` was a hardcoded powder pink.** The browser paints the strip
  behind the status bar from it — and, added to a home screen, the whole status
  bar — so on any other palette that strip stayed pink while the page under it
  went green, and the app appeared to stop short of the top of the screen.
  `applyBrand()` sets it from `--wash-a`, the top of the page's own gradient,
  which is exactly the colour the strip should be continuing. `hslToHex()`
  exists because theme-color wants a plain colour and Safari has been fussy
  about `hsl()` in it.
  - `scratchpad/cal-test.mjs` covers the link, the day sheet, the task landing
    on the right project's checklist, the one-row controls and the theme colour
    changing with the palette, at 393 and 1400.

  Once every screen is inside a job, the old shape leaves the same facts in
  three places. What was actually duplicated: the client's contact details on
  the workspace *and* on their file; documents in the project, in the studio
  list and on the client file; a job's money split across a project Budget, the
  studio's Invoicing and the client's Invoices; and Messages and Client Portal
  sitting under a studio heading while reading `activeEvent()` — global-looking
  screens behaving locally, which is the one that confused most.
  - **Inside a project the client is a panel, not a screen** (`clientPanel()`):
    who they are, tap-to-call, tap-to-write, a line naming their other projects,
    and one door to their file. A project has one client; a client has many
    projects, which is exactly why the file still earns its place at the studio
    level.
  - **`money` is a project view**: this job's invoices (matched by event, and
    for older records by client), what has been collected, what is still owed,
    and the budget. Budget & Invoicing stays as the studio roll-up.
  - **The dashboard is the project's own week and its own list.** `weekDays()`
    and `weekStrip()` take an optional project and narrow to its events, tasks
    and invoices; the checklist is grouped by due date (`chkGrouped()`) and
    lives at the top. There is no separate Checklist section — one list, or
    people keep two of them.
  - **The nav's "This project" group is Dashboard, Guests, Seating, Design,
    Money, Messages, Portal**, and the studio's Client group keeps only what is
    genuinely studio-wide.
  - `scratchpad/money-test.mjs` covers all of it, including that switching
    project switches the money with it.
  - **The client file is the person across their jobs, and that is the whole
    reason it survives.** A project can tell you everything about one job; only
    the file can put a couple's wedding and their anniversary party side by
    side. So it lost the things a project owns and gained the things only it
    can show: `projectsForLead()` returns every primary event of theirs,
    upcoming first and finished last, drawn with `projCard()` — the same card
    the board uses, so one card means one thing everywhere. The single "The
    Weekend / Event" card is gone; the weekend is inside its project now.
  - **Money and paperwork on the file are across all their projects**, not just
    the next one: `blockIds` is built from every project's block, so the
    Documents stat counts the contract from the job two years ago. The stat row
    is Collected / Outstanding / Projects / Documents.
  - **Bookings belong to the job, not the person.** The Vendor Team section is
    off the client file, and the project's own vendor section no longer links
    back to the file to "manage" them — that arrow pointed the wrong way once
    projects owned their work.
  - **The band's subtitle stops lying when there are two.** One project and it
    reads the date and venue; more than one and it reads "N projects · next
    <date>", because a single date on a returning client's file is wrong.
  - `openEventModal(existing,parentId,seedLeadId)` — the third way in. "New
    project for them" on the file opens the form already pointed at that
    client, and the event type follows their type.
  - `scratchpad/client-file-test.mjs` covers it at 1400 and 390.
- **The app is project-first now, and that is an information architecture, not
  a screen.** It used to open on a studio-wide dashboard with nineteen tools
  that each acted on whichever event happened to be current — a filing cabinet
  with all the drawers open. The front door is a board of projects; opening one
  makes the whole app about it.
  - **`projects` is the new view and the default landing.** `viewProjects()` is
    `viewStudio(projectBoard())` — the old dashboard body, renamed, with the
    card stack of upcoming events replaced by the projects themselves and a
    one-line band of what is overdue or waiting above them.
  - **`dashboard` means "this project"** and renders `viewEventDetail()` of the
    active event, so there is one page for a project rather than two competing
    ones. `pageHead('dashboard')` says which project and how long there is.
  - **`.app.at-home` hides the project tools** at the front door, because a
    tool that acts on a project you are not in is a trap. Set in `setView()`,
    the only place a view changes.
  - **The nav switcher is the switcher.** Pressing the "working on" card lists
    the other projects; picking one **keeps you on the same screen** —
    comparing the same thing across two jobs is the whole point. Detail screens
    that name a record (a board, an invoice) fall back to that project's
    dashboard, since the record belonged to the project you left.
  - **The phone tabs are Projects · Dashboard · Clients · Calendar · More.**
  - **Everything still routes through `state.activeEventId`** — the earlier fix
    that made opening an event set it is what let this be a small change rather
    than a rewrite.
  - **`viewEvents()` is gone**; the guided tour and every "all events" link
    point at the board. `scratchpad/projects-test.mjs` covers the front door,
    the card facts, the ordering, the nav at home versus inside, Dashboard
    meaning this project, the switcher keeping your place, and the way out.
- **Two dozen hand-picked creams and pinks were what stopped the theme being a
  theme.** The tint ramp was derived from the start, but `--sunk`, the
  sidebar's own gradient, every hover wash, the calendar's "today" and all four
  shadow colours were literals — so a studio on sage still had a pink sidebar,
  a pink calendar and pink shadows. They are four tokens now, all derived:
  - `--accent-wash` / `--accent-wash-2` — a breath of the accent, for anything
    the app is drawing the eye to (hovers, "today", the drop target).
  - `--tint-wash` / `--tint-wash-2` — a breath of the tint, for quiet grounds.
  - `--panel` — the sidebar's ground, three steps warmer than the tint by the
    same hue offsets the page wash uses, so the default lands exactly where the
    three creams it replaced did.
  - `--accent-rgb`, `--accent-deep-rgb`, `--shade-1` (ink), `--shade-2` (a dark
    step of the tint) are **bare channels**, because a colour used inside
    `rgba()` cannot be a token that already carries its own alpha. Shadows and
    focus rings read those.
  - **Status colours stay put on purpose** — the ambers, greens and reds of
    Paid, Overdue, Attending and Declined mean something, and a studio that
    rebrands should not get a green "overdue".
  - **The numbers are anchored on the originals**, so champagne reproduces the
    old palette to within a hue degree; `scratchpad/theme-test.mjs` switches to
    Basalt & Steel and asserts that *no* surface token stayed where it was, then
    switches back and checks champagne returns.
- **The palettes were all one house style.** Six soft, pink-adjacent sets is not
  a choice. There are twelve now in two labelled groups — Soft as it was, and
  Deep: Forest & Brass, Navy & Camel, Graphite & Copper, Oxblood & Stone,
  Basalt & Steel, Tobacco & Linen — and the note under them says what each of
  the three pickers actually governs, since any preset is only a starting
  point.
- **The phone bar floated up the screen while scrolling, and it was three
  things at once.** A fixed element the browser declines to composite gets
  repainted with the page instead of pinned to the viewport — so scrolling down
  carried the tab bar into the middle of the screen with content above and
  below it. iOS gives up when the page is expensive, and this one was asking
  three ways: a full-viewport `mix-blend-mode:multiply` layer (the paper
  grain), a `background-attachment:fixed` ground, and a backdrop-filtered bar
  reading through both of them every frame. Each is free on a desktop.
  - The bar now asks for its own layer everywhere (`transform:translateZ(0)`).
  - A **Safari-only** block — `@supports (-webkit-touch-callout:none)`, which
    is WebKit and nothing else (verified: Chromium answers false) — releases
    the fixed ground, takes the grain out of its blending group, and drops the
    bar's backdrop blur. The look survives; only the way it is drawn changes.
  - **There is no WebKit in this container** (`/opt/pw-browsers` has Chromium
    only), so the fix cannot be reproduced here. `scratchpad/tabbar-test.mjs`
    guards what can be checked — fixed, promoted, still on the bottom edge
    after a scroll — plus the presence of the Safari block in the built file.
    The confirmation has to come from an actual phone.
  - If it ever comes back, the heavier fix is app-shell scrolling: the document
    stops scrolling and an inner element does, so nothing is fixed at all.
- **The board is arranged by dragging, and the arrangement is one order.**
  Three arrays make three kinds of tile, but a board is one composition — a
  colour belongs between two photographs if that is where it was dragged. Every
  item carries `pos` and the wall is `wallTiles(b)`, the merge of the three
  sorted by it; `wallCommit(b,list)` writes 0..n-1 back and sorts each array to
  match, so `b.images` in sequence always agrees with the screen.
  - **Items from before this have no `pos`** and fall back to photos, then
    colours, then notes — the order they were already shown in, so nothing
    moves the first time an old board is opened.
  - **Pointer events, not HTML5 drag-and-drop.** The native one cannot show the
    board moving out of the way, drags a ghost of the whole tile including its
    buttons, and differs in every browser.
  - **A clone follows the pointer; the real tile is the placeholder.** It is
    moved between its neighbours as the pointer passes their centres, so the
    live preview IS the DOM and what you see is what you will get. Only the
    release writes anything down.
  - **Deliberately desktop-only** (`(pointer:coarse)` bails out). On a touch
    screen a drag beginning on a tile is indistinguishable from a scroll until
    it is too late to give the scroll back, and this is a tall page. Touch gets
    the ‹ › arrows, which every tile carries and which do the same thing.
  - **`tileSpan()` asks "has anybody set a size on this board", not "is
    anything wide".** Asking the second question meant narrowing the only wide
    picture handed the board back to the "first picture is the feature"
    default, which promptly made it wide again.
  - **Migration 26** gives notes the `sort_order` photos and colours already
    had, and photos a `span` (1 or 2, checked). The push writes a position
    unique across the whole board once anything has been arranged; the pull
    uses that to tell an arranged board from an old one — **if every
    `sort_order` on the board is distinct they are wall positions, and if any
    collide they are the old per-list indexes**. Verified against local
    Postgres, including the span check refusing 40.
  - **`sbBoardCols()` probes once for both columns**, because one migration
    adds both.
- **The mood board is one wall now, not three cards about one.** It used to be
  a form: reference photos in a uniform grid with every one cropped to the same
  118px band, the palette in a sidebar card and the notes in another. Nobody
  pins a board that way, and it is the screen a studio actually shows a client.
  - **Photos keep their own proportions** — `img{width:100%;height:auto}` in a
    CSS-grid masonry, with `grid-auto-rows:8px` and a row span per tile
    measured by `layoutWall()`.
  - **`align-self:start` is what makes the measurement honest.** Without it the
    grid stretches each tile to its span and every re-measure grows by a row.
  - **Re-measure on every image load** — pictures arrive at their own pace and
    each one changes the height of the column it lands in — and once on resize
    (a single listener guarded by `window.__gemWallResize`, not one per
    render).
  - **The first photo is the feature** and spans two columns. That is the whole
    of it: "make this the feature" moves it to the front, and the array order
    is already what syncs as `sort_order`. No flag, no column, no migration.
  - **Colours and notes are tiles on the same wall**, and a colour tile carries
    its hex as a button that copies it — the number is what gets read out to a
    florist or a printer.
  - **The hero banner went.** It was the feature photograph again, dimmed,
    under a title the page header already carries — 260px saying nothing the
    board says better. Its CSS went with it.
- **There were two ideas of "which event", and only one of them moved.**
  `state.eventId` is the workspace you have open; `state.activeEventId` is what
  `activeEvent()` returns — and that is what the guest list, the seating chart,
  the design studio, the day-of console and the nav's "working on" card all
  read. Only the event switcher and a couple of links ever wrote it, so opening
  a different event from the Events grid and then tapping Guests showed you the
  previous event's guests. `setView()` now sets both: what you opened is what
  you are working on. `scratchpad/active-event-test.mjs` covers it, and fails
  against the build before the fix — two events, open one, check the card, the
  guest list and the seating chart all followed.
- **The sidebar is three bands, not one long scroll.** The whole panel scrolled
  and the user chip was pinned to the bottom of it with `position:sticky`,
  which meant it floated OVER the tools as they passed underneath — a nav item
  reading through the middle of somebody's name — and on a short list sat
  wherever the list happened to end, with a field of nothing below it. Now
  `.sidebar` is `overflow:hidden` with `.brand` fixed at the top, `.side-scroll`
  (`flex:1 1 auto; min-height:0; overflow-y:auto`) in the middle and
  `.side-foot` fixed at the bottom.
  - **`min-height:0` is what makes it scroll**, not the overflow property: a
    flex item's default `min-height:auto` refuses to shrink below its content.
  - **`.brand{flex:0 0 auto}` or the masthead gets squeezed** — a 104px logo
    came out 72px tall the moment the list below it was long enough to
    compete.
  - **The 104px bottom padding on `.sidebar` went with it.** It only ever
    existed to hold the list clear of the floating chip.
  - **Anything that scrolls the nav must target `.side-scroll` now**, not
    `#sidebar` — `navreach.mjs` was scrolling the wrong element and reported
    eleven tools unreachable.
- **A centred image cannot clear a corner button with `max-width`.** Half the
  clearance is spent on the left, so a wide logo still ran under the drawer's
  ✕. The clearance belongs on the container as `padding-right`, and the
  picture then centres in what is left.
- **A percentage `max-width` inside a shrink-to-fit parent walks itself
  down.** `.mark` had `margin:0 auto` (which turns off `align-items:stretch`
  and makes the box shrink to its content), and the image inside had
  `max-width:calc(100% - 32px)` — each pass trimmed the other until a 104px
  square settled at 72. Keep the container full-width and centre the image
  instead.
- **The click delegate is bound to `#content`, and the sidebar is not inside
  it.** `[data-openevent]` on the nav's "working on" card had looked like a
  button and done nothing since the day it was added. Anything interactive
  outside `#content` must be wired directly — and with property assignment,
  since `paintNavEvent()` runs on every render.
- **A studio's logo is a wordmark, not an avatar.** It was drawn into a 38px
  rounded square with `object-fit:cover`, so "CONCRETE" arrived as "ONCRE" —
  in a 240px-wide row that was otherwise empty apart from a single serif
  letter beside it.
  - **With a logo set, the logo IS the masthead.** `.brand:not(.no-logo)`
    turns the row into a column: the mark becomes a plate across the whole
    sidebar (58px tall, 44 on the phone drawer), the picture is `contain`, and
    `.name` — the short mark — stands down, because printing a wordmark beside
    a wordmark says the same thing twice. Collapsed to the rail it goes back
    to a 38px tile, still contained.
  - **Every other place the logo appears is `contain` too**, and the document
    and portal marks are `height:Npx;width:auto;max-width:…` rather than
    squares — a 3.75:1 wordmark inside a 44px square is a 12px-tall smudge.
  - **The panel's close button lives in that corner.** The plate starts below
    it (46px desktop, 48px phone where the button is a 42px touch target), or
    a logo with no margin of its own runs straight under the ✕.
  - **`openPhotoCrop` grew two options for this**: `aspect:'auto'` takes the
    shape of the file that arrived (clamped to 1–4.5, and generous at the wide
    end because a frame narrower than the file pads the export with white),
    and `contain:true` starts the picture whole instead of filling the frame —
    so pressing Use photo without touching anything keeps what was uploaded.
    `clamp()` centres rather than corner-pins when the picture is smaller than
    the frame, and the export fills white first (JPEG has no alpha, so a
    letterbox would come out black).
  - **`height:100%` does not resolve inside a centred grid item.** Both the
    settings plate and the branding preview had the picture take its height
    from its width and spill out of the box (610×163 inside a 54px plate).
    Fixed pixel `max-height` is what works there.
  - **`scratchpad/logo-test.mjs`** uploads a real 3.75:1 file at 1400 and
    390px and checks the frame shape, the whole-picture start, the stored
    result, `background-size:contain`, the plate width, the retired short mark
    and the ✕ clearance. `crop-cover-test.mjs` proves the 16:9 cover crop
    still fills its frame, since both share `openPhotoCrop`.
- **A person's card is two things, and they must not share a line.** Both the
  wedding-party row and the phone guest card were laid out as one wrapped
  flex row — name, chips and buttons all competing for the same width. The
  result was that an allergy pushed the buttons onto a second line, so rows
  came out 32px and 71px tall alternately with the attire button at a
  different x on every one of them (measured: 303, 103, 263, 166, 175, 264).
  The rule that fixed it: **what is true of a person goes under their name;
  what you do to them lives in a fixed column that nothing else may enter.**
  - **Wedding party row** — `.wp-who` (name + one `.wp-sub` caption carrying
    side, dietary, RSVP-if-not-yes and the garment in words) and `.wp-acts`
    (attire + rehearsal, fixed widths, stacked into a 106px column below
    700px). Rows are then the same height by construction.
  - **The attire button shows the status word only.** "Ordered · UK 10" made
    every button a different width, so the column could not line up. The size
    moved into the caption, where it is more readable anyway, and stays in the
    button's `title`.
  - **Nothing is dashed any more.** Three dashed outline chips stacked up read
    as a page that had not finished loading. Quiet and solid says "nobody has
    said anything yet" without the alarm.
  - **Guest card: four lines, forced.** Zero-height full-width `.g-brk` cells
    (`b1`,`b2`,`b3`) end each line, and every cell has an explicit `order`.
    Without them the cells wrapped wherever they ran out of room — the RSVP
    box sat beside a short name and below a long one, and the family name
    landed in whatever gap was left. The four are: who they are (+ the row
    actions) · where they belong and where they sit · what is true of them, as
    chips · what you came to change, under a hairline.
  - **`flex:1 1 0` on the name, not `1 1 auto`.** With `auto` a long surname
    grew the cell to the full width and pushed the pencil onto its own line,
    so where the buttons sat depended on how long somebody's name was.
  - **Those break cells must be `display:none` by default.** They are only for
    the phone card; left as table cells on a desktop they became empty columns
    the header knew nothing about, walking every heading one place away from
    the values beneath it. (`td.inv-brk,td.g-brk{display:none}`, switched back
    on inside the ≤700px block.)
  - **`.g-acts` is `width:1%;white-space:nowrap` on desktop.** Two 28px buttons
    were being given a fifth of the table's width by the auto layout, which is
    what had the names wrapping three lines deep beside all that space.
  - **The RSVP select carries its own answer** (`data-r`, tinted green for
    attending, red for declined, neutral while awaiting). On two hundred names
    the colour is what you sweep for, and it saves the card a status chip
    repeating the word already in the select.
  - **`scratchpad/card-layout-test.mjs` guards all of this** at 320/360/390 and
    1400px: same x for every button, one width per state, buttons level with
    the name, caption under the name, and the four-line order on the card —
    plus, on desktop, one column heading per cell.
- **A sub-event asks six questions, not nineteen.** A rehearsal dinner needs a
  name, which occasion it is, a date and a start time; its client comes from
  the block (`leadId` is hidden when `parentId` is set) and its type is
  resolved upward by `evType()`. The venue is one select — "Same place —
  `<venue>`" or "Somewhere else" — gating thirteen fields through the
  `elsewhere` showIf.
  - **"Same place" copies, it does not look up.** `onSave` reads `venueSame`
    and, when it is `'yes'`, writes the parent's `venue`, `loc`,
    `venueNotes`, `venueAddress` and `venueContact` onto the child as **fresh
    objects**. Sixty-odd readers of `e.venue` then keep working without
    knowing a parent exists, and editing one venue does not silently edit the
    other. Inheritance at read time was the alternative and was rejected:
    `e.venue` alone has 66 call sites, and one missed reader is a blank venue
    on the day.
  - **The hidden fields are the danger.** A hidden field reads back as empty,
    so the copy branch is not a nicety — without it, choosing "Same place"
    would wipe the venue the sub-event already had. Any future field put
    behind a `showIf` needs the same treatment in `onSave`.
  - **The default is read off the record, never assumed.** A new sub-event
    starts on "same place"; an existing one starts on whatever it actually
    holds, so opening the form never quietly proposes to move an event. Blank
    counts as the same place — that is what an unanswered venue meant.
  - **The option names the place, not the parent.** "Same as Candace &
    Lawrence — Cliffside Estate" ran off the end of the select on a phone;
    the modal header already says which block this belongs to.
- **The active sub-event chip drops its date.** The switcher is context — the
  header directly above it already carries the date of the event you are
  looking at, so repeating it on the chip that says "you are here" was the
  same fact three times in 80px. Every other chip keeps its date, because
  that is the thing you are choosing between.
- **The cover control lives on the banner, not in the content.** It sits in
  `.vb-edit` over the image where the photo it changes actually is; the
  `.vb-cover-row` in the content only appears when there is no cover at all.
  Whose photo is showing is in the button's `title`, not a line of body text.
- **Row actions are blocked on sample records by design.** `sampleBlock()` is a
  capture-phase gate on `.main`: it calls `preventDefault()` and
  `stopPropagation()` before any handler sees the click. A test that clicks
  `[data-edit]` on the sample and finds nothing happened has found the gate,
  not a bug — exercise create buttons instead, or adopt/remove the sample
  first.

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
