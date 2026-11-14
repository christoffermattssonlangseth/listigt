import { firebaseConfig } from './config.js';

/* ---------- Grund ---------- */
const STORE_KEY = 'listigt:v1';
const LIST_KEY = 'listigt:listId';
const FB = 'https://www.gstatic.com/firebasejs/13.3.0';

const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
const norm = s => s.trim().toLocaleLowerCase('sv');
const $ = sel => document.querySelector(sel);

function loadLocal() {
  try {
    const d = JSON.parse(localStorage.getItem(STORE_KEY));
    if (d && Array.isArray(d.items)) return { items: d.items, base: d.base || [], eans: d.eans || {} };
  } catch {}
  return { items: [], base: [], eans: {} };
}

const state = { items: [], base: [], eans: {} };
let backend;

/*
 * All ändring sker via commit(ops), där varje op är
 *   { op: 'put', coll: 'items'|'base'|'eans', id, data }  eller  { op: 'del', coll, id }
 * Lokalt läge skriver till localStorage, synkat läge till Firestore.
 */
function commit(ops) {
  if (!ops.length) return;
  Promise.resolve(backend.commit(ops)).catch(e => { console.error(e); toast('Kunde inte spara: ' + e.message); });
}
const put = (coll, { id, ...data }) => ({ op: 'put', coll, id, data });
const del = (coll, id) => ({ op: 'del', coll, id });

function applyOps(target, ops) {
  for (const o of ops) {
    if (o.coll === 'eans') {
      if (o.op === 'del') delete target.eans[o.id]; else target.eans[o.id] = o.data.name;
      continue;
    }
    const arr = target[o.coll].filter(x => x.id !== o.id);
    if (o.op === 'put') arr.push({ id: o.id, ...o.data });
    target[o.coll] = arr;
  }
}

function localBackend() {
  Object.assign(state, loadLocal());
  window.addEventListener('storage', e => {
    if (e.key === STORE_KEY) { Object.assign(state, loadLocal()); render(); }
  });
  return {
    synced: false,
    commit(ops) {
      applyOps(state, ops);
      localStorage.setItem(STORE_KEY, JSON.stringify(state));
      render();
    },
  };
}

async function firestoreBackend(listId, isNew) {
  const { initializeApp } = await import(`${FB}/firebase-app.js`);
  const fs = await import(`${FB}/firebase-firestore.js`);
  const app = initializeApp(firebaseConfig);
  const db = fs.initializeFirestore(app, {
    localCache: fs.persistentLocalCache({ tabManager: fs.persistentMultipleTabManager() }),
  });
  const root = fs.doc(db, 'lists', listId);

  async function write(ops) {
    for (let i = 0; i < ops.length; i += 400) {
      const b = fs.writeBatch(db);
      for (const o of ops.slice(i, i + 400)) {
        const ref = fs.doc(root, o.coll, o.id);
        if (o.op === 'del') b.delete(ref); else b.set(ref, o.data);
      }
      // Väntar inte in serverbekräftelse – Firestore köar skrivningar offline.
      b.commit().catch(e => { console.error(e); toast('Synkfel: ' + e.message); });
    }
  }

  // Ny delad lista: flytta över det som redan fanns lokalt.
  if (isNew) {
    const local = loadLocal();
    await write([
      ...local.items.map(i => put('items', i)),
      ...local.base.map(b => put('base', b)),
      ...Object.entries(local.eans).map(([ean, name]) => put('eans', { id: ean, name })),
    ]);
  }

  for (const coll of ['items', 'base', 'eans']) {
    fs.onSnapshot(fs.collection(root, coll), snap => {
      const docs = snap.docs.map(d => ({ id: d.id, ...d.data() }));
      if (coll === 'eans') state.eans = Object.fromEntries(docs.map(d => [d.id, d.name]));
      else state[coll] = docs;
      render();
    }, e => { console.error(e); toast('Synkfel: ' + e.message); });
  }
  return { synced: true, commit: write };
}

/* ---------- Logik ---------- */
const matches = (item, name, ean) => (ean && item.ean === ean) || norm(item.name) === norm(name);

