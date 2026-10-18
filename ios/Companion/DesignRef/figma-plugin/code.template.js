// Sought: sync from app. Figma plugin, run once from the desktop app (Plugins > Development > Import plugin from manifest).
// Additive only: never edits existing frames. Creates
//   1. Variable collection "Sought tokens" (Standard + High contrast modes), with the contrast fixes from the app
//   2. Paint + effect styles "Glass/..." and text styles "Sought/..."
//   3. A section "Built app" on Page 1 with "Home v2" rebuilt as editable layers, plus screenshots of every other screen
// Image hashes and icon node ids come from the existing Home hi-fi and Item Log frames.
// __SCREENS__ is replaced by build.py with {name: base64 jpeg}.

const SCREENS = __SCREENS__;

const hex = (h, a = 1) => {
  const n = parseInt(h.replace('#', ''), 16);
  return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255, a };
};
const solid = (h, a = 1) => { const c = hex(h); return { type: 'SOLID', color: { r: c.r, g: c.g, b: c.b }, opacity: a }; };
const VERTICAL = [[0, 1, 0], [-1, 0, 1]];
const DIAGONAL = [[0.5, 0.5, 0], [-0.5, 0.5, 0.5]];
const gradient = (transform, stops) => ({
  type: 'GRADIENT_LINEAR', gradientTransform: transform,
  gradientStops: stops.map(([position, h, a]) => ({ position, color: hex(h, a) })),
});
const shadow = (y, radius, a) => ({ type: 'DROP_SHADOW', color: { r: 0, g: 0, b: 0, a }, offset: { x: 0, y }, radius, spread: 0, visible: true, blendMode: 'NORMAL' });

// Blur effects gained a blurType field in newer API versions; try the new shape, fall back to the old one.
let BLUR_HAS_TYPE = true;
const blur = (type, radius) => BLUR_HAS_TYPE ? { type, radius, visible: true, blurType: 'NORMAL' } : { type, radius, visible: true };
function probeBlur() {
  const r = figma.createRectangle();
  try { r.effects = [blur('BACKGROUND_BLUR', 10)]; } catch (e) { BLUR_HAS_TYPE = false; }
  r.remove();
}

const fontCache = {};
async function font(family, style) {
  const key = family + '/' + style;
  if (fontCache[key]) return fontCache[key];
  try { await figma.loadFontAsync({ family, style }); fontCache[key] = { family, style }; }
  catch (e) { await figma.loadFontAsync({ family: 'Inter', style: 'Regular' }); fontCache[key] = { family: 'Inter', style: 'Regular' }; }
  return fontCache[key];
}

// ---------- 1. Tokens ----------

const TOKENS = [
  // name, standard, high contrast, note
  ['color/background', '#D6E8EC', '#0F1E24'],
  ['color/background-item-log', '#D9E3ED', '#0F1E24'],
  ['color/band', '#C8DAE4', '#172C34'],
  ['color/surface', '#EEF4F5', '#1C343D'],
  ['color/title', '#3E7C8A', '#D6E8EC', 'was #5B8E98 (2.9:1), now 3.7:1 for 24 pt'],
  ['color/section-title', '#2E4A66', '#EEF4F5'],
  ['color/text', '#24414B', '#EEF4F5', 'status line was #5B8E98 (2.9:1), now 8.6:1'],
  ['color/placeholder', '#434C4E', '#C4D6DB'],
  ['color/primary', '#24414B', '#D6E8EC', 'Find it'],
  ['color/call', '#2F6672', '#9DBDC6', 'Call SoughtBot, was 77% #3E7C8A (2.8:1), now 5:1+'],
  ['color/activity-text', '#0B5F66', '#EEF4F5'],
  ['color/signal', '#22D3EE', '#3CC4D4', 'only while Soughtbot is busy; never text'],
  ['color/searching', '#B7790F', '#F2B84B'],
  ['color/found', '#1F9D6B', '#4FD19A'],
  ['color/alert', '#C8412C', '#FF8A75'],
  ['color/tab-band', '#57A9B2', '#0F1E24'],
];

async function makeTokens() {
  const existing = (await figma.variables.getLocalVariableCollectionsAsync()).find(c => c.name === 'Sought tokens');
  if (existing) return 'kept existing "Sought tokens"';
  const col = figma.variables.createVariableCollection('Sought tokens');
  const std = col.modes[0].modeId;
  col.renameMode(std, 'Standard');
  const hc = col.addMode('High contrast');
  for (const [name, a, b, note] of TOKENS) {
    const v = figma.variables.createVariable(name, col, 'COLOR');
    v.setValueForMode(std, hex(a));
    v.setValueForMode(hc, hex(b));
    if (note) v.description = note;
  }
  return 'created "Sought tokens" (' + TOKENS.length + ' colors, 2 modes)';
}

