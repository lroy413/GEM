# GEM — bug report

19 Aug 2026. Found against `4804c96`, **all six now fixed** on this branch,
on top of the eleven recovered commits described below. Line numbers are
`gem-artifact.html` as it stands after the fixes.

## Migration status

**`16_event_photos.sql` is the latest migration, and it is now run** — 19 Aug
2026, verifying all true.

It was written in a session whose branch — `claude/gem-deployment-handoff-ojdskr`
— was pushed and then never merged or opened as a pull request. Eleven commits
were sitting there: migration 16 and per-event cover photos, dashboard drag to
reorder, `VERIFY.md`, the iOS/Android install fix, a time-range sort fix, and
five sync commits (pull automatically where it cannot lose anything, refuse to
push the sample over a studio, say so when an account has no studio, create the
studio on sign-in). That branch is merged here.

It adds `events.photo_path`. Running it first was the gate on this build: the
events payload carries that key on every row whether or not the event has a
cover, so until the column existed PostgREST would have refused *every* events
push, not only the ones with a photograph. That gate is now clear — the column
exists and nothing writes to it until this build ships.

Migrations 01–15 were already run and remain correct. Nothing beyond 16 is
needed: every
key in every payload `sbPush()` sends was matched against the columns created
across `01`–`16`, and there is no drift left in either direction. Three columns
the schema has and the app never fills — `documents.lead_id`,
`questionnaires.lead_id`, `guests.plus_ones` — are unused rather than broken.

---

## 1 · Every push wiped the invoice → client join · **fixed**

`sbPush()` built the invoice row with

```js
lead_id: has(i.leadId) ? i.leadId : null,
```

and `has()` is `evIds.indexOf(id)>=0` — it answers "is this an **event** id?".
A lead id never is, so `lead_id` went up `null` for every invoice, on every
push, forever. The column has been null in the live database since the first
sync. The line above it, `event_id: has(i.eventId)?i.eventId:null`, is correct
and is plainly where this was copied from.

`normalize()` re-derives the join on the way back in by matching `client_name`
to `leads.names` — which is exactly the name match `leadId` was introduced to
replace. So a round trip usually looked fine, and failed in the two cases the
join exists for: two clients with the same name, where every invoice for both
re-attaches to whichever lead is first; and a client renamed on another device,
where the invoice arrives carrying a name that matches no lead and lands on the
client file of nobody.

Nothing leaked — the portal's `invoices_read` policy keys on `event_id`, not
`lead_id` (`02_rls.sql:206`).

**Fix** (`:10634`) — lead ids get a guard of their own, and the invoice row
uses it:

```js
var leadIds=L.map(function(l){return l.id;});
var hasLead=function(id){ return leadIds.indexOf(id)>=0; };
```

## 2 · `sbMigrateIds()` never rewrote an invoice's `leadId` · **fixed**

`eventId` was fixed on invoices, documents, questionnaires and messages;
`leadId` was fixed on events and on form submissions, and nowhere on invoices.
On the first push from a device still holding `l1`-style ids, every lead is
re-issued a uuid and each invoice kept pointing at the id that no longer
existed. This is trap 1 in `NEXT.md` §2, which names `leadId` first. Bug 1 hid
it — the id was discarded before it could be sent — and fixing 1 alone would
have started sending dangling lead ids for the foreign key to reject.

**Fix** (`:10550`) — one line, beside the others:

```js
(db.invoices||[]).forEach(function(r){ fix(r,'leadId'); });
```

## 3 · A weekend's client file could open on the wrong night · **fixed**

`eventForLead()` took the first event carrying the lead's id, with no
preference for the primary — and sub-events inherit their parent's `leadId`
(the event editor defaults the field to `(e&&e.leadId)||(parent&&parent.leadId)`).
Locally that is creation order, so the primary usually won. After a pull it was
arbitrary: `sbPull()` requests `?select=*` with no `order`, so PostgREST
returns rows in whatever order the table gives them.

When a sub-event won, the client file showed the rehearsal dinner's venue and
location as the client's event, and read its guest count off `ev.guests` —
which for a sub-event is always empty, because the roster lives on the primary
and sub-events use `guest_invites`. The symptom was a client file reading
**"Guests attending 0 of 0"** beside the wrong venue.

**Fix** (`:5164`) — ask for the primary first, and read the roster through the
accessors that know where the answer lives:

