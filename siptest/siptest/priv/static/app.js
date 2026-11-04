(() => {
  'use strict';

  const $ = (s) => document.querySelector(s);
  const state = {
    scenarios: [],
    selected: new Set(),
    results: new Map(),   // id -> {id,title,status,steps[],error,ms}
    order: [],
    running: false,
    trace: [],            // {scenario, dir, remote, ts, text}
    summary: null,
    target: '',
    scriptFor: null,      // scenario id shown in the script dialog
  };
  let ws = null;
  let pingTimer = null;

  // ---------- helpers (text is always set through textContent: no XSS) ----------
  function h(tag, props = {}, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k.startsWith('data-')) el.setAttribute(k, v);
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
    toast.timer = setTimeout(() => { t.hidden = true; }, err ? 7000 : 3500);
  }

  const store = {
    get(k, d) { try { const v = localStorage.getItem('siptest.' + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem('siptest.' + k, JSON.stringify(v)); } catch (e) { /* private mode */ } },
  };

  // ---------- settings ----------
  const FIELDS = {
    host: 't_host', port: 't_port', to_user: 't_to',
    from_user: 'a_from', display: 'a_display', domain: 'a_domain', auth_user: 'a_auth_user',
    local_port: 'a_local_port', local_host: 'a_local_host', rtp_port: 'a_rtp',
    timeout: 'a_timeout', ring_timeout: 'a_ring',
  };

  function loadSettings() {
    const saved = store.get('settings', {});
    for (const [k, id] of Object.entries(FIELDS)) if (saved[k] != null) $('#' + id).value = saved[k];
    if (!$('#t_host').value) $('#t_host').value = '127.0.0.1';
  }

  function collectParams() {
    const p = {};
    for (const [k, id] of Object.entries(FIELDS)) p[k] = $('#' + id).value.trim();
    store.set('settings', p);          // the password is deliberately not stored
    p.password = $('#a_password').value;
    return p;
  }

  // ---------- websocket ----------
  function send(obj) {
    if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
    else toast('Not connected to the server', true);
  }

  function connect() {
    ws = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`);
    ws.onopen = () => {
      setConn(true);
      clearInterval(pingTimer);
      pingTimer = setInterval(() => { if (ws.readyState === 1) ws.send('{"type":"ping"}'); }, 15000);
    };
    ws.onclose = () => { setConn(false); clearInterval(pingTimer); setTimeout(connect, 1500); };
    ws.onmessage = (ev) => onMessage(JSON.parse(ev.data));
  }

  function setConn(on) {
    const el = $('#conn');
    el.textContent = on ? 'online' : 'offline';
    el.className = 'pill ' + (on ? 'on' : 'off');
  }

  // ---------- events ----------
  function scriptSteps(text) {
    return text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));
  }

  function onMessage(m) {
    switch (m.type) {
      case 'hello': {
        state.scenarios = m.scenarios;
        const saved = store.get('selected', ['options-ping']);
        state.selected = new Set(saved.filter((id) => m.scenarios.some((s) => s.id === id)));
        setRunning(m.running);
        renderScenarios();
        break;
      }
      case 'run_started': {
        state.results = new Map();
        state.order = m.scenarios.map((s) => s.id);
        state.trace = [];
        state.summary = null;
        state.target = m.target;
        for (const s of m.scenarios) {
          const sc = s.id === 'custom' ? { script: $('#scriptText').value } : state.scenarios.find((x) => x.id === s.id);
          state.results.set(s.id, {
            id: s.id, title: s.title, status: 'pending', error: null, ms: 0,
            steps: scriptSteps(sc ? sc.script : '').map((t) => ({ text: t, status: 'pending', detail: '', ms: 0 })),
          });
        }
        setRunning(true);
        renderResults();
        break;
      }
      case 'scenario_started': { const r = state.results.get(m.id); if (r) { r.status = 'running'; renderResults(); } break; }
      case 'step': {
        const r = state.results.get(m.scenario);
        if (r) {
          r.steps[m.idx] = { text: m.text, status: m.status, detail: m.detail, ms: m.ms };
          renderResults();
        }
        break;
      }
      case 'scenario_done': {
        const r = state.results.get(m.id);
        if (r) { r.status = m.status; r.error = m.error; r.ms = m.ms; renderResults(); }
        break;
      }
      case 'run_done':
        state.summary = m;
        setRunning(false);
        for (const r of state.results.values()) if (r.status === 'pending' || r.status === 'running') r.status = 'skipped';
        renderResults();
        break;
      case 'trace':
        state.trace.push({ scenario: m.scenario, dir: m.dir, remote: m.remote, ts: m.ts, text: m.text });
        if (state.trace.length > 3000) state.trace.shift();
        if ($('#traceDlg').open) renderTrace();
        break;
      case 'error': toast(m.message, true); break;
    }
  }

  function setRunning(on) {
    state.running = on;
    $('#btnRun').disabled = on;
    $('#btnRunAll').disabled = on;
    $('#btnStop').hidden = !on;
    $('#btnScriptRun').disabled = on;
  }

  // ---------- scenarios ----------
  function renderScenarios() {
    const box = $('#scList');
    box.replaceChildren();
    let group = null;
    for (const sc of state.scenarios) {
      if (sc.group !== group) { group = sc.group; box.append(h('div', { class: 'group', text: group })); }
      const cb = h('input', { type: 'checkbox', id: 'cb_' + sc.id, checked: state.selected.has(sc.id), 'data-id': sc.id });
      box.append(h('div', { class: 'sc' },
        cb,
        h('label', { htmlFor: 'cb_' + sc.id },
          h('div', { class: 't', text: sc.title }),
          h('div', { class: 'd', text: sc.description })),
        h('button', { class: 'ghost small', text: 'Script', 'data-script': sc.id })));
    }
  }

  $('#scList').addEventListener('change', (e) => {
    const id = e.target.dataset && e.target.dataset.id;
    if (!id) return;
    e.target.checked ? state.selected.add(id) : state.selected.delete(id);
    store.set('selected', [...state.selected]);
  });
  $('#scList').addEventListener('click', (e) => {
    const b = e.target.closest('button[data-script]');
    if (b) openScript(b.dataset.script);
  });
  $('#btnAll').onclick = () => { state.selected = new Set(state.scenarios.map((s) => s.id)); store.set('selected', [...state.selected]); renderScenarios(); };
  $('#btnNone').onclick = () => { state.selected = new Set(); store.set('selected', []); renderScenarios(); };

  // ---------- run / stop ----------
  function run(ids) {
    if (!ids.length) { toast('Select at least one scenario', true); return; }
    if (!$('#t_host').value.trim()) { toast('Enter the IP address of the phone / server', true); $('#t_host').focus(); return; }
    send({ type: 'run', scenarios: ids, params: collectParams(), custom: '' });
  }
  const catalogOrder = () => state.scenarios.map((s) => s.id);
  $('#btnRun').onclick = () => run(catalogOrder().filter((id) => state.selected.has(id)));
  $('#btnRunAll').onclick = () => run(catalogOrder());
  $('#btnStop').onclick = () => send({ type: 'stop' });

  // ---------- results ----------
  const ICON = { pass: '✓', fail: '✗', running: '▶', pending: '·', skipped: '–' };

  function renderResults() {
    const box = $('#resList');
    box.replaceChildren();
    $('#noRes').hidden = state.results.size > 0;
    let done = 0, failed = 0;
    for (const id of state.order) {
      const r = state.results.get(id);
      if (!r) continue;
      if (r.status === 'pass' || r.status === 'fail') done++;
      if (r.status === 'fail') failed++;
      const steps = h('ol', { class: 'steps' });
      for (const s of r.steps) {
        const li = h('li', { class: s.status },
          h('span', { class: 'ic', text: ICON[s.status] || '·' }),
          h('span', { text: s.text }),
          h('span', { class: 'ms', text: s.ms ? s.ms + ' ms' : '' }));
        if (s.detail) li.append(h('span', { class: 'det', text: s.detail }));
        steps.append(li);
      }
      box.append(h('div', { class: 'res ' + r.status },
        h('div', { class: 'res-head' },
          h('span', { class: 't', text: r.title }),
          h('span', { class: 'badge', text: r.status === 'pass' ? 'PASS' : r.status === 'fail' ? 'FAIL' : r.status }),
          h('span', { class: 'muted', text: r.ms ? (r.ms / 1000).toFixed(1) + ' s' : '' })),
        r.error ? h('div', { class: 'err', text: r.error }) : null,
        steps));
    }
    const total = state.order.length;
    const bar = $('#bar');
    bar.hidden = total === 0;
    bar.classList.toggle('failed', failed > 0);
    $('#barFill').style.width = total ? Math.round((done / total) * 100) + '%' : '0';
    if (state.summary) {
      const s = state.summary;
      $('#summary').textContent = `${s.passed} passed, ${s.failed} failed` + (s.stopped ? ' (stopped)' : '') + ` · ${(s.ms / 1000).toFixed(1)} s` + (state.target ? ' · ' + state.target : '');
    } else {
      $('#summary').textContent = state.running ? `running ${done}/${total}…` : '';
    }
  }

  // ---------- popups ----------
  $('#btnAdv').onclick = () => $('#advDlg').showModal();
  $('#btnAdvClose').onclick = () => { collectParams(); $('#advDlg').close(); };

  function openScript(id) {
    const sc = state.scenarios.find((s) => s.id === id);
    if (!sc) return;
    state.scriptFor = id;
    $('#scriptTitle').textContent = sc.title;
    $('#scriptDesc').textContent = sc.description;
    $('#scriptText').value = sc.script;
    $('#scriptDlg').showModal();
  }
  $('#btnScriptReset').onclick = () => {
    const sc = state.scenarios.find((s) => s.id === state.scriptFor);
    if (sc) $('#scriptText').value = sc.script;
  };
  $('#btnScriptClose').onclick = () => $('#scriptDlg').close();
  $('#btnScriptRun').onclick = () => {
    if (!$('#t_host').value.trim()) { toast('Enter the IP address of the phone / server', true); return; }
    send({ type: 'run', scenarios: [], params: collectParams(), custom: $('#scriptText').value });
    $('#scriptDlg').close();
  };

  function renderTrace() {
    const sel = $('#traceSel');
    const want = sel.value;
    sel.replaceChildren(h('option', { value: '', text: 'All scenarios' }));
    for (const id of state.order) {
      const r = state.results.get(id);
      sel.append(h('option', { value: id, text: r ? r.title : id }));
    }
    sel.value = state.order.includes(want) ? want : '';
    const box = $('#traceBox');
    box.replaceChildren();
    for (const e of state.trace) {
      if (sel.value && e.scenario !== sel.value) continue;
      const r = state.results.get(e.scenario);
      box.append(h('div', { class: 'entry' },
        h('div', { class: 'head ' + e.dir, text: `${new Date(e.ts).toLocaleTimeString()}  ${e.dir === 'in' ? '← from' : '→ to'} ${e.remote}  [${r ? r.title : e.scenario}]` }),
        h('pre', { text: e.text })));
    }
    box.scrollTop = box.scrollHeight;
  }
  $('#btnTrace').onclick = () => { renderTrace(); $('#traceDlg').showModal(); };
  $('#traceSel').onchange = renderTrace;
  $('#btnTraceClose').onclick = () => $('#traceDlg').close();
  $('#btnTraceClear').onclick = () => { state.trace = []; renderTrace(); };

  // ---------- export ----------
  $('#btnExport').onclick = () => {
    if (!state.results.size) { toast('Nothing to export yet', true); return; }
    const params = collectParams();
    delete params.password;
    const doc = {
      exported_at: new Date().toISOString(),
      target: state.target,
      params,
      summary: state.summary,
      results: state.order.map((id) => state.results.get(id)),
      trace: state.trace,
    };
    const a = h('a', { href: URL.createObjectURL(new Blob([JSON.stringify(doc, null, 2)], { type: 'application/json' })), download: 'siptest-report.json' });
    document.body.append(a);
    a.click();
    a.remove();
  };

  loadSettings();
  connect();
})();