// ---------- 2. Styles ----------

const GLASS = {
  Search: { tint: '#98C1CD', a: 0.45, edge: 0.75, shadow: [8, 20, 0.08] },
  Activity: { tint: '#96E2EE', a: 0.32, edge: 0.75, shadow: [8, 20, 0.08] },
  Call: { tint: '#2F6672', a: 0.9, edge: 0.35, shadow: [4, 8, 0.15] },
  Pill: { tint: '#FFFFFF', a: 0.28, edge: 0.75, shadow: [8, 20, 0.08] },
  'Tab bar': { tint: '#57A9B2', a: 0.35, edge: 0.75, shadow: [8, 20, 0.08] },
};
const styleIds = {};

async function makeStyles() {
  const paints = await figma.getLocalPaintStylesAsync();
  const effects = await figma.getLocalEffectStylesAsync();
  for (const [name, g] of Object.entries(GLASS)) {
    let ps = paints.find(s => s.name === 'Glass/' + name + ' fill');
    if (!ps) { ps = figma.createPaintStyle(); ps.name = 'Glass/' + name + ' fill'; ps.paints = [solid(g.tint, g.a)]; ps.description = 'Glass tint. Pair with effect style Glass/' + name + '. Edge: 1 px inside, white ' + g.edge + ' to 0.04 diagonal.'; }
    let es = effects.find(s => s.name === 'Glass/' + name);
    if (!es) { es = figma.createEffectStyle(); es.name = 'Glass/' + name; es.effects = [blur('BACKGROUND_BLUR', 24), shadow(...g.shadow)]; }
    styleIds[name] = { fill: ps.id, effect: es.id };
  }
  const texts = await figma.getLocalTextStylesAsync();
  const TEXT = [
    ['Sought/Large title', 'Geist', 'Medium', 28], ['Sought/Screen title', 'Geist', 'Regular', 24],
    ['Sought/Section title', 'Geist', 'Regular', 24], ['Sought/Body', 'Geist', 'Regular', 17],
    ['Sought/Search hero', 'Geist', 'Regular', 17], ['Sought/Status', 'Geist', 'Regular', 12],
    ['Sought/Card title', 'Geist', 'SemiBold', 12], ['Sought/Card meta', 'Geist', 'Light', 12],
    ['Sought/Find it', 'JetBrains Mono', 'Medium', 12], ['Sought/Call button', 'JetBrains Mono', 'Bold', 16],
    ['Sought/Map label', 'JetBrains Mono', 'Bold Italic', 24], ['Sought/Readout', 'JetBrains Mono', 'Bold', 13],
  ];
  for (const [name, fam, style, size] of TEXT) {
    if (texts.find(s => s.name === name)) continue;
    const ts = figma.createTextStyle();
    ts.fontName = await font(fam, style);
    ts.fontSize = size;
    ts.name = name;
  }
}

async function applyGlass(node, name) {
  const g = GLASS[name];
  node.fills = [solid(g.tint, g.a)];
  node.strokes = [gradient(DIAGONAL, [[0, '#FFFFFF', g.edge], [1, '#FFFFFF', 0.04]])];
  node.strokeWeight = 1;
  node.strokeAlign = 'INSIDE';
  node.effects = [blur('BACKGROUND_BLUR', 24), shadow(...g.shadow)];
  try {
    await node.setFillStyleIdAsync(styleIds[name].fill);
    await node.setEffectStyleIdAsync(styleIds[name].effect);
  } catch (e) { /* styles are a convenience; raw values are already set */ }
}

// ---------- 3. Home v2 ----------

const IMG = {
  liveview: 'ac81b4ae27cb006e5d1d61641d7cd7084b4395c9',
  sandals: '98a2302f61e788e95c1cc0ee13fc3e68fdca0416',
  bottle: 'd7c1eba863ed65c3a1c98bf38ad0364f2f04b609',
  chair: '68688935cba0f752214dcc7a3cc75d8874ad63ae',
};
const NODE = {
  mapWidget: '18:920', tabHome: '18:903', tabMap: '18:905', tabItems: '18:907', tabSettings: '18:909',
  eye: '21:976', mic: '18:950', video: '18:948', battery: '18:943', search: '24:1275',
};

