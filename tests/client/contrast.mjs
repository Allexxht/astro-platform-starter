// Kontraszt-mérés a böngészőben (WCAG 2.x relatív fénysűrűség). A színeket a
// böngésző számolja ki (a témák tokenjeiből, color-mix/oklch-val együtt), és
// egy 1×1-es vásznon keresztül alakítjuk sRGB-vé – így bármilyen CSS
// színformátumot ugyanúgy mér.
//
// auditText(page): minden látható, szöveget tartalmazó elemre a szövegszín és
// a mögötte lévő (felfelé keresett, átlátszóságot is összemosó) háttér
// kontrasztja. A küszöb 4,5:1, nagy szövegnél (24px, vagy 18,66px félkövér)
// 3:1. Kimarad: letiltott gomb, rejtett elem, és ami a sötét szigeten van
// (.theme-dark) – azt a sötét téma mérése fedi. all: minden elemet visszaad,
// nem csak a küszöb alattiakat (két változat összevetéséhez).
export async function auditText(page, { skipDark = true, all = false } = {}) {
  return page.evaluate(([skipDark, all]) => {
    const cv = document.createElement('canvas'); cv.width = cv.height = 1;
    const cx = cv.getContext('2d', { willReadFrequently: true });
    const rgba = (s) => { cx.clearRect(0, 0, 1, 1); cx.fillStyle = '#000'; cx.fillStyle = s; cx.fillRect(0, 0, 1, 1); const d = cx.getImageData(0, 0, 1, 1).data; return [d[0], d[1], d[2], d[3] / 255]; };
    const alphaOf = (s) => rgba(s)[3];
    const lum = ([r, g, b]) => { const f = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
    const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
    const blend = (top, a, under) => top.map((v, i) => v * a + under[i] * (1 - a));
    function bgOf(el) {
      const layers = [];
      for (let e = el; e; e = e.parentElement) {
        const cs = getComputedStyle(e);
        const s = cs.backgroundColor; const a = alphaOf(s);
        if (a > 0) { layers.push([rgba(s).slice(0, 3), a]); if (a >= 1) break; }
      }
      let c = [255, 255, 255];
      for (let i = layers.length - 1; i >= 0; i--) c = blend(layers[i][0], layers[i][1], c);
      return c;
    }
    const out = [];
    for (const el of document.querySelectorAll('body *')) {
      if (!el.childNodes.length || ![...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) continue;
      if (skipDark && el.closest('.theme-dark')) continue;
      if (el.closest('[hidden],script,style,option') || el.closest(':disabled')) continue;
      const r = el.getBoundingClientRect(); if (!r.width || !r.height) continue;
      const cs = getComputedStyle(el); if (cs.visibility === 'hidden' || parseFloat(cs.opacity) < 0.5) continue;
      const fg = rgba(cs.color); const bg = bgOf(el);
      const col = blend(fg.slice(0, 3), alphaOf(cs.color), bg);
      const size = parseFloat(cs.fontSize), bold = parseInt(cs.fontWeight, 10) >= 700;
      const need = (size >= 24 || (bold && size >= 18.66)) ? 3 : 4.5;
      const cr = ratio(col, bg);
      if (all || cr < need) out.push({ text: el.textContent.trim().slice(0, 40), cls: el.className && String(el.className).slice(0, 40), ratio: +cr.toFixed(2), need });
    }
    return out;
  }, [skipDark, all]);
}

// Egy elem háttérszínének kontrasztja egy adott színhez képest (pl. a
// feladatszín-minta a panelen) – nem-szöveges elemekhez, küszöb: 3:1.
export async function colorRatios(page, selector, prop, against) {
  return page.evaluate(([selector, prop, against]) => {
    const cv = document.createElement('canvas'); cv.width = cv.height = 1;
    const cx = cv.getContext('2d', { willReadFrequently: true });
    const rgb = (s) => { cx.clearRect(0, 0, 1, 1); cx.fillStyle = '#000'; cx.fillStyle = s; cx.fillRect(0, 0, 1, 1); return [...cx.getImageData(0, 0, 1, 1).data].slice(0, 3); };
    const lum = ([r, g, b]) => { const f = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
    const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
    const bg = rgb(against);
    return [...document.querySelectorAll(selector)].filter((el) => !el.closest('.theme-dark')).map((el) => {
      const c = getComputedStyle(el)[prop];
      return { color: c, ratio: +ratio(rgb(c), bg).toFixed(2) };
    });
  }, [selector, prop, against]);
}