```js
return db.events.find(function(e){return e.leadId===lead.id&&!evIsSub(e);})||
       db.events.find(function(e){return e.leadId===lead.id;})|| …
```

`rosterFor(ev)` and `gRsvp(g,ev)` replace the direct `ev.guests` read at
`:3985`, per the rule in `NEXT.md` §2.

## 4 · Dropped reference photos were added twice · **fixed**

`wireBoardDetail()` attaches its dropzone handlers with `addEventListener`, and
five of its own handlers ended with `render(); wireBoardDetail();`. `render()`
already re-wires the current view, so the explicit call was a second pass over
the same freshly-built `#dropzone` — two `drop` listeners, so `addFiles()` ran
twice and each dragged image was imported twice.

It was latent until one of those five actions ran: delete a photo, delete a
swatch, delete an idea, add an idea, add a photo. After any of them, the next
drag-and-drop duplicated. Choosing files through the picker was always safe —
that one is `input.onchange=`, which overwrites.

**Fix** — the trailing wire call is gone from all five, the way `wireSeating()`
already called `render()` alone. The same removal fixes `wireClientDetail()` at
two call sites, where it was doubling the photo's `keydown` listener and
opening the file picker twice on Enter.

## 5 · "Sync automatically" would not stay off · **fixed upstream**

`autoSync` was missing from the object `prefs()` rebuilds, so the toggle held
for the session and was on again after a reload — the `dashOrder` bug, again.
This one was already fixed on the recovered branch (`:6209`); it is listed here
because it was live on `main`.

## 6 · The pipeline board leaked a window listener per render · **fixed**

`wireBoard()` registered a **window** resize handler alongside its element
handlers. Every other listener there dies with the DOM `render()` replaces;
that one survived, holding the detached `.board` and `.board-scroll`.
`wireBoard()` runs on every render of the pipeline view, and the two
stage-change handlers called `render(); wireBoard();` — so a drag between
stages added two more. Move fifteen cards and fifteen dead handlers ran on the
next resize. The same double call duplicated the `wheel` handler, which was
visible immediately: after one drag, a wheel notch scrolled the board twice as
far.

**Fix** (`:3853`) — one listener, registered once at boot, calling whichever
updater is current:

```js
var boardFit=null;
addEventListener('resize',function(){ if(boardFit)boardFit(); });
```

and `boardFit=update;` inside `wireBoard()` in place of the registration. The
two trailing `wireBoard()` calls are gone.

---

## Also done

- **Deleting a lead now clears `invoices[].leadId`.** An invoice matches on
  `leadId` when it has one and falls back to the cached name when it does not
  (`invoicesForLead`), so an invoice left pointing at a deleted client could
  never attach to anyone again. Harmless while bug 1 was discarding the id;
  it belonged in the same change.

## Left alone, deliberately

- **A budget line tagged to a deleted sub-event dangles locally.**
  `deleteRecord('event',…)` clears documents, questionnaires, messages, invites
  and bookings but not `budget[].tagEventId`. The push survives it — the prune
  runs after the upserts, and `tag_event_id` is `on delete set null` — and the
  next pull cleans it up.
- **`org_prefs.templates` and `org_prefs.fields` are always empty.** The push
  sends `p.templates` / `p.fields`, which no longer exist; the whitelist calls
  them `taskTemplates`, `docTemplates` and `customFields`. Nothing is lost —
  all three ride along inside the `prefs` jsonb. The two columns are dead
  weight rather than missing data.

## How these were checked

There is no test suite, so each logic fix was exercised against the real
functions lifted out of the artifact, with a weekend fixture whose sub-event is
listed **first** — the order a pull can hand back:

- `eventForLead()` returns the wedding, not the rehearsal dinner.
- The primary counts 2 of 3 attending; the rehearsal dinner counts 1 of 1
  through `rosterFor()`, where `ev.guests` would have said 0 of 0.
- `hasLead()` keeps a live lead id and refuses a deleted one; `has()` would
  have discarded both.
- `sbMigrateIds()` re-issues the lead's uuid and both the event's and the
  invoice's `leadId` follow it.

Bugs 4 and 6 are DOM-lifecycle changes, verified structurally: `render()`
re-wires each of those views itself, and only the redundant second call was
removed. Both files pass `node --check`, and `index.html` was rebuilt from the
artifact with `python3 build.py` (build `9b54b8cc2450`).