async function cloneInto(parent, id, x, y, w, h) {
  const n = await figma.getNodeByIdAsync(id);
  if (!n) return null;
  const c = n.clone();
  parent.appendChild(c);
  c.x = x; c.y = y;
  if (w && h && 'resize' in c) c.resize(w, h);
  return c;
}

function recolor(node, h) {
  const walk = n => {
    if ('fills' in n && Array.isArray(n.fills) && n.fills.length) n.fills = n.fills.map(f => f.type === 'SOLID' ? solid(h) : f);
    if ('strokes' in n && Array.isArray(n.strokes) && n.strokes.length) n.strokes = n.strokes.map(s => s.type === 'SOLID' ? solid(h) : s);
    if ('children' in n) n.children.forEach(walk);
  };
  if (node) walk(node);
}

function rect(parent, x, y, w, h, radius = 0) {
  const r = figma.createRectangle();
  parent.appendChild(r);
  r.x = x; r.y = y; r.resize(w, h); r.cornerRadius = radius;
  return r;
}

function frame(parent, name, x, y, w, h, radius = 0) {
  const f = figma.createFrame();
  parent.appendChild(f);
  f.name = name; f.x = x; f.y = y; f.resize(w, h); f.cornerRadius = radius; f.fills = [];
  return f;
}

async function text(parent, str, fam, style, size, color, x, y, w, opts = {}) {
  const t = figma.createText();
  t.fontName = await font(fam, style);
  t.characters = str;
  t.fontSize = size;
  t.fills = [solid(color)];
  if (opts.lineHeight) t.lineHeight = { value: opts.lineHeight, unit: 'PIXELS' };
  if (opts.tracking) t.letterSpacing = { value: opts.tracking, unit: 'PIXELS' };
  if (opts.align) t.textAlignHorizontal = opts.align;
  parent.appendChild(t);
  if (w) { t.textAutoResize = 'HEIGHT'; t.resize(w, t.height); }
  t.x = x; t.y = y;
  return t;
}

function photo(parent, hash, x, y, w, h, shadeTo = 0.31, radius = 20) {
  const r = rect(parent, x, y, w, h, radius);
  r.fills = [
    { type: 'IMAGE', imageHash: hash, scaleMode: 'FILL' },
    gradient(VERTICAL, [[0, '#0F1E24', 0], [1 - shadeTo, '#39738A', 0.13], [0.98, '#0F1E24', 1]]),
  ];
  r.effects = [shadow(8, 20, 0.08)];
  return r;
}

async function background(f, w, h) {
  f.fills = [gradient(VERTICAL, [[0, '#DFEEF1', 1], [0.5, '#D3E6EB', 1], [1, '#CDE1E7', 1]])];
  const pools = [[w * 0.95, 874 * 0.12, w * 0.9, '#9DBDC6', 0.30, 70], [w * 0.05, 874 * 0.48, w * 0.8, '#96E2EE', 0.45, 80], [w * 0.85, 874 * 0.85, w, '#B4D0D8', 0.45, 90]];
  const group = [];
  for (const [cx, cy, d, c, a, r] of pools) {
    const e = figma.createEllipse();
    f.appendChild(e);
    e.resize(d, d); e.x = cx - d / 2; e.y = cy - d / 2;
    e.fills = [solid(c, a)];
    e.effects = [blur('LAYER_BLUR', r)];
    group.push(e);
  }
  const g = figma.group(group, f);
  g.name = 'Background pools';
  g.locked = true;
}

async function itemCard(parent, x, y, hash, title, meta) {
  const card = frame(parent, 'Item card / ' + title, x, y, 169, 230);
  card.clipsContent = false;
  photo(card, hash, 0, 0, 169, 141);
  await text(card, title, 'Geist', 'SemiBold', 12, '#24414B', 0, 149, 158);
  await text(card, meta, 'Geist', 'Light', 12, '#24414B', 0, 167, 158);
  const pill = frame(card, 'Find it', 0, 189, 158, 22, 11);
  pill.fills = [solid('#24414B')];
  const icon = await cloneInto(pill, NODE.search, 45, 5, 12, 12);
  recolor(icon, '#EEF4F5');
  await text(pill, 'Find it', 'JetBrains Mono', 'Medium', 12, '#EEF4F5', 64, 3);
}

