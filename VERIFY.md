# GEM — verification runbook

Everything in this file has been reasoned about and exercised locally, but has
never made a real round trip. It is the list from `NEXT.md` §5, turned into
something you can sit down and run.

Work through it in order — B depends on A having created a weekend, and D
depends on C having proved a couple can sign in at all. Each step says what to
do, what you should see, and **what it means if it doesn't** so a failure points
at a file rather than at a shrug.

Nothing here needs a code change. If a step fails, write down which one and stop
— a later step built on a broken earlier one only tells you it is broken twice.

---

## 0 · Before you start

| | |
|---|---|
| Time | About 90 minutes for A–D |
| You need | Two browsers (or one plus a private window), two email addresses you can read, and the Supabase SQL editor |
| Live build | Settings → Data & storage → **App version**, or `curl -s https://gemevents.app/ \| grep gem-build` |

**Run migration 16 first — before section A, and before this build reaches
production.** `supabase/16_event_photos.sql` adds `events.photo_path` and has
not been run against the live project. Every events row carries that key
whether or not anything has a cover, so until the column exists PostgREST
refuses the whole events push with an unknown-column error — section A would
fail before you ever reached the photographs in B. The migration ends in a
`select` of booleans; all of them should be true.

Two devices means two *different signed-in browsers*, not two tabs. Two tabs
share localStorage and IndexedDB, so they will agree with each other no matter
what the server holds — which is precisely the thing under test.

Throughout: **Settings → Sync** has the `Push` and `Pull` buttons. Push sends
this device up; Pull replaces this device with what is stored. Auto-sync pushes
a few seconds after you stop typing, so if you want a clean observation, turn it
off while you work.

> A push refuses with *"This device has never synced with your studio"* when the
> device holds records the server has not seen. That is `gem_claim_sync` doing
> its job, not a bug — pull first.

---

## A · Invitations to sub-events survive a round trip

`guests` belong to the **primary** event; an invitation to a sub-event is a
separate `guest_invites` row carrying its own rsvp, seat and meal. Nothing has
ever confirmed those rows come back.

### A1 — Build a weekend on device 1

1. Events → open an event → **+ Sub-event**. Add two: a rehearsal dinner the day
   before, and a farewell brunch the day after.
2. Guests → add three guests to the primary, or use ones already there.
3. For guest one, invite them to **both** sub-events. For guest two, the
   rehearsal only. Leave guest three on the main event alone.
4. Give the rehearsal dinner its own table, and seat guest one at it. Give them
   a meal choice there different from their meal on the main event.
5. Set guest one's rsvp to **yes** on the main event and **no** on the brunch.

That last pair is the point of the whole design: the same person, two answers.

### A2 — Push, then pull on device 2

6. Device 1: Settings → Sync → **Push**. Wait for *Saved to Supabase*.
7. Device 2: sign in to the same account → Settings → Sync → **Pull**.

### A3 — What to check

| Check | Should be |
|---|---|
| Both sub-events present, one level deep, attached to the same primary | yes |
| Guest one appears on the rehearsal **and** the brunch | yes |
| Guest one is `yes` on the main event and `no` on the brunch | both, independently |
| Guest one is seated at the rehearsal's table | yes, and the table is the rehearsal's own |
| Guest one's meal differs between the main event and the rehearsal | yes |
| Guest two is on the rehearsal only | yes |
| Guest three is on neither | yes |

**If invitations are missing entirely** — check `guest_invites` in the SQL editor
for `event_id`s that match no event. That is `sbMigrateIds()` having missed one
of an invitation's three foreign keys (`guestId`, `eventId`, `tableId`); it is
`NEXT.md` §2 trap 1, three times over.

**If a sub-event is missing but the primary arrived** — look for a failed insert
on `events_parent_guard`. It is a BEFORE ROW trigger, so a child sent ahead of
its parent is refused on the spot. The payload is sorted primaries-first; if you
see this, that sort is what to look at.

**If the rsvp is the same on every event** — something is reading `g.rsvp`
directly instead of going through `gRsvp`/`gTable`/`gMeal`/`gSet`.

### A4 — Then send it back

8. On device 2, change guest one's brunch rsvp to **yes** and reseat them.
9. Push from device 2, pull on device 1, confirm device 1 agrees.

A round trip that only works in one direction is not a round trip.

---

## B · Photographs and documents

Storage policies were fixed in migration 08 and have never been exercised from
two devices. This is where a mistake would show.

### B1 — On device 1

1. Client file → the photo tile at the top left → upload a photo.
2. Events → the primary → **Add a cover photo**. Use a different picture, so you
   can tell which one you are looking at.
