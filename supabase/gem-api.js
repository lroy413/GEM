/* ============================================================
 * GEM · Supabase data layer
 *
 * Drop-in replacement for the prototype's localStorage `db` + `save()`.
 * loadWorkspace() returns the SAME shape the UI already renders, so the
 * view functions need no changes — only the mutation call sites do.
 * See MIGRATION.md for the call-site map.
 *
 * Usage:
 *   <script type="module">
 *     import { gemApi } from './gem-api.js';
 *     await gemApi.signIn(email);          // magic link
 *     const db = await gemApi.loadWorkspace();
 *   </script>
 * ============================================================ */

import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = import.meta.env?.VITE_SUPABASE_URL ?? window.GEM_SUPABASE_URL;
const SUPABASE_ANON_KEY = import.meta.env?.VITE_SUPABASE_ANON_KEY ?? window.GEM_SUPABASE_ANON_KEY;

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
});

/* ---------- row → UI shape ---------- */
const toLead = r => ({
  id: r.id, names: r.names, type: r.event_type, date: r.event_date,
  venue: r.venue, value: Number(r.value), stage: r.stage,
  guests: r.guest_count, email: r.email, phone: r.phone, notes: r.notes
});
const toGuest = r => ({
  id: r.id, name: r.name, party: r.party, side: r.side, rsvp: r.rsvp,
  meal: r.meal || '', diet: r.dietary || '', tableId: r.table_id
});
const toVendor = r => ({
  id: r.id, name: r.name, cat: r.category, contact: r.contact,
  email: r.email, phone: r.phone, status: r.status,
  fee: Number(r.fee), eventId: r.event_id
});
const toInvoice = r => ({
  id: r.id, client: r.client_name, num: r.number, amount: Number(r.amount),
  due: r.due_date, status: r.status, eventId: r.event_id
});

let _orgId = null;
export const orgId = () => _orgId;

