// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The setup pages. Before the start the page shows its welcome; from the
// start on, the program's state (/api/state, read every second) says which
// screen shows. Every refusal shown is the program's sentence.
"use strict";

(() => {
  const token = location.hash.slice(1);
  const stepNames = {
    files: "Getting CYFR's files",
    settings: "Writing its settings",
    images: "Downloading CYFR",
    start: "Starting CYFR",
  };
  let busy = false;
  let moved = false;
  let setupURL = "";

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));

  function show(name) {
    for (const section of $$("[data-screen]")) {
      section.hidden = section.dataset.screen !== name;
    }
  }

  function setError(where, text) {
    const el = $(`[data-error="${where}"]`);
    if (el) el.textContent = text || "";
  }

  // api calls the program with this run's token; a refusal throws its
  // sentence.
  async function api(path, body) {
    const init = { headers: { "X-Cyfr-Setup": token }, cache: "no-store" };
    if (body !== undefined) {
      init.method = "POST";
      init.headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(body);
    }
    const res = await fetch(path, init);
    let data = null;
    try {
      data = await res.json();
    } catch {
      data = null;
    }
    if (!res.ok) {
      throw new Error((data && data.sentence) || `The setup program answered ${res.status}.`);
    }
    return data;
  }

  // act runs one request at a time, its refusal shown at where.
  async function act(where, fn) {
    if (busy) return;
    busy = true;
    for (const b of $$("button")) b.disabled = true;
    setError(where, "");
    try {
      await fn();
    } catch (err) {
      setError(where, err.message);
    } finally {
      busy = false;
      for (const b of $$("button")) b.disabled = false;
    }
  }

  function render(state) {
    const phase = state.phase;
    if (phase === "ready") {
      show("welcome");
    } else if (phase === "running") {
      renderProgress(state);
      show("progress");
    } else if (phase === "problem") {
      const section = $('[data-screen="problem"]');
      $("[data-sentence]", section).textContent = state.sentence || "";
      for (const b of $$("[data-offer]", section)) {
        b.hidden = !(state.offers || []).includes(b.dataset.offer);
      }
      show("problem");
    } else if (phase === "done") {
      renderDone(state);
      show("done");
    } else if (phase === "failed") {
      $('[data-screen="failed"] [data-sentence]').textContent = state.sentence || "";
      show("failed");
    }
  }

  function renderProgress(state) {
    const steps = state.steps || [];
    const current = steps.indexOf(state.step);
    $("[data-steps]").replaceChildren(
      ...steps.map((step, i) => {
        const li = document.createElement("li");
        li.textContent = stepNames[step] || step;
        li.className = i < current ? "done" : i === current ? "current" : "";
        return li;
      }),
    );
  }

  // renderDone shows the setup link and moves the browser there.
  function renderDone(state) {
    const section = $('[data-screen="done"]');
    setupURL = state.setup_url || "";
    const link = $("[data-setup-url]", section);
    if (link.textContent !== setupURL) link.textContent = setupURL;
    $("[data-setup]", section).hidden = !setupURL;
    $('[data-action="open"]', section).hidden = !setupURL;
    if (setupURL && !moved) {
      moved = true;
      setTimeout(() => location.assign(setupURL), 1500);
    }
  }

  // copy puts the text of the element a Copy button names on the
  // clipboard and says so on the button. Where the clipboard API is
  // missing or refused, as some browsers refuse it to a page they do not
  // count as a secure context, it selects the text instead, copies that
  // where the browser still lets a page, and otherwise leaves it selected
  // for the person to copy.
  async function copy(button) {
    const el = $(button.dataset.copy, button.closest("section"));
    const text = el ? el.textContent : "";
    if (!text) return;
    let copied = false;
    if (navigator.clipboard && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text);
        copied = true;
      } catch {
        copied = false;
      }
    }
    if (!copied) {
      const range = document.createRange();
      range.selectNodeContents(el);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      try {
        copied = document.execCommand("copy");
      } catch {
        copied = false;
      }
      if (copied) selection.removeAllRanges();
    }
    acknowledge(button, copied ? "Copied" : "Selected: copy it");
  }

  // acknowledge shows what a Copy button did on it for two seconds.
  function acknowledge(button, said) {
    if (!button.dataset.label) button.dataset.label = button.textContent;
    button.textContent = said;
    clearTimeout(Number(button.dataset.timer));
    button.dataset.timer = String(setTimeout(() => (button.textContent = button.dataset.label), 2000));
  }

  let polling = null;
  async function poll() {
    try {
      const state = await api("/api/state");
      render(state);
      if (state.phase === "done" || state.phase === "failed") stopPolling();
    } catch {
      // The program stops serving once the run has ended and been read;
      // what shows stays.
    }
  }
  function stopPolling() {
    if (polling !== null) clearInterval(polling);
    polling = null;
  }

  function wire() {
    const on = (action, fn) => $(`[data-action="${action}"]`).addEventListener("click", fn);
    on("start", () => act("welcome", async () => render(await api("/api/start", {}))));
    for (const b of $$("[data-offer]")) {
      b.addEventListener("click", () => act("problem", async () => render(await api("/api/choose", { offer: b.dataset.offer }))));
    }
    for (const b of $$("[data-copy]")) b.addEventListener("click", () => copy(b));
    on("open", () => {
      if (setupURL) location.assign(setupURL);
    });
  }

  if (!token) {
    show("nokey");
    return;
  }
  wire();
  show("welcome");
  poll();
  polling = setInterval(poll, 1000);
})();
