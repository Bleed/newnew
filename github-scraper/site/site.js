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
  function clock(el, dateEl) {
    const draw = () => {
      const now = new Date();
      const text = `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
      const cols = text.length * 6 + 1, rows = 9;
      let dots = '';
      for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
        const gi = Math.floor((x - 1) / 6), cx = (x - 1) % 6, cy = y - 1;
        const on = x > 0 && cx < 5 && cy >= 0 && cy < 7 && D[text[gi]]?.[cy * 5 + cx] === '1';
        dots += `<circle cx="${x + 0.5}" cy="${y + 0.5}" r="0.36" fill="currentColor"${on ? '' : ' fill-opacity="0.07"'}/>`;
      }
      el.innerHTML = `<svg viewBox="0 0 ${cols} ${rows}" role="img" aria-label="${text}">${dots}</svg>`;
      if (dateEl) dateEl.textContent = now.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
      setTimeout(draw, 60000 - (now.getSeconds() * 1000 + now.getMilliseconds()) + 50);
    };
    draw();
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