export const gemApi = {
  /* ---------- auth ---------- */
  async signIn(email) {
    const { error } = await supabase.auth.signInWithOtp({
      email, options: { emailRedirectTo: window.location.origin }
    });
    if (error) throw error;
    return 'Check your email for the sign-in link.';
  },
  async signOut() { await supabase.auth.signOut(); _orgId = null; },
  async currentUser() {
    const { data } = await supabase.auth.getUser();
    return data.user ?? null;
  },
  onAuthChange(fn) { return supabase.auth.onAuthStateChange((_e, s) => fn(s?.user ?? null)); },

  /* ---------- workspace ---------- */
  async resolveOrg() {
    const { data, error } = await supabase
      .from('org_members').select('org_id, role').limit(1).maybeSingle();
    if (error) throw error;
    _orgId = data?.org_id ?? null;
    return _orgId;
  },
  async createOrg(name) {
    const { data, error } = await supabase.rpc('gem_create_org', { p_name: name });
    if (error) throw error;
    _orgId = data;
    return data;
  },

  /** Returns { leads, events, vendors, invoices } — the prototype's `db`. */
  async loadWorkspace() {
    if (!_orgId) await this.resolveOrg();

    const [leads, events, timeline, checklist, budget, tables, guests, vendors, invoices] =
      await Promise.all([
        supabase.from('leads').select('*').order('event_date'),
        supabase.from('events').select('*').order('event_date'),
        supabase.from('timeline_items').select('*').order('sort_order'),
        supabase.from('checklist_items').select('*').order('sort_order'),
        supabase.from('budget_lines').select('*').order('sort_order'),
        supabase.from('seating_tables').select('*').order('sort_order'),
        supabase.from('guests').select('*').order('name'),
        supabase.from('vendors').select('*').order('name'),
        supabase.from('invoices').select('*').order('due_date')
      ]);

    for (const r of [leads, events, timeline, checklist, budget, tables, guests, vendors, invoices]) {
      if (r.error) throw r.error;
    }

    const byEvent = (rows, map) => id => rows.data.filter(r => r.event_id === id).map(map);

    return {
      leads: leads.data.map(toLead),
      events: events.data.map(e => ({
        id: e.id, leadId: e.lead_id, title: e.title, date: e.event_date,
        venue: e.venue, loc: e.location,
        timeline: byEvent(timeline, t => ({ t: t.at_time, ev: t.title, ds: t.detail }))(e.id),
        checklist: byEvent(checklist, c => ({ id: c.id, lbl: c.label, cat: c.category, done: c.done }))(e.id),
        budget: byEvent(budget, b => ({ cat: b.category, est: Number(b.estimated), act: Number(b.actual) }))(e.id),
        tables: byEvent(tables, t => ({ id: t.id, name: t.name, seats: t.seats }))(e.id),
        guests: byEvent(guests, toGuest)(e.id)
      })),
      vendors: vendors.data.map(toVendor),
      invoices: invoices.data.map(toInvoice)
    };
  },

  /* ---------- leads ---------- */
  async addLead(l) {
    const { data, error } = await supabase.from('leads').insert({
      org_id: _orgId, names: l.names, event_type: l.type, event_date: l.date || null,
      venue: l.venue, value: l.value, stage: 'inquiry', guest_count: l.guests || 0
    }).select().single();
    if (error) throw error;
    return toLead(data);
  },
  async setLeadStage(id, stage) {
    const { error } = await supabase.from('leads').update({ stage }).eq('id', id);
    if (error) throw error;
  },

  /* ---------- guests & seating ---------- */
  async addGuest(eventId, g) {
    const { data, error } = await supabase.from('guests').insert({
      org_id: _orgId, event_id: eventId, name: g.name, party: g.party,
      side: g.side || 'A', rsvp: g.rsvp, meal: g.meal || null, dietary: g.diet || null
    }).select().single();
    if (error) throw error;
    return toGuest(data);
  },
  async setGuestRsvp(id, rsvp) {
    // Declining frees the seat — mirrors the prototype's behavior.
    const patch = rsvp === 'no' ? { rsvp, table_id: null } : { rsvp };
    const { error } = await supabase.from('guests').update(patch).eq('id', id);
    if (error) throw error;
  },
  /** Seat a guest, refusing if the table is already at capacity. */
  async seatGuest(guestId, tableId) {
    if (tableId === null) {
      const { error } = await supabase.from('guests').update({ table_id: null }).eq('id', guestId);
      if (error) throw error;
      return { ok: true };
    }
    const [{ data: table, error: te }, { count, error: ce }] = await Promise.all([
      supabase.from('seating_tables').select('name, seats').eq('id', tableId).single(),
      supabase.from('guests').select('id', { count: 'exact', head: true })
        .eq('table_id', tableId).eq('rsvp', 'yes')
    ]);
    if (te) throw te;
    if (ce) throw ce;
    if (count >= table.seats) return { ok: false, reason: `${table.name} is full — add a seat first.` };
    const { error } = await supabase.from('guests').update({ table_id: tableId }).eq('id', guestId);
    if (error) throw error;
    return { ok: true };
  },
  async addTable(eventId, t) {
    const { data, error } = await supabase.from('seating_tables').insert({
      org_id: _orgId, event_id: eventId, name: t.name, seats: t.seats
    }).select().single();
    if (error) throw error;
    return { id: data.id, name: data.name, seats: data.seats };
  },

  /* ---------- checklist ---------- */
  async toggleChecklist(id, done) {
    const { error } = await supabase.from('checklist_items').update({ done }).eq('id', id);
    if (error) throw error;
  },

  /* ---------- vendors ---------- */
  async addVendor(v) {
    const { data, error } = await supabase.from('vendors').insert({
      org_id: _orgId, event_id: v.eventId, name: v.name, category: v.cat,
      contact: v.contact, email: v.email, phone: v.phone, status: 'quote', fee: v.fee
    }).select().single();
    if (error) throw error;
    return toVendor(data);
  },
  async setVendorStatus(id, status) {
    const { error } = await supabase.from('vendors').update({ status }).eq('id', id);
    if (error) throw error;
  },

  /* ---------- invoices ---------- */
  async addInvoice(inv) {
    const { data, error } = await supabase.from('invoices').insert({
      org_id: _orgId, event_id: inv.eventId || null, number: inv.num,
      client_name: inv.client, amount: inv.amount, due_date: inv.due || null, status: 'draft'
    }).select().single();
    if (error) throw error;
    return toInvoice(data);
  },
  async setInvoiceStatus(id, status) {
    const patch = status === 'paid' ? { status, paid_at: new Date().toISOString() } : { status };
    const { error } = await supabase.from('invoices').update(patch).eq('id', id);
    if (error) throw error;
  },

  /* ---------- realtime: keep desktop + phone in sync ---------- */
  subscribe(onChange) {
    return supabase.channel('gem-workspace')
      .on('postgres_changes', { event: '*', schema: 'public' }, onChange)
      .subscribe();
  }
};
