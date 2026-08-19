# GEM — bug report

19 Aug 2026, against `4804c96` (`main`, live). Everything below was read out of
`gem-artifact.html`; none of it has been changed. Line numbers are that file
unless another is named.

## Migration status

**`15_event_types.sql` is the latest migration, and it is already run.** Nothing
is outstanding — migrations 01–15 cover every column the app writes.

That was checked rather than assumed: every key in every payload `sbPush()`
sends (line 10054 onward, 27 tables) was matched against the columns created
across `supabase/01`–`15`. There is no drift in either direction that would
need a `16`. The two commits since migration 15 — the dashboard rework and
booking a vendor from anywhere — are pure client changes: the dashboard order
lives in `org_prefs.prefs` (jsonb), and creating a vendor while booking writes
an ordinary `vendors` row plus a `vendor_bookings` row.

Three columns the schema has and the app never fills — `documents.lead_id`,
`questionnaires.lead_id`, `guests.plus_ones` — are unused rather than broken.
`invoices.lead_id` is a different matter; see bug 1.

---

## 1 · Every push wipes the invoice → client join

`sbPush()`, line 10094:

```js
lead_id: has(i.leadId) ? i.leadId : null,
```

`has()` is `evIds.indexOf(id)>=0` (line 10000) — it answers "is this an **event**
id?". A lead id never is, so `lead_id` is written as `null` for every invoice,
on every push, forever. The column has been null in the live database since the
first sync.

The line above it, `event_id: has(i.eventId)?i.eventId:null`, is correct and is
plainly where this was copied from. What it needs is a lead-id guard of its own:

```js
var leadIds = L.map(function(l){ return l.id; });
var hasLead = function(id){ return leadIds.indexOf(id) >= 0; };
```

**What it costs.** `normalize()` re-derives the join on the way back in, by
matching `client_name` to `leads.names` (line 2837) — which is exactly the
name match the `leadId` column was introduced to replace (see the comment at
line 2792). So a round trip usually looks fine, and fails in the two cases the
join exists for:

- **Two clients with the same name.** Every invoice for both re-attaches to
  whichever lead is first in the array.
- **A client renamed on another device.** The invoice arrives carrying a
  `client_name` that matches no lead, and lands on the client file of nobody.

Severity: medium. Nothing leaks — the portal's `invoices_read` policy keys on
`event_id`, not `lead_id` (`02_rls.sql:206`) — but a column the app believes is
the join is empty in production.

## 2 · `sbMigrateIds()` never rewrites an invoice's `leadId`

Line 9920:

```js
['invoices','documents','questionnaires','messages'].forEach(function(k){
  (db[k]||[]).forEach(function(r){ fix(r,'eventId'); });
});
```

`eventId` is fixed on all four. `leadId` is fixed on events (9904) and on form
submissions (9923) — and nowhere on invoices. On the first push from a device
that still holds `l1`-style ids, every lead is re-issued a uuid and each
invoice keeps pointing at the id that no longer exists.

This is trap 1 in `NEXT.md` §2, which names `leadId` first in the list of
references that have to be fixed there. Bug 1 hides it: the id is discarded
before it can be sent. Fix 1 without fixing this and the push starts sending
dangling lead ids, which the FK will reject.

One line, next to the others:

```js
(db.invoices||[]).forEach(function(r){ fix(r,'leadId'); });
```

## 3 · A weekend's client file can open on the wrong night

```js
function eventForLead(lead){          // line 4821
  if(!lead)return null;
  return db.events.find(function(e){return e.leadId===lead.id;}) || …
}
```

First match wins, with no preference for the primary — and sub-events inherit
their parent's `leadId` (the event editor defaults the field to
`(e&&e.leadId)||(parent&&parent.leadId)`, line 8591). So for any weekend, this
returns whichever of the four events happens to sit earliest in `db.events`.

Locally that is creation order, so the primary usually wins. **After a pull it
is arbitrary**: `sbPull()` requests `?select=*` with no `order` (line 10193),
so PostgREST returns rows in whatever order the table gives them.