async function homeV2(parent, x, y) {
  const W = 402, H = 1150;
  const f = frame(parent, 'Home v2 (built)', x, y, W, H);
  f.clipsContent = true;
  await background(f, W, H);

  // Badge + status pill
  const badge = frame(f, 'Sample badge', 24, 64, 112, 22, 11);
  badge.fills = [solid('#B7790F')];
  await text(badge, 'SAMPLE DATA', 'JetBrains Mono', 'Bold', 11, '#FAFCFC', 22, 4, null, { tracking: 0.6 });
  const pill = frame(f, 'Status pill', 172, 62, 206, 26, 13);
  await applyGlass(pill, 'Pill');
  const dot = figma.createEllipse(); pill.appendChild(dot); dot.resize(6, 6); dot.x = 12; dot.y = 10; dot.fills = [solid('#22D3EE')];
  await text(pill, 'Soughtbot is roaming · 82%', 'Geist', 'Regular', 12, '#24414B', 24, 5);
  const batt = await cloneInto(pill, NODE.battery, 182, 5);

  // Greeting + hero search
  await text(f, 'Welcome Luca', 'Geist', 'Regular', 24, '#3E7C8A', 24, 100);
  await text(f, 'What are we seeking today?', 'Geist', 'Medium', 28, '#24414B', 24, 136, 354, { lineHeight: 34 });
  const search = frame(f, 'Search (hero, pins on scroll)', 24, 222, 354, 56, 28);
  await applyGlass(search, 'Search');
  recolor(await cloneInto(search, NODE.search, 16, 20, 16, 16), '#24414B');
  await text(search, 'Find my charger', 'Geist', 'Regular', 17, '#434C4E', 40, 17);
  const mic = figma.createEllipse(); search.appendChild(mic); mic.resize(44, 44); mic.x = 304; mic.y = 6; mic.fills = [solid('#98C1CD', 0.26)];
  recolor(await cloneInto(search, NODE.mic, 314, 16), '#24414B');

  // Map widget (cloned from Home hi-fi)
  const mw = await cloneInto(f, NODE.mapWidget, 24, 294);
  if (mw && 'cornerRadius' in mw) { mw.cornerRadius = 26; mw.clipsContent = true; }

  // Card grid: glass Call + glass Activity | tall Live View
  const call = frame(f, 'Call SoughtBot (glass)', 24, 451, 169, 87, 26);
  await applyGlass(call, 'Call');
  recolor(await cloneInto(call, NODE.eye, 12, 25), '#FAFCFC');
  await text(call, 'Call\nSoughtBot', 'JetBrains Mono', 'Bold', 16, '#FAFCFC', 56, 23, 105);
  const act = frame(f, 'Activity log (glass)', 24, 554, 169, 147, 26);
  await applyGlass(act, 'Activity');
  await text(act, 'Activity log', 'Geist', 'SemiBold', 14, '#0B5F66', 16, 16, 137);
  await text(act, 'Slippers moved to front door', 'Geist', 'Regular', 16, '#0B5F66', 16, 41, 137);
  await text(act, '2 hours ago', 'Geist', 'Light', 14, '#0B5F66', 16, 110, 137);
  photo(f, IMG.liveview, 209, 451, 169, 250, 0.48, 26).name = 'Live View';
  await text(f, 'Live View', 'Geist', 'Bold', 20, '#FAFCFC', 217, 664);
  recolor(await cloneInto(f, NODE.video, 317, 666), '#FAFCFC');

  // Recent Finds
  await text(f, 'Recent Finds', 'Geist', 'Regular', 24, '#2E4A66', 24, 725);
  await text(f, 'See all', 'JetBrains Mono', 'Medium', 12, '#24414B', 330, 734);
  await itemCard(f, 24, 768, IMG.sandals, 'Brown Sandals', 'By the front door: 12 min ago');
  await itemCard(f, 209, 768, IMG.bottle, 'Metal Water Bottle', 'Under the table: 13 min ago');
  await itemCard(f, 394, 768, IMG.chair, 'White Chair', 'In the kitchen: 15 min ago');

  // Opaque tab band + glass pill
  const band = rect(f, 0, H - 104, W, 104);
  band.name = 'Tab band (opaque)';
  band.fills = [gradient(VERTICAL, [[0, '#CDE1E7', 1], [0.58, '#57A9B2', 1], [1, '#57A9B2', 1]])];
  const tab = frame(f, 'Tab bar (glass)', 24, H - 92, 354, 58, 29);
  await applyGlass(tab, 'Tab bar');
  const ids = [NODE.tabHome, NODE.tabMap, NODE.tabItems, NODE.tabSettings];
  for (let i = 0; i < 4; i++) {
    const cx = 16 + (322 / 4) * i + 322 / 8;
    if (i === 0) { const sel = figma.createEllipse(); tab.appendChild(sel); sel.resize(40, 40); sel.x = cx - 20; sel.y = 9; sel.fills = [solid('#FAFCFC', 0.22)]; }
    recolor(await cloneInto(tab, ids[i], cx - 14, 15), '#FAFCFC');
    if (i > 0) { const l = rect(tab, 16 + (322 / 4) * i, 15, 1, 28); l.fills = [solid('#FAFCFC')]; }
  }

  // Notes
  await text(parent, 'Home v2: search is the hero and pins to the top as glass while content scrolls under it. ' +
    'Glass = Glass/* fill + effect style + 1 px white diagonal edge. Tab band is opaque so nothing shows through. ' +
    'Corners are continuous: cards 26, photos and rows 20, tiles 16, thumbnails 12, buttons capsules. ' +
    'Live View keeps full height. Frame is the full scroll length; the phone shows the top 874.',
    'Geist', 'Regular', 14, '#24414B', x, y + H + 24, W);
  const fold = rect(f, 0, 874, W, 1); fold.fills = [solid('#C8412C', 0.6)]; fold.name = 'Fold (874)';
  return f;
}