// Nya rader för basvaror som saknas bland de oavbockade varorna.
function missingBaseOps(items, base) {
  const ops = [];
  base.forEach((b, i) => {
    const onList = items.some(it => !it.checked && (it.baseId === b.id || matches(it, b.name, b.ean)));
    if (!onList) {
      ops.push(put('items', {
        id: uid(), name: b.name, qty: 1, ean: b.ean || null,
        checked: false, baseId: b.id, created: i,
      }));
    }
  });
  return ops;
}

function addItem(name, { ean = null, baseId = null } = {}) {
  name = name.trim();
  if (!name) return;
  const ex = state.items.find(i => matches(i, name, ean));
  if (ex) {
    commit([put('items', {
      ...ex,
      checked: false,
      qty: ex.checked ? ex.qty : ex.qty + 1,
      ean: ex.ean || ean,
    })]);
  } else {
    commit([put('items', { id: uid(), name, qty: 1, ean, checked: false, baseId, created: Date.now() })]);
  }
}

function addBase(name, ean = null) {
  name = name.trim();
  if (!name) return;
  if (state.base.some(b => matches(b, name, ean))) {
    toast(`${name} finns redan bland basvarorna`);
    return;
  }
  const b = { id: uid(), name, ean };
  const extra = missingBaseOps(state.items, [b]);
  commit([put('base', b), ...extra]);
  if (extra.length) toast(`${name} lades även till på inköpslistan`);
}

function newRound() {
  const checked = state.items.filter(i => i.checked);
  const remaining = state.items.filter(i => !i.checked);
  const adds = missingBaseOps(remaining, sortedBase());
  commit([...checked.map(i => del('items', i.id)), ...adds]);
  const n = adds.length;
  toast(n ? `${n} basvar${n === 1 ? 'a' : 'or'} tillagd${n === 1 ? '' : 'a'}` : 'Alla basvaror finns redan på listan');
}

const sortedBase = () => [...state.base].sort((a, b) => a.name.localeCompare(b.name, 'sv'));

/* ---------- Rendering ---------- */
function eanMeta(parent, ean) {
  if (!ean) return;
  const m = document.createElement('span');
  m.className = 'meta';
  m.textContent = ean;
  parent.appendChild(m);
}

function render() {
  const list = $('#list');
  list.innerHTML = '';
  const sorted = [...state.items].sort((a, b) =>
    (a.checked - b.checked) || ((b.created || 0) - (a.created || 0)) || a.name.localeCompare(b.name, 'sv'));
  for (const it of sorted) {
    const li = document.createElement('li');
    li.className = it.checked ? 'checked' : '';
    li.innerHTML = `
      <input type="checkbox" ${it.checked ? 'checked' : ''} aria-label="Bocka av">
      <span class="name"></span>
      <span class="qty">
        <button class="minus" aria-label="Minska">−</button>
        <span>${Number(it.qty) || 1}</span>
        <button class="plus" aria-label="Öka">+</button>
      </span>
      <button class="del" aria-label="Ta bort">✕</button>`;
    const nameEl = li.querySelector('.name');
    nameEl.textContent = it.name;
    if (it.baseId) nameEl.insertAdjacentHTML('beforeend', '<span class="badge">bas</span>');
    eanMeta(nameEl, it.ean);
    li.querySelector('input').onchange = e => commit([put('items', { ...it, checked: e.target.checked })]);
    li.querySelector('.plus').onclick = () => commit([put('items', { ...it, qty: it.qty + 1 })]);
    li.querySelector('.minus').onclick = () => { if (it.qty > 1) commit([put('items', { ...it, qty: it.qty - 1 })]); };
    li.querySelector('.del').onclick = () => commit([del('items', it.id)]);
    list.appendChild(li);
  }
  $('#list-empty').classList.toggle('hidden', state.items.length > 0);
  $('#clear-checked').disabled = !state.items.some(i => i.checked);

  const base = $('#base');
  base.innerHTML = '';
  for (const b of sortedBase()) {
    const li = document.createElement('li');
    li.innerHTML = `<span class="name"></span><button class="del" aria-label="Ta bort basvara">✕</button>`;
    const nameEl = li.querySelector('.name');
    nameEl.textContent = b.name;
    eanMeta(nameEl, b.ean);
    li.querySelector('.del').onclick = () => {
      if (!confirm(`Ta bort ”${b.name}” från basvarorna?`)) return;
      commit([
        del('base', b.id),
        ...state.items.filter(i => i.baseId === b.id).map(i => put('items', { ...i, baseId: null })),
      ]);
    };
    base.appendChild(li);
  }
  $('#base-empty').classList.toggle('hidden', state.base.length > 0);

  const names = new Set([...state.base.map(b => b.name), ...Object.values(state.eans)]);
  $('#suggestions').innerHTML = [...names].map(n => {
    const o = document.createElement('option'); o.value = n; return o.outerHTML;
  }).join('');
}