3. Do the same on the rehearsal dinner, so a sub-event has its own.
4. Documents → upload a real PDF against the event.
5. **Push.**

### B2 — On device 2

6. **Pull.** Photos come down after the rows, so give it a moment.

| Check | Should be | If not |
|---|---|---|
| The client's photo is on the client file | yes | `leads.photo_path` is null → the path never went up |
| The primary's cover is on its event page and on the dashboard hero | yes | `events.photo_path` null → migration 16 not run, or the events table was not written |
| The rehearsal's own cover shows on the rehearsal | yes | as above |
| The brunch, with no cover of its own, shows the primary's | yes | `evPhoto()` fallback |
| Opening the document downloads the real file | yes | `documents.body`→`file.path` is null → `docUpload()` never ran |

### B3 — The one that used to fail silently

7. On device 2, add a cover to the **brunch** and change nothing else at all —
   no title, no date, no tasks.
8. Push. Then pull on device 1.

The brunch cover must arrive. A photo is the only kind of change that does not
alter its table's payload until *after* the upload has run, so this is the case
where an unwritten table looks exactly like a photo that never uploaded. If it
does not arrive, check that the events table was written at all in that push —
not just that the object landed in the bucket.

### B4 — Storage keys, from the SQL editor

```sql
select name from storage.objects where bucket_id = 'gem-media' order by name;
```

You should see `<org>/leads/<leadId>` for the client photo and
`<org>/<eventId>/<eventId>` for each event cover. A cover filed under `/leads/`
is wrong and would be invisible to the couple, because the read policy grants
client access on the **second** path segment.

---

## C · A couple signing into the portal

Migration 10 redefined `gem_is_event_client` and `gem_client_can_edit` to reach
through `parent_event_id`. Everything a couple sees across a weekend rests on
those two functions, and neither has met a real client.

> **Read section F first.** There is a known first-visit problem with the portal
> hostname that will affect step C2, and knowing about it in advance saves you
> half an hour deciding whether you have broken something.

Prerequisites, all from `NEXT.md` §4 and all on the studio's side: the
`portal.gemevents.app` custom domain on the Worker, Settings → Branding →
**Portal domain** set to that host, and `https://portal.gemevents.app/**` in
Supabase → Authentication → URL Configuration.

### C1 — Invite

1. Device 1 → the client file → **Client Portal** → **Invite**, with an address
   you can read email at. It should appear in the list as **Invited**.
2. Confirm the row landed:

```sql
select email, source, can_edit, claimed_at from event_client_invites;
```

`source` should be `planner`, `claimed_at` null. An invitation emails nobody —
it grants access to whoever signs in with that address.

### C2 — Sign in as the couple

3. In a browser that has never seen GEM, go to `https://portal.gemevents.app`.
4. Sign in with the invited address.

```sql
select event_id, user_id, can_edit from event_clients;
```

One row should now exist, and the invitation should show `claimed_at` set. That
is `gem_claim_client_invites()`, which matches the address in the caller's own
token — so nobody can claim someone else's invitation.

### C3 — What the couple must see, and must not

The invitation attaches them to the **primary only**. Everything below is
therefore a test of the reach-through.

| Must see | Must **not** see |
|---|---|
| The primary event | Any other client's event |
| The rehearsal dinner and the brunch | Leads and the pipeline |
| Their own tasks (`owner = 'client'`) | The studio's tasks (`owner = 'planner'`) |
| The event covers from section B | Vendor fees, or any vendor booking |
| Their guest list | Invoices they were not sent |

The sub-events are the load-bearing check. If the couple sees the primary but
not the rehearsal dinner, `gem_is_event_client` is not reaching through
`parent_event_id` — confirm migration 10 actually ran, since 02 defines an
earlier version of the same function and re-running 02 afterwards would quietly
put it back.

If the studio's tasks are visible, look at `checklist_items.owner`. Existing
rows default to `planner`, which is the safe direction; a row that came back as
`client` came back wrong.

### C4 — Can they edit?

5. As the couple, change an rsvp on the primary and on a sub-event. Push.
6. On device 1, pull, and confirm both changes arrived.

That exercises `gem_client_can_edit` on both an event they are attached to and
one they reach through.

---

## D · The invitation flow, end to end

Two seats per event: the couple share one, and may add one more themselves.
The cap counts claimed rows **plus** outstanding invitations, so it cannot be
beaten by inviting twice.

