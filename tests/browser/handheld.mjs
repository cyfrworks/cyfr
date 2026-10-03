// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The proposed handheld, shared by every proof that drives a glass: a
// 720×720 CSS-pixel touch viewport in Chromium, standing in for the square
// handheld until a board is chosen, and the checks a screen meets there
// (WCAG 2.2 AA): every control at least 24×24 CSS px, visible text at least
// 12 px, and nothing overflowing sideways.

// A browser context's options for the handheld.
export const HANDHELD = { viewport: { width: 720, height: 720 }, isMobile: true, hasTouch: true };

// What `page` shows inside `scope` (a selector; the whole body without
// one), measured: each visible control under 24×24 CSS px, each visible
// text under 12 px, and whether the document overflows the viewport
// sideways. A scope the page does not hold answers `missing`.
export const measure = (page, scope) => page.evaluate((selector) => {
  const root = selector ? document.querySelector(selector) : document.body;
  if (!root) return { missing: selector };
  const visible = (el) => {
    const style = getComputedStyle(el);
    const box = el.getBoundingClientRect();
    return style.visibility !== "hidden" && style.display !== "none" && box.width > 0 && box.height > 0;
  };
  const small = [];
  for (const el of root.querySelectorAll("button, a[href], input:not([type=hidden]), select, textarea, [role=button]")) {
    if (!visible(el)) continue;
    const box = el.getBoundingClientRect();
    if (box.width < 24 || box.height < 24) small.push({ tag: el.tagName, test: el.getAttribute("data-test"), text: (el.innerText || el.value || "").slice(0, 40), w: Math.round(box.width), h: Math.round(box.height) });
  }
  const tiny = [];
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!node.textContent.trim() || !node.parentElement || !visible(node.parentElement)) continue;
    const size = parseFloat(getComputedStyle(node.parentElement).fontSize);
    if (size < 12) tiny.push({ text: node.textContent.trim().slice(0, 40), px: size });
  }
  return {
    controls_under_24: small, text_under_12: tiny,
    overflow: document.documentElement.scrollWidth > window.innerWidth + 1,
    width: window.innerWidth,
  };
}, scope);

// The names of the screens in `measured` (name → `measure`'s answer) that
// break a check. A screen never measured, or whose scope was missing, breaks
// it too: a check of nothing holds nothing.
export const unmet = (measured) => Object.entries(measured)
  .filter(([, m]) => !m || m.missing !== undefined || m.overflow || m.controls_under_24.length || m.text_under_12.length)
  .map(([name]) => name);