let toastTimer;
function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), 2500);
}

/* ---------- EAN ---------- */
function validEan(code) {
  if (!/^\d{8}$|^\d{12,14}$/.test(code)) return false;
  const digits = code.split('').map(Number);
  const check = digits.pop();
  const sum = digits.reverse().reduce((s, d, i) => s + d * (i % 2 === 0 ? 3 : 1), 0);
  return (10 - (sum % 10)) % 10 === check;
}

async function lookupEan(ean) {
  if (state.eans[ean]) return state.eans[ean];
  try {
    const r = await fetch(
      `https://world.openfoodfacts.org/api/v2/product/${ean}.json?fields=product_name_sv,product_name,generic_name_sv,brands`);
    if (!r.ok) return null;
    const p = (await r.json()).product;
    const name = p && (p.product_name_sv || p.product_name || p.generic_name_sv);
    if (!name) return null;
    const brand = (p.brands || '').split(',')[0].trim();
    return brand && !norm(name).includes(norm(brand)) ? `${name} (${brand})` : name;
  } catch {
    return null;
  }
}

async function handleEan(ean, target) {
  let name = await lookupEan(ean);
  if (!name) {
    name = prompt(`Okänd vara (${ean}). Vad heter den?`);
    if (!name || !name.trim()) return;
    name = name.trim();
  }
  if (state.eans[ean] !== name) commit([put('eans', { id: ean, name })]);
  if (target === 'base') addBase(name, ean);
  else { addItem(name, { ean }); toast(`${name} tillagd`); }
}

/* ---------- Scanner ---------- */
const scanner = {
  dialog: $('#scanner'),
  video: $('#video'),
  stream: null,
  zxing: null,
  running: false,
  target: 'list',

  async open(target) {
    this.target = target;
    $('#scan-status').textContent = 'Rikta kameran mot streckkoden…';
    $('#manual-ean-input').value = '';
    this.dialog.showModal();
    try {
      if ('BarcodeDetector' in window) await this.startNative();
      else await this.startZxing();
    } catch (e) {
      console.error(e);
      $('#scan-status').textContent = !window.isSecureContext
        ? 'Kameran kräver https. Skriv in koden manuellt.'
        : 'Kunde inte starta kameran. Skriv in koden manuellt.';
    }
  },

  async startNative() {
    const formats = ['ean_13', 'ean_8', 'upc_a', 'upc_e'];
    const supported = await BarcodeDetector.getSupportedFormats();
    if (!formats.some(f => supported.includes(f))) return this.startZxing();
    const detector = new BarcodeDetector({ formats: formats.filter(f => supported.includes(f)) });
    this.stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'environment', width: { ideal: 1280 } }, audio: false });
    this.video.srcObject = this.stream;
    await this.video.play();
    this.running = true;
    const tick = async () => {
      if (!this.running) return;
      try {
        const hit = (await detector.detect(this.video)).map(c => c.rawValue).find(validEan);
        if (hit) return this.found(hit);
      } catch {}
      setTimeout(tick, 150);
    };
    tick();
  },

  async startZxing() {
    if (!window.ZXing) throw new Error('ZXing laddades inte');
    const hints = new Map();
    hints.set(ZXing.DecodeHintType.POSSIBLE_FORMATS, [
      ZXing.BarcodeFormat.EAN_13, ZXing.BarcodeFormat.EAN_8,
      ZXing.BarcodeFormat.UPC_A, ZXing.BarcodeFormat.UPC_E]);
    this.zxing = new ZXing.BrowserMultiFormatReader(hints, 200);
    this.running = true;
    await this.zxing.decodeFromConstraints(
      { video: { facingMode: 'environment' }, audio: false },
      this.video,
      result => {
        if (!this.running || !result) return;
        const code = result.getText();
        if (validEan(code)) this.found(code);
      });
  },

  found(code) {
    if (navigator.vibrate) navigator.vibrate(80);
    const target = this.target;
    this.close();
    handleEan(code, target);
  },

  close() {
    this.running = false;
    if (this.zxing) { this.zxing.reset(); this.zxing = null; }
    if (this.stream) { this.stream.getTracks().forEach(t => t.stop()); this.stream = null; }
    this.video.srcObject = null;
    if (this.dialog.open) this.dialog.close();
  },
};