1. **The couple invites their partner.** `gem_invite_partner` exists and is
   wrapped in the app as `sbInvitePartner()`, but **no UI calls it yet** — see
   section F.

   It also cannot be called from the browser console: the whole artifact runs
   inside an IIFE, so none of its functions are reachable from outside. The
   function checks `auth.uid()` against `event_clients`, so it has to be called
   *as the couple* — running it in the SQL editor raises *"You do not have
   access to that event"*, which is the correct answer to the wrong question.

   Take the couple's token from their own browser (localStorage **is** reachable
   from the console) and call the RPC with it:

   ```js
   // in the couple's signed-in browser, console:
   JSON.parse(localStorage.getItem('gem-sb-session')).access_token
   ```

   ```bash
   curl -sS 'https://dqntxdhzcieycifzjzwc.supabase.co/rest/v1/rpc/gem_invite_partner' \
     -H "apikey: $PUBLISHABLE_KEY" \
     -H "Authorization: Bearer $COUPLE_TOKEN" \
     -H 'Content-Type: application/json' \
     -d '{"p_event":"<primary event id>","p_email":"partner@example.com"}'
   ```

   A new `event_client_invites` row should come back with `source` = `client`.

2. **The third person is refused.** With one claimed seat and one outstanding
   invitation, running that same call for a third address must fail with
   *"You can add one more person, and that seat is already taken."* Repeating it
   for an address already invited must **not** fail — the cap only applies to
   addresses that are not already on the list.

3. **The partner signs in** with their address and lands on the same event.
   `event_clients` should now hold two rows for it. A partner never gets more
   rights than the person who invited them — if the couple has `can_edit` false,
   the partner's row must be false too.

4. **Revoke.** Device 1 → Client Portal → the ✕ beside an address.

```sql
select * from event_client_invites where event_id = '<id>';
select * from event_clients        where event_id = '<id>';
```

Both rows must be gone. Revoking only the invitation would leave someone who has
already signed in with access — `gem_revoke_client` deletes the claimed row too,
and this is the step that proves it.

5. **The revoked person reloads.** They should see nothing. If they still see
   the event, they are being matched by something other than `event_clients`.

---

## E · Quick reference — what each failure points at

| Symptom | Look at |
|---|---|
| Invitations arrive pointing at nothing | `sbMigrateIds()`, the `db.invites` block |
| Sub-event refused on push | `events_parent_guard`; primaries-first sort in `sbPush()` |
| One rsvp for every event | a direct read of `g.rsvp` instead of `gRsvp()` |
| Photo uploads but never appears elsewhere | the table carrying `photo_path` was not written that push |
| Cover filed under `/leads/` | `mediaKey()` — `eventId` not set on the media item |
| Couple sees the primary but not its sub-events | `gem_is_event_client`, migration 10 vs 02 |
| Couple sees the studio's tasks | `checklist_items.owner` |
| Revoked user still has access | `gem_revoke_client` deleting only the invitation |
| Dashboard order resets on reload | the `prefs()` whitelist — `NEXT.md` §3 |

---

## F · Known before you start

Two things found while writing this. Neither is fixed; both will affect what you
see, so they are here rather than in a surprise.

### F1 — A couple's first visit lands on the studio's app

`portalHostMatch()` decides portal-only mode by comparing `location.hostname`
against `prefs().portalHost` — a **local** preference. A couple opening
`portal.gemevents.app` for the first time has an empty localStorage, so
`portalHost` is `''`, the match fails, and they get the planner's dashboard with
the sample wedding in it. The pref only arrives with `org_prefs` on a pull,
which happens after they sign in, and portal-only mode is decided once at boot —
so it takes effect on their **second** load.

The flow does work, in that they can sign in and reload and land in the portal.
It is the first thirty seconds that is wrong, and it is the first thirty seconds
a couple has.

Verified locally: with no stored prefs, `portalHost` reads `""` and
`PORTAL_ONLY` is false; with the pref present and the hostname matching, boot
lands on the portal as intended. So the mechanism is sound and only its
bootstrap is missing. The fix is for the portal host to know it is the portal
without having been told by a previous visit.

Related, and visible in the same thirty seconds: the first-run walkthrough is
gated on `gem-tour-done`, which a couple also does not have, so the studio's
onboarding tour starts up over the top.

### F2 — The couple cannot invite their partner from the UI

`gem_invite_partner` is written, tested by migration 14, and wrapped in the app
as `sbInvitePartner()`. Nothing calls that wrapper. The planner's own Invite
button calls `gem_invite_client`, and the portal's copy tells the couple they
"can add one more person themselves" — but there is no control that does it.

So section D step 1 has no UI path today. Everything under it is still worth
running against the RPC directly, because the seat cap, the claim and the revoke
are all shared with the planner's flow.