When a sub-event wins, the client file (`viewClientDetail`, and lines 3647,
5403, 5419) shows the rehearsal dinner's venue and location as the client's
event, and reads its guest count off `ev.guests` (line 3700) — which for a
sub-event is always empty, because the roster lives on the primary and
sub-events use `guest_invites`. The symptom is a client file that says
**"Guests attending 0 of 0"** next to the wrong venue.

Fix: ask for the primary first.

```js
return db.events.find(function(e){return e.leadId===lead.id&&!evIsSub(e);}) ||
       db.events.find(function(e){return e.leadId===lead.id;}) || …
```

Line 3700 should also go through `rosterFor(ev)` rather than `ev.guests`, per
the rule in `NEXT.md` §2.

## 4 · Dropped reference photos are added twice

`wireBoardDetail()` attaches the dropzone handlers with `addEventListener`
(lines 5139–5145), and five of its own handlers end with `render();
wireBoardDetail();` (5131, 5151, 5155, 5158, 5163). `render()` already re-wires
the current view (line 3180), so the explicit call is a second pass over the
same freshly-built `#dropzone` — two `drop` listeners, so `addFiles()` runs
twice and each dragged image is imported twice.

It is latent until one of those five actions runs: delete a photo, delete a
swatch, delete an idea, add an idea, or add a photo. After any of them, the
next drag-and-drop duplicates. Choosing files through the picker is safe —
that one is `input.onchange=`, which overwrites.

Exactly the trap in `NEXT.md` §3. Fix: drop the trailing `wireBoardDetail()`
from all five (`render()` does it), the same way `wireSeating()` already calls
`render()` alone.

`wireClientDetail()` has a small version of this: line 5498 re-wires after a
photo change, doubling the `keydown` listener at 5501, so Enter on the client
photo opens the file picker twice.

## 5 · "Sync automatically" will not stay off

The toggle writes and persists it (line 6699) and `sbAuto()` reads it (10298),
but `autoSync` is not in the object `prefs()` rebuilds (5821–5865). Anything
not named there is written to storage and silently dropped on load — the
comment at 5840 says so, having already cost an afternoon over `dashOrder`.

So switching automatic sync off holds for the session and is on again after a
reload. For anyone who turned it off on purpose — a phone on cellular, a
device deliberately kept behind — it comes back without asking.

Fix, in the whitelist:

```js
autoSync: d.autoSync !== false,
```

## 6 · The pipeline board leaks a window listener per render

`wireBoard()` registers a **window** resize handler (line 3614) alongside its
element handlers. Every other listener there dies with the DOM that `render()`
replaces; this one does not — it survives, holding the detached `.board` and
`.board-scroll` nodes.

`wireBoard()` runs on every render of the pipeline view (3164), and the two
stage-change handlers call `render(); wireBoard();` (3591, 3597) — so a drag
between stages adds two more. Move fifteen cards and fifteen dead handlers run
on the next window resize.

The same double call duplicates the `wheel` handler on the (fresh) scroller,
which is visible immediately: after one drag, a wheel notch over the board
scrolls it **twice as far**.

Fix: drop the two trailing `wireBoard()` calls, and hang the resize handling
off a single boot-time listener (or a `ResizeObserver` on the lane) rather than
re-registering per render.

---

## Not bugs, but worth knowing

- **A budget line tagged to a deleted sub-event dangles locally.**
  `deleteRecord('event',…)` clears documents, questionnaires, messages,
  invites and bookings (8915–8938) but not `budget[].tagEventId`. The push
  survives it — the prune runs after the upserts, and `tag_event_id` is
  `on delete set null` — and the next pull cleans it up. Until then the line is
  filed under an event that is gone.
- **Deleting a lead leaves `invoices[].leadId` pointing at it** (8939 clears
  `events[].leadId` only). Harmless today because of bug 1; becomes a dangling
  FK the moment 1 and 2 are fixed. Worth doing in the same change.
- **`org_prefs.templates` and `org_prefs.fields` are always empty.** The push
  sends `p.templates` / `p.fields` (10169), which no longer exist — the
  whitelist calls them `taskTemplates`, `docTemplates` and `customFields`.
  Nothing is lost: all three ride along inside the `prefs` jsonb, so they sync.
  The two columns are dead weight rather than missing data.
