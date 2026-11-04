(() => {
  'use strict';

  const $ = (s) => document.querySelector(s);
  const state = {
    accounts: new Map(),
    calls: new Map(),
    editing: null,   // account id being edited, or null when adding
    focus: null,     // call id whose audio is routed to this browser
    muted: false,
    dtmfCall: null,
    log: [],
  };
  let ws = null;
  let pingTimer = null;

  // ---------- tiny DOM helper (text is always set via textContent: no XSS) ----------
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
    toast.timer = setTimeout(() => { t.hidden = true; }, err ? 6000 : 3500);
  }

  // ---------- websocket ----------
  function send(obj) {
    if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
  }

  function connect() {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    ws = new WebSocket(`${proto}://${location.host}/ws`);
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => {
      setConn(true);
      clearInterval(pingTimer);
      pingTimer = setInterval(() => send({ type: 'ping' }), 15000);
      if (state.focus) send({ type: 'focus', call_id: state.focus });
    };
    ws.onclose = () => {
      setConn(false);
      clearInterval(pingTimer);
      setTimeout(connect, 1500);
    };
    ws.onmessage = (ev) => {
      if (typeof ev.data === 'string') onMessage(JSON.parse(ev.data));
      else audio.play(ev.data);
    };
  }

  function setConn(on) {
    const el = $('#conn');
    el.textContent = on ? 'online' : 'offline';
    el.className = 'pill ' + (on ? 'on' : 'off');
  }

  function onMessage(m) {
    switch (m.type) {
      case 'snapshot':
        state.accounts = new Map(m.accounts.map((a) => [a.id, a]));
        state.calls = new Map(m.calls.map((c) => [c.id, c]));
        renderAccounts(); renderCalls();
        break;
      case 'accounts':
        state.accounts = new Map(m.accounts.map((a) => [a.id, a]));
        renderAccounts();
        break;
      case 'account_status': {
        const a = state.accounts.get(m.id);
        if (a) { a.status = m.status; a.status_text = m.status_text; renderAccounts(); }
        break;
      }
      case 'call': onCall(m.call); break;
      case 'log':
        state.log.push(m.entry);
        if (state.log.length > 300) state.log.shift();
        if ($('#logDlg').open) renderLog();
        break;
      case 'saved':
        $('#advDlg').close(); $('#accountDlg').close();
        break;
      case 'files': projectFiles.setList(m.files); break;
      case 'file': projectFiles.show(m.path, m.content); break;
      case 'error': toast(m.message, true); break;
    }
  }

  // ---------- accounts ----------
  function renderAccounts() {
    const list = $('#accountList');
    list.replaceChildren();
    for (const a of state.accounts.values()) {
      const li = h('li', { class: 'account' },
        h('span', { class: 'dot ' + a.status, title: a.status }),
        h('div', {},
          h('div', { class: 'title', text: a.name }),
          h('div', { class: 'sub', text: `${a.username}${a.registrar ? '@' + a.registrar : ''} · UDP ${a.local_port}` }),
          h('div', { class: 'sub', text: a.status_text || '' })),
        h('div', { class: 'acts' },
          a.registrar && a.register ? h('button', { class: 'ghost small', title: 'Register again', text: '↻', 'data-act': 'rereg', 'data-id': a.id }) : null,
          h('button', { class: 'ghost small', title: 'Settings', text: '⚙', 'data-act': 'edit', 'data-id': a.id })));
      list.append(li);
    }
    $('#noAccounts').hidden = state.accounts.size > 0;

    const sel = $('#fromSel');
    const prev = sel.value;
    sel.replaceChildren();
    for (const a of state.accounts.values()) {
      sel.append(h('option', { value: a.id, text: `${a.name} (${a.username})` }));
    }
    if (prev && state.accounts.has(prev)) sel.value = prev;
  }

  $('#accountList').addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    if (b.dataset.act === 'rereg') send({ type: 'reregister', account_id: b.dataset.id });
    if (b.dataset.act === 'edit') openAccount(b.dataset.id);
  });

  const fields = ['name', 'username', 'password', 'registrar', 'display', 'auth', 'domain', 'proxy', 'port', 'adv', 'expires'];

  function openAccount(id) {
    state.editing = id;
    const a = id ? state.accounts.get(id) : null;
    $('#accountTitle').textContent = a ? 'Edit account' : 'Add account';
    $('#btnDelete').hidden = !a;
    const set = (f, v) => { $('#f_' + f).value = v == null ? '' : v; };
    set('name', a?.name); set('username', a?.username); set('password', '');
    $('#f_password').placeholder = a?.has_password ? '•••••• (unchanged)' : '';
    set('registrar', a?.registrar); set('display', a?.display_name); set('auth', a?.auth_user);
    set('domain', a?.domain); set('proxy', a?.outbound_proxy); set('port', a ? a.local_port : '');
    set('adv', a?.advertised_host); set('expires', a ? a.expires : 300);
    $('#f_codec').value = a?.prefer_codec || 'pcmu';
    $('#f_register').checked = a ? a.register : true;
    $('#f_auto').checked = a ? a.auto_answer : false;
    $('#accountDlg').showModal();
    $('#f_name').focus();
  }

  function collectAccount() {
    const v = (f) => $('#f_' + f).value.trim();
    const acc = {
      name: v('name'), username: v('username'), registrar: v('registrar'),
      display_name: v('display'), auth_user: v('auth'), domain: v('domain'),
      outbound_proxy: v('proxy'), local_port: v('port'), advertised_host: v('adv'),
      expires: v('expires'), prefer_codec: $('#f_codec').value,
      register: $('#f_register').checked, auto_answer: $('#f_auto').checked,
    };
    if (state.editing) acc.id = state.editing;
    const pw = $('#f_password').value;
    if (pw !== '') acc.password = pw;
    return acc;
  }

  $('#btnAdd').onclick = () => openAccount(null);
  $('#btnAdvanced').onclick = () => $('#advDlg').showModal();
  $('#btnAdvClose').onclick = () => $('#advDlg').close();
  $('#btnAccCancel').onclick = () => $('#accountDlg').close();
  $('#btnAccSave').onclick = () => {
    if (!$('#f_username').value.trim()) { toast('Username is required', true); return; }
    send({ type: 'save_account', account: collectAccount() });
  };
  $('#btnDelete').onclick = () => {
    if (state.editing && confirm('Delete this account?')) send({ type: 'delete_account', id: state.editing });
  };
  $('#accountForm').addEventListener('submit', (e) => e.preventDefault());

  // ---------- dialer ----------
  const KEYS = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
  for (const pad of [$('#keypad'), $('#dtmfPad')]) {
    for (const k of KEYS) pad.append(h('button', { type: 'button', text: k, 'data-k': k }));
  }
  $('#keypad').addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (b) { $('#target').value += b.dataset.k; $('#target').focus(); }
  });
  $('#btnBack').onclick = () => { const t = $('#target'); t.value = t.value.slice(0, -1); };
  $('#target').addEventListener('keydown', (e) => { if (e.key === 'Enter') placeCall(); });
  $('#btnCall').onclick = placeCall;

  async function placeCall() {
    const account_id = $('#fromSel').value;
    const target = $('#target').value.trim();
    if (!account_id) { toast('Add an account first', true); return; }
    if (!target) { toast('Enter a number or a SIP address', true); return; }
    await audio.start();
    send({ type: 'call', account_id, target });
  }

  // ---------- calls ----------
  const LABELS = {
    calling: 'Calling…', ringing: 'Ringing…', cancelling: 'Cancelling…',
    established: 'Connected', ended: 'Ended',
  };

  function onCall(c) {
    const prev = state.calls.get(c.id);
    state.calls.set(c.id, c);

    if (c.state === 'ended') {
      if (state.focus === c.id) setFocus(null);
      setTimeout(() => { state.calls.delete(c.id); renderCalls(); }, 5000);
    } else if (c.state === 'established' || (c.dir === 'out' && (c.state === 'calling' || c.state === 'ringing'))) {
      if (state.focus !== c.id) setFocus(c.id);
    }
    if (!prev && c.dir === 'in' && c.state === 'ringing') toast('Incoming call: ' + c.remote);
    renderCalls();
  }

  function setFocus(id) {
    state.focus = id;
    send({ type: 'focus', call_id: id });
  }

  function renderCalls() {
    const list = $('#callList');
    list.replaceChildren();
    let ringing = false, active = false;
    for (const c of state.calls.values()) {
      if (c.dir === 'in' && c.state === 'ringing') ringing = true;
      if (c.state !== 'ended') active = true;
      const acc = state.accounts.get(c.account_id);
      let status = LABELS[c.state] || c.state;
      if (c.dir === 'in' && c.state === 'ringing') status = 'Incoming call';
      if (c.state === 'established' && c.connected_at) status = 'Connected · ' + fmtDur(Date.now() - c.connected_at);
      if (c.state === 'ended' && c.reason) status = 'Ended · ' + c.reason;

      const acts = h('div', { class: 'acts' });
      const btn = (cls, text, act) => h('button', { class: cls, text, 'data-act': act, 'data-id': c.id, 'data-acc': c.account_id });
      if (c.dir === 'in' && c.state === 'ringing') {
        acts.append(btn('ok', 'Answer', 'answer'), btn('hang', 'Decline', 'hangup'));
      } else if (c.state !== 'ended') {
        if (c.state === 'established') {
          acts.append(btn(state.muted ? 'active' : 'ghost', state.muted ? 'Unmute' : 'Mute', 'mute'), btn('ghost', 'Keypad', 'dtmf'));
        }
        acts.append(btn('hang', c.state === 'established' ? 'Hang up' : 'Cancel', 'hangup'));
      }

      list.append(h('li', { class: `call ${c.dir} ${c.state}` },
        h('div', { class: 'who', text: c.remote || 'unknown' }),
        h('div', { class: 'meta', text: `${acc ? acc.name : c.account_id} · ${c.dir === 'in' ? 'incoming' : 'outgoing'} · ${status}` }),
        acts));
    }
    $('#noCalls').hidden = state.calls.size > 0;
    ringing ? ringer.start() : ringer.stop();
    if (!active) audio.scheduleStop();
  }

  $('#callList').addEventListener('click', async (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    const { act, id, acc } = b.dataset;
    if (act === 'answer') { await audio.start(); send({ type: 'answer', account_id: acc, call_id: id }); }
    if (act === 'hangup') send({ type: 'hangup', account_id: acc, call_id: id });
    if (act === 'mute') { state.muted = !state.muted; renderCalls(); }
    if (act === 'dtmf') { state.dtmfCall = { id, acc }; $('#dtmfDlg').showModal(); }
  });

  $('#dtmfPad').addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (b && state.dtmfCall) send({ type: 'dtmf', account_id: state.dtmfCall.acc, call_id: state.dtmfCall.id, digit: b.dataset.k });
  });
  $('#btnDtmfClose').onclick = () => $('#dtmfDlg').close();

  function fmtDur(ms) {
    const s = Math.max(0, Math.floor(ms / 1000));
    return String(Math.floor(s / 60)).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0');
  }
  setInterval(() => {
    if ([...state.calls.values()].some((c) => c.state === 'established')) renderCalls();
  }, 1000);

  // ---------- SIP log ----------
  function renderLog() {
    const box = $('#logBox');
    box.replaceChildren();
    for (const e of state.log) {
      const t = new Date(e.ts).toLocaleTimeString();
      const acc = state.accounts.get(e.account);
      box.append(h('div', { class: 'entry' },
        h('div', { class: 'head ' + e.dir, text: `${t}  ${e.dir === 'in' ? '← from' : '→ to'} ${e.remote}  [${acc ? acc.name : e.account}]` }),
        h('pre', { text: e.text })));
    }
    box.scrollTop = box.scrollHeight;
  }
  $('#btnLog').onclick = () => { renderLog(); $('#logDlg').showModal(); };
  $('#btnLogClose').onclick = () => $('#logDlg').close();
  $('#btnLogClear').onclick = () => { state.log = []; renderLog(); };

  // ---------- project files (read only; the server decides what may be shown) ----------
  const projectFiles = {
    current: null,
    setList(list) {
      const ul = $('#fileList');
      ul.replaceChildren();
      let dir = null;
      for (const f of list) {
        const i = f.path.lastIndexOf('/');
        const d = i < 0 ? '' : f.path.slice(0, i);
        if (d !== dir) {
          dir = d;
          ul.append(h('li', { class: 'dir', text: d || '(root)' }));
        }
        const name = i < 0 ? f.path : f.path.slice(i + 1);
        const b = h('button', { type: 'button', class: 'ghost small' + (f.path === this.current ? ' active' : ''), text: name, title: f.path, 'data-path': f.path });
        ul.append(h('li', {}, b));
      }
      if (!list.length) ul.append(h('li', { class: 'dir', text: 'No files available' }));
    },
    show(path, content) {
      this.current = path;
      $('#fileName').textContent = path;
      const pre = $('#fileView');
      pre.textContent = content;
      pre.scrollTop = 0;
      for (const b of $('#fileList').querySelectorAll('button')) b.classList.toggle('active', b.dataset.path === path);
    },
  };
  $('#btnFiles').onclick = () => { $('#filesDlg').showModal(); send({ type: 'list_files' }); };
  $('#btnFilesClose').onclick = () => $('#filesDlg').close();
  $('#fileList').addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (b) send({ type: 'read_file', path: b.dataset.path });
  });

  // ---------- audio: microphone <-> websocket via AudioWorklet ----------
  const audio = {
    ctx: null, node: null, stream: null, starting: null, stopTimer: null,
    start() {
      clearTimeout(this.stopTimer);
      if (this.ctx) {
        if (this.ctx.state === 'suspended') this.ctx.resume();
        return Promise.resolve();
      }
      if (!this.starting) this.starting = this._start().finally(() => { this.starting = null; });
      return this.starting;
    },
    async _start() {
      const ctx = new AudioContext({ latencyHint: 'interactive' });
      this.ctx = ctx;
      try {
        await ctx.audioWorklet.addModule('/audio-worklet.js');
      } catch (e) {
        toast('Audio engine failed to load: ' + e.message, true);
        this.ctx = null; ctx.close();
        return;
      }
      this.node = new AudioWorkletNode(ctx, 'phone-processor', { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1] });
      this.node.port.onmessage = (e) => {
        if (!state.muted && state.focus && ws && ws.readyState === 1) ws.send(e.data);
      };
      this.node.connect(ctx.destination);
      try {
        this.stream = await navigator.mediaDevices.getUserMedia({
          audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
        });
        ctx.createMediaStreamSource(this.stream).connect(this.node);
      } catch (e) {
        toast('Microphone unavailable – you will only hear the other side', true);
      }
    },
    play(buf) {
      if (this.node) this.node.port.postMessage(buf, [buf]);
    },
    scheduleStop() {
      if (!this.ctx || this.stopTimer) return;
      this.stopTimer = setTimeout(() => {
        this.stopTimer = null;
        if (this.stream) this.stream.getTracks().forEach((t) => t.stop());
        if (this.ctx) this.ctx.close();
        this.ctx = this.node = this.stream = null;
      }, 1500);
    },
  };

  // ---------- ringtone (cold two-tone) ----------
  const ringer = {
    ctx: null, timer: null,
    start() {
      if (this.timer) return;
      try { this.ctx = this.ctx || new AudioContext(); } catch (e) { return; }
      const beep = () => {
        if (this.ctx.state === 'suspended') this.ctx.resume();
        const t0 = this.ctx.currentTime;
        [[0, 659], [0.28, 523]].forEach(([off, f]) => {
          const o = this.ctx.createOscillator();
          const g = this.ctx.createGain();
          o.type = 'sine'; o.frequency.value = f;
          g.gain.setValueAtTime(0.0001, t0 + off);
          g.gain.exponentialRampToValueAtTime(0.15, t0 + off + 0.03);
          g.gain.exponentialRampToValueAtTime(0.0001, t0 + off + 0.25);
          o.connect(g); g.connect(this.ctx.destination);
          o.start(t0 + off); o.stop(t0 + off + 0.3);
        });
      };
      beep();
      this.timer = setInterval(beep, 2400);
    },
    stop() { clearInterval(this.timer); this.timer = null; },
  };

  connect();
})();
