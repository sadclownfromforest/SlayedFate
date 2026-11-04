(() => {
  'use strict';

  const $ = (s) => document.querySelector(s);
  const state = { config: { extensions: [], routes: [], settings: {}, sip_port: 5060, sip_host: '' }, regs: [], calls: [], cdr: [] };
  let ws = null;
  let pingTimer = null;
  let pending = null; // dialog waiting for the server to confirm a save

  // Text is always set through textContent (never innerHTML): no XSS from names or numbers.
  function h(tag, props = {}, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k === 'title') el.title = v;
      else el[k] = v;
    }
    for (const kid of kids) if (kid) el.append(kid);
    return el;
  }

  function toast(msg, err = false) {
    const t = $('#toast');
    t.textContent = msg;
    t.className = 'toast' + (err ? ' err' : '');
    t.hidden = false;
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { t.hidden = true; }, err ? 7000 : 3000);
  }

  function send(obj) {
    if (ws && ws.readyState === 1) { ws.send(JSON.stringify(obj)); return true; }
    toast('Not connected to the server', true);
    return false;
  }

  function connect() {
    ws = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`);
    ws.onopen = () => {
      setConn(true);
      clearInterval(pingTimer);
      pingTimer = setInterval(() => { if (ws.readyState === 1) ws.send('{"type":"ping"}'); }, 15000);
    };
    ws.onclose = () => { setConn(false); clearInterval(pingTimer); setTimeout(connect, 1500); };
    ws.onmessage = (e) => { try { onMessage(JSON.parse(e.data)); } catch (err) { /* ignore garbage */ } };
  }

  function setConn(on) {
    const c = $('#conn');
    c.textContent = on ? 'online' : 'offline';
    c.className = 'pill ' + (on ? 'on' : 'off');
  }

  function onMessage(m) {
    switch (m.type) {
      case 'hello':
        for (const k of Object.keys(m.data)) state[k === 'config' ? 'config' : k] = m.data[k];
        renderAll();
        break;
      case 'data':
        state[m.what] = m.data;
        render(m.what);
        break;
      case 'ok':
        toast(m.message);
        if (pending) { pending.close(); pending = null; }
        break;
      case 'error':
        toast(m.message, true);
        break;
      default:
    }
  }

  // ---------- rendering ----------
  function renderAll() { for (const a of ['config', 'regs', 'calls', 'cdr']) render(a); }

  function render(what) {
    if (what === 'config') { renderTop(); renderExts(); renderRoutes(); }
    if (what === 'regs') renderExts();
    if (what === 'calls') renderCalls();
    if (what === 'cdr') renderCdr();
  }

  function renderTop() {
    const c = state.config;
    $('#sipaddr').textContent = `SIP ${c.settings.public_host || c.sip_host || ''}:${c.sip_port}`;
  }

  function fwdTags(e) {
    const out = [];
    if (e.forward_always) out.push('always → ' + e.forward_always);
    if (e.forward_busy) out.push('busy → ' + e.forward_busy);
    if (e.forward_noanswer) out.push('no answer → ' + e.forward_noanswer);
    if (e.forward_unreachable) out.push('offline → ' + e.forward_unreachable);
    return out;
  }

  function renderExts() {
    const ul = $('#extList');
    ul.replaceChildren();
    const regs = new Map(state.regs.map((r) => [r.number, r]));
    if (!state.config.extensions.length) ul.append(h('li', { class: 'muted', text: 'No phones yet. Add one.' }));
    for (const e of state.config.extensions) {
      const r = regs.get(e.number);
      const sub = r ? `${r.ip}:${r.port}${r.ua ? ' · ' + r.ua : ''}` : 'not registered';
      const body = h('div', { class: 'grow' },
        h('div', { class: 'title', text: e.name ? `${e.number}  ${e.name}` : e.number }),
        h('div', { class: 'sub', text: sub }));
      for (const t of fwdTags(e)) body.append(h('div', { class: 'sub', text: t }));
      const acts = h('div', { class: 'acts' });
      if (r) acts.append(h('button', { class: 'ghost small', text: 'Kick', title: 'Forget the registration (the phone registers again by itself)', onclick: () => send({ type: 'unregister', number: e.number }) }));
      acts.append(h('button', { class: 'ghost small', text: 'Edit', onclick: () => openExt(e) }));
      ul.append(h('li', { class: 'account' }, h('span', { class: 'dot ' + (r ? 'registered' : 'idle') }), body, acts));
    }
  }

  function renderRoutes() {
    const ul = $('#routeList');
    ul.replaceChildren();
    const rs = state.config.routes;
    $('#noRoutes').hidden = rs.length > 0;
    rs.forEach((r, i) => {
      const acts = h('div', { class: 'acts' },
        h('button', { class: 'ghost small', text: '↑', title: 'Move up', disabled: i === 0, onclick: () => send({ type: 'move_route', id: r.id, dir: 'up' }) }),
        h('button', { class: 'ghost small', text: '↓', title: 'Move down', disabled: i === rs.length - 1, onclick: () => send({ type: 'move_route', id: r.id, dir: 'down' }) }),
        h('button', { class: 'ghost small', text: 'Edit', onclick: () => openRoute(r) }));
      const body = h('div', { class: 'grow' }, h('div', { class: 'title', text: `${r.pattern}  →  ${r.target}` }));
      if (r.note) body.append(h('div', { class: 'sub', text: r.note }));
      ul.append(h('li', { class: 'account' + (r.enabled === false ? ' disabled' : '') }, h('span', { class: 'dot ' + (r.enabled === false ? 'idle' : 'registered') }), body, acts));
    });
  }

  function fmtDur(s) {
    s = Math.max(0, Math.round(s));
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  }

  function renderCalls() {
    const ul = $('#callList');
    ul.replaceChildren();
    $('#noCalls').hidden = state.calls.length > 0;
    const now = Date.now();
    for (const c of state.calls) {
      const since = c.answered ? `talking ${fmtDur((now - Date.parse(c.answered)) / 1000)}` : `${c.state} ${fmtDur((now - Date.parse(c.started)) / 1000)}`;
      const who = `${c.caller} → ${c.callee}` + (c.target && c.target !== c.callee ? ` (${c.target})` : '');
      ul.append(h('li', { class: 'call ' + (c.answered ? 'established' : 'in ringing') },
        h('div', { class: 'who', text: who }),
        h('div', { class: 'meta', text: since }),
        h('div', { class: 'acts' }, h('button', { class: 'hang small', text: 'Hang up', onclick: () => send({ type: 'hangup', id: c.id }) }))));
    }
  }

  function renderCdr() {
    const q = $('#cdrFilter').value.trim().toLowerCase();
    const disp = $('#cdrDisp').value;
    const body = $('#cdrBody');
    body.replaceChildren();
    let n = 0;
    for (const r of state.cdr) {
      if (disp && r.disposition !== disp) continue;
      const hay = [r.caller, r.caller_name, r.callee, r.target, r.reason, r.disposition].join(' ').toLowerCase();
      if (q && !hay.includes(q)) continue;
      n++;
      const when = new Date(r.start).toLocaleString();
      const from = r.caller_name ? `${r.caller} (${r.caller_name})` : r.caller;
      const rang = h('td', { text: r.target || '—', title: r.route || '' });
      if (r.route) rang.append(h('span', { class: 'tag', text: 'rerouted' }));
      body.append(h('tr', {},
        h('td', { class: 'num', text: when }),
        h('td', { text: from }),
        h('td', { text: r.callee }),
        rang,
        h('td', {}, h('span', { class: 'badge ' + r.disposition.replace(' ', '-'), text: r.disposition })),
        h('td', { class: 'num', text: r.billsec ? fmtDur(r.billsec) : '—' }),
        h('td', { text: r.reason || '', title: `total ${fmtDur(r.duration)}${r.route ? ' · ' + r.route : ''}` })));
    }
    $('#noCdr').hidden = n > 0;
    $('#cdrTable').hidden = n === 0;
  }

  // ---------- dialogs ----------
  function openDialog(dlg) { pending = null; dlg.showModal(); }

  function openExt(e) {
    const isNew = !e;
    e = e || {};
    $('#extTitle').textContent = isNew ? 'New phone' : `Phone ${e.number}`;
    $('#e_number').value = e.number || '';
    $('#e_number').readOnly = !isNew;
    $('#e_name').value = e.name || '';
    $('#e_password').value = '';
    $('#e_password').placeholder = isNew ? 'at least 4 characters' : 'unchanged';
    $('#e_pwhint').hidden = isNew;
    $('#e_fa').value = e.forward_always || '';
    $('#e_fb').value = e.forward_busy || '';
    $('#e_fn').value = e.forward_noanswer || '';
    $('#e_fu').value = e.forward_unreachable || '';
    $('#e_delete').hidden = isNew;
    openDialog($('#dlgExt'));
    (isNew ? $('#e_number') : $('#e_name')).focus();
  }

  let editingRoute = null;
  function openRoute(r) {
    editingRoute = r ? r.id : null;
    r = r || {};
    $('#routeTitle').textContent = r.id ? 'Edit route' : 'New route';
    $('#r_pattern').value = r.pattern || '';
    $('#r_target').value = r.target || '';
    $('#r_note').value = r.note || '';
    $('#r_enabled').checked = r.enabled !== false;
    $('#r_delete').hidden = !r.id;
    openDialog($('#dlgRoute'));
    $('#r_pattern').focus();
  }

  function openSettings() {
    const s = state.config.settings;
    $('#s_ring').value = s.ring_timeout;
    $('#s_host').value = s.public_host || '';
    $('#s_realm').value = s.realm;
    $('#s_realm').readOnly = state.config.extensions.length > 0;
    $('#s_auth').checked = s.auth_calls !== false;
    openDialog($('#dlgSettings'));
  }

  function wire() {
    $('#btnAddExt').onclick = () => openExt(null);
    $('#btnAddRoute').onclick = () => openRoute(null);
    $('#btnSettings').onclick = openSettings;
    $('#e_cancel').onclick = () => $('#dlgExt').close();
    $('#r_cancel').onclick = () => $('#dlgRoute').close();
    $('#s_cancel').onclick = () => $('#dlgSettings').close();

    $('#extForm').onsubmit = (ev) => {
      ev.preventDefault();
      pending = $('#dlgExt');
      send({
        type: 'save_extension',
        ext: {
          number: $('#e_number').value.trim(), name: $('#e_name').value, password: $('#e_password').value,
          forward_always: $('#e_fa').value, forward_busy: $('#e_fb').value,
          forward_noanswer: $('#e_fn').value, forward_unreachable: $('#e_fu').value,
        },
      });
    };
    $('#e_delete').onclick = () => {
      const n = $('#e_number').value;
      if (!confirm(`Delete phone ${n}?`)) return;
      pending = $('#dlgExt');
      send({ type: 'delete_extension', number: n });
    };

    $('#routeForm').onsubmit = (ev) => {
      ev.preventDefault();
      pending = $('#dlgRoute');
      send({
        type: 'save_route',
        route: { id: editingRoute || '', pattern: $('#r_pattern').value, target: $('#r_target').value, note: $('#r_note').value, enabled: $('#r_enabled').checked },
      });
    };
    $('#r_delete').onclick = () => {
      if (!confirm('Delete this route?')) return;
      pending = $('#dlgRoute');
      send({ type: 'delete_route', id: editingRoute });
    };

    $('#setForm').onsubmit = (ev) => {
      ev.preventDefault();
      pending = $('#dlgSettings');
      send({
        type: 'save_settings',
        settings: { ring_timeout: $('#s_ring').value, public_host: $('#s_host').value, realm: $('#s_realm').value, auth_calls: $('#s_auth').checked },
      });
    };

    $('#btnClear').onclick = () => { if (confirm('Delete the whole call log?')) send({ type: 'clear_cdr' }); };
    $('#cdrFilter').oninput = renderCdr;
    $('#cdrDisp').onchange = renderCdr;
  }

  wire();
  connect();
  setInterval(() => { if (state.calls.length) renderCalls(); }, 1000);
})();