/* ---------- Delning ---------- */
const shareUrl = id => `${location.origin}${location.pathname}#lista=${id}`;

function openShare() {
  const dlg = $('#share');
  const id = localStorage.getItem(LIST_KEY);
  if (!backend.synced || !id) {
    $('#share-text').textContent =
      'Synkning är inte påslagen än. Fyll i Firebase-inställningarna i config.js (se README.md).';
    $('#share-link').hidden = true;
    $('#share-go').hidden = true;
  } else {
    $('#share-text').textContent =
      'Alla som öppnar länken delar den här listan med dig, och ändringar syns direkt hos alla.';
    $('#share-link').hidden = false;
    $('#share-link').value = shareUrl(id);
    $('#share-go').hidden = false;
  }
  dlg.showModal();
}

$('#share-go').onclick = async () => {
  const url = $('#share-link').value;
  if (navigator.share) {
    try { await navigator.share({ title: 'Vår inköpslista', url }); } catch {}
  } else {
    await navigator.clipboard.writeText(url);
    toast('Länken är kopierad');
  }
};
$('#share-close').onclick = () => $('#share').close();
$('#share-btn').onclick = openShare;

/* ---------- Händelser ---------- */
document.querySelectorAll('.tab').forEach(btn => btn.onclick = () => {
  document.querySelectorAll('.tab').forEach(b => b.classList.toggle('active', b === btn));
  document.querySelectorAll('.view').forEach(v =>
    v.classList.toggle('active', v.id === 'view-' + btn.dataset.view));
});

$('#add-form').onsubmit = e => {
  e.preventDefault();
  const input = $('#add-input');
  const v = input.value.trim();
  if (validEan(v)) handleEan(v, 'list');
  else {
    const b = state.base.find(x => norm(x.name) === norm(v));
    addItem(v, { baseId: b ? b.id : null });
  }
  input.value = '';
  input.focus();
};

$('#base-form').onsubmit = e => {
  e.preventDefault();
  const input = $('#base-input');
  const v = input.value.trim();
  if (validEan(v)) handleEan(v, 'base'); else addBase(v);
  input.value = '';
  input.focus();
};

document.querySelectorAll('.scan-btn').forEach(b => b.onclick = () => scanner.open(b.dataset.target));
$('#scan-close').onclick = () => scanner.close();
$('#scanner').addEventListener('cancel', () => scanner.close());
$('#manual-ean').onsubmit = e => {
  e.preventDefault();
  const v = $('#manual-ean-input').value.trim();
  if (!validEan(v)) { $('#scan-status').textContent = 'Ogiltig EAN-kod'; return; }
  scanner.found(v);
};

$('#clear-checked').onclick = () => commit(state.items.filter(i => i.checked).map(i => del('items', i.id)));
$('#new-round').onclick = newRound;

/* ---------- Start ---------- */
async function start() {
  if (!firebaseConfig) {
    backend = localBackend();
    render();
    return;
  }

  // Inbjudningslänk: #lista=<id>
  const m = location.hash.match(/lista=([A-Za-z0-9]{20,})/);
  let listId = localStorage.getItem(LIST_KEY);
  if (m && m[1] !== listId) {
    if (!listId || confirm('Vill du gå med i den delade listan? Din nuvarande lista ersätts på den här enheten.')) {
      listId = m[1];
      localStorage.setItem(LIST_KEY, listId);
    }
  }
  if (m) history.replaceState(null, '', location.pathname);

  let isNew = false;
  if (!listId) {
    listId = crypto.randomUUID().replace(/-/g, '');
    localStorage.setItem(LIST_KEY, listId);
    isNew = true;
  }

  try {
    backend = await firestoreBackend(listId, isNew);
    $('#share-btn').classList.add('synced');
  } catch (e) {
    console.error(e);
    toast('Kunde inte ansluta till synkningen – sparar lokalt');
    backend = localBackend();
  }
  render();
}

start();

if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