// ---------- 4. Screenshots of the other screens ----------

const SHOTS = [
  ['home_scrolled', 'Home v2, scrolled (search pinned)'], ['items', 'Item Log'], ['detail', 'Item detail'],
  ['map', 'Map'], ['settings', 'Settings'], ['find_confirm', 'Find 1: confirm'], ['find_searching', 'Find 2: searching'],
  ['find_guiding', 'Find 3: guiding'], ['find_found', 'Find 4: found'], ['find_notseen', 'Find: not seen yet'],
  ['map_room', 'Map: room + pin card'], ['map_list', 'Map: item list'], ['home_stuck', 'Home: Soughtbot stuck (amber glow)'],
];

async function screenshots(parent, x, y) {
  let i = 0;
  for (const [key, label] of SHOTS) {
    if (!SCREENS[key]) continue;
    const img = figma.createImage(figma.base64Decode(SCREENS[key]));
    const f = frame(parent, label + ' (screenshot)', x + i * 452, y, 402, 874, 0);
    f.fills = [{ type: 'IMAGE', imageHash: img.hash, scaleMode: 'FILL' }];
    await text(parent, label, 'Geist', 'Medium', 16, '#24414B', x + i * 452, y - 32);
    i++;
  }
}

// ---------- main ----------

async function main() {
  probeBlur();
  await font('Inter', 'Regular');
  const page = await figma.getNodeByIdAsync('3:121');
  if (!page || page.type !== 'PAGE') throw new Error('Could not find "Page 1" (3:121). Is this the Sought / SoughtBot file?');
  await figma.setCurrentPageAsync(page);
  const tokenMsg = await makeTokens();
  await makeStyles();

  const right = page.children.reduce((m, n) => Math.max(m, n.x + n.width), 0) + 300;
  const top = page.children.reduce((m, n) => Math.min(m, n.y), Infinity);
  const section = figma.createSection();
  page.appendChild(section);
  section.name = 'Built app (synced from simulator, Oct 17)';
  section.x = right; section.y = top - 100;

  const title = await text(section, 'Sought, as built', 'Geist', 'Medium', 40, '#24414B', 80, 60);
  await text(section, 'Editable rebuild of the new Home, then simulator screenshots of every other screen (sample data). ' +
    'Original frames on this page are untouched.', 'Geist', 'Regular', 18, '#24414B', 80, 116, 900);
  await homeV2(section, 80, 200);
  await screenshots(section, 80 + 402 + 160, 232);
  const w = 80 + 402 + 160 + SHOTS.length * 452 + 40;
  section.resizeWithoutConstraints(w, 200 + 1150 + 160);

  figma.viewport.scrollAndZoomIntoView([section]);
  figma.closePlugin('Sought: ' + tokenMsg + ', glass + text styles, Home v2 and ' + SHOTS.length + ' screenshots added.');
}

main().catch(e => { figma.notify('Sought plugin error: ' + e.message, { error: true, timeout: 10000 }); figma.closePlugin('Error: ' + e.message); });
