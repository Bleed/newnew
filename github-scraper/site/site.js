// newnew.news: the NEWNEW block logo (BlockFont in Newnew/Design/TopFaces.swift), its roll-in,
// the dot-face clock (DotFont in DotMatrix.swift) and the menu.
(() => {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Block face: a 10 × 10 block cut by 0.5-wide slits. Only letters whose cuts are rectangles,
  // so a cut is a hole in an even-odd path. Stretched down by S; slits keep their width.
  const S = 1.48, GAP = 1.2;
  const a = (y, x0, x1) => ['a', y, x0, x1], d = (x, y0, y1) => ['d', x, y0, y1], r = (x0, y0, x1, y1) => ['r', x0, y0, x1, y1];
  const G = {
    B: [a(3.3, 3, 7.5), a(6.7, 3, 7.5)], C: [a(5, 4, 10)], E: [a(3.3, 4, 10), a(6.7, 4, 10)],
    F: [a(3.3, 4, 10), r(4, 6.5, 10, 10)], G: [a(3.5, 4, 10), a(6.5, 4.5, 7.5)], H: [d(5, 0, 3.6), d(5, 6.4, 10)],
    L: [r(4, 0, 10, 6.5)], M: [d(3.3, 4, 10), d(6.7, 4, 10)], N: [d(6, 0, 6), d(4, 4, 10)],
    P: [a(3.3, 3, 7), r(4, 6.7, 10, 10)], S: [a(3.3, 3, 10), a(6.7, 0, 7)], T: [r(0, 3.6, 3.6, 10), r(6.4, 3.6, 10, 10)],
    U: [d(5, 0, 7)], W: [d(3.3, 0, 6), d(6.7, 0, 6)], Z: [a(3.3, 0, 7), a(6.7, 3, 10)],
  };
  const ROLL = Object.keys(G);
  const box = (x, y, w, h) => `M${x} ${y}h${w}v${h}h${-w}Z`;
  function glyph(ch, x0) {
    let p = box(x0, 0, 10, 10 * S);
    for (const c of G[ch]) {
      if (c[0] === 'a') p += box(x0 + c[2], c[1] * S - 0.25, c[3] - c[2], 0.5);
      else if (c[0] === 'd') p += box(x0 + c[1] - 0.25, c[2] * S, 0.5, (c[3] - c[2]) * S);
      else p += box(x0 + c[1], c[2] * S, c[3] - c[1], (c[4] - c[2]) * S);
    }
    return p;
  }
  function logo(el, word) {
    const n = word.length, w = n * 10 + (n - 1) * GAP;
    el.innerHTML = `<svg viewBox="0 0 ${w} ${10 * S}" aria-hidden="true">${[...word].map((_, i) =>
      `<path fill="currentColor" fill-rule="evenodd"/>`).join('')}</svg>`;
    const paths = el.querySelectorAll('path');
    const show = (i, ch) => paths[i].setAttribute('d', glyph(ch, i * (10 + GAP)));
    let timer;
    function play() {
      [...word].forEach((ch, i) => show(i, ch));
      if (reduce) return;
      clearInterval(timer);
      const start = performance.now();
      // Every cell rolls through random letters every 0.06 s; they settle left to right.
      const tick = () => {
        const t = performance.now() - start; let rolling = false;
        [...word].forEach((ch, i) => {
          if (t < 250 + i * 90) { rolling = true; show(i, ROLL[Math.floor(Math.random() * ROLL.length)]); } else show(i, ch);
        });
        if (!rolling) clearInterval(timer);
      };
      tick(); timer = setInterval(tick, 60);
    }
    el.addEventListener('click', play);
    play();
  }
  document.querySelectorAll('[data-logo]').forEach(el => logo(el, el.dataset.logo));

  // Dot-face clock: the reader's own time.
  const D = {
    0: '01110100011001110101110011000101110', 1: '00100011000010000100001000010001110',
    2: '01110100010000100010001000100011111', 3: '11111000100010000010000011000101110',
    4: '00010001100101010010111110001000010', 5: '11111100001111000001000011000101110',
    6: '00110010001000011110100011000101110', 7: '11111000010001000100010000100001000',
    8: '01110100011000101110100011000101110', 9: '01110100011000101111000010001001100',
    ':': '00000011000110000000011000110000000',
  };
  // Arrives like the app's dot face (DotText): cells start 0.025 s apart, left to right, each
  // rolls through random digits every 0.06 s for 4 + 0.4 × index steps, then settles. When the
  // minute turns, only the digits that change roll.
  function clock(el, dateEl) {
    const cols = 5 * 6 + 1, rows = 9;
    el.innerHTML = `<svg viewBox="0 0 ${cols} ${rows}" role="img">${Array.from({ length: rows * cols }, (_, k) =>
      `<circle cx="${k % cols + 0.5}" cy="${Math.floor(k / cols) + 0.5}" r="0.36" fill="currentColor" fill-opacity="0.07"/>`).join('')}</svg>`;
    const svg = el.firstChild, dots = svg.querySelectorAll('circle');
    const cells = [' ', ' ', ' ', ' ', ' '];
    function set(i, ch) {
      if (cells[i] === ch) return; cells[i] = ch;
      for (let cy = 0; cy < 7; cy++) for (let cx = 0; cx < 5; cx++) {
        const on = D[ch]?.[cy * 5 + cx] === '1';
        dots[(cy + 1) * cols + 1 + i * 6 + cx].setAttribute('fill-opacity', on ? '1' : '0.07');
      }
    }
    let timer;
    function show(text, roll) {
      svg.setAttribute('aria-label', text);
      clearInterval(timer);
      const target = [...text];
      const moving = target.map((ch, i) => roll && ch !== cells[i] && ch !== ':');
      if (reduce || !moving.some(Boolean)) { target.forEach((ch, i) => set(i, ch)); return; }
      target.forEach((ch, i) => { if (!moving[i]) set(i, ch); });
      const start = performance.now();
      let order = 0;
      const plan = target.map((_, i) => moving[i] ? { at: (order++) * 25, steps: 4 + 0.4 * i } : null);
      const tick = () => {
        const t = performance.now() - start; let busy = false;
        plan.forEach((p, i) => {
          if (!p || t < p.at) { if (p) busy = true; return; }
          if (t < p.at + p.steps * 60) { busy = true; set(i, String(Math.floor(Math.random() * 10))); }
          else set(i, target[i]);
        });
        if (!busy) clearInterval(timer);
      };
      tick(); timer = setInterval(tick, 60);
    }
    const now = () => { const d = new Date(); return [d, `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`]; };
    function next() {
      const [d, text] = now();
      show(text, true);
      if (dateEl) dateEl.textContent = d.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
      setTimeout(next, 60000 - (d.getSeconds() * 1000 + d.getMilliseconds()) + 50);
    }
    // The first roll waits until the clock is on screen.
    // The colon blinks with the seconds: lit on even, dark on odd (steady with Reduce Motion).
    function blink() {
      const d = new Date();
      if (!reduce) set(2, d.getSeconds() % 2 ? ' ' : ':');
      setTimeout(blink, 1000 - d.getMilliseconds() + 5);
    }
    const seen = new IntersectionObserver(entries => {
      if (!entries.some(e => e.isIntersecting)) return;
      seen.disconnect(); next(); blink();
    }, { threshold: 0.6 });
    const [d0] = now();
    if (dateEl) dateEl.textContent = d0.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
    seen.observe(el);
    el.addEventListener('click', () => { cells.fill(' '); show(now()[1], true); });
  }
  document.querySelectorAll('[data-clock]').forEach(el => clock(el, document.querySelector('[data-date]')));

  // Menu
  const menu = document.querySelector('.menu');
  document.querySelectorAll('[data-menu]').forEach(b => b.addEventListener('click', () => {
    const open = menu.classList.toggle('open');
    document.querySelectorAll('[data-menu]').forEach(x => x.setAttribute('aria-expanded', open));
  }));
  menu?.querySelectorAll('nav a').forEach(l => l.addEventListener('click', () => menu.classList.remove('open')));
  addEventListener('keydown', e => { if (e.key === 'Escape') menu?.classList.remove('open'); });
})();
