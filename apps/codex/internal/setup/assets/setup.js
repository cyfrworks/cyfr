// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// The setup pages. Before the start the screens are the page's own; from
// the start on, the program's state (/api/state, read every second) says
// which screen shows. Every refusal shown is the program's sentence.
"use strict";

(() => {
  const token = location.hash.slice(1);
  const answers = { mode: "", domain: "", acme_email: "" };
  const stepNames = {
    files: () => "Getting CYFR's files",
    settings: () => "Writing its settings",
    access: (mode) => (mode === "public" ? "Setting up its public address" : "Joining your tailnet"),
    images: () => "Downloading CYFR",
  };
  // The start step names the mode it starts CYFR in.
  const startNames = {
    local: "Starting CYFR on this device only",
    tailnet: "Starting CYFR on your tailnet",
    public: "Starting CYFR at its public address",
  };
  let screen = "welcome";
  let phase = "answering";
  let busy = false;
  let moved = false;
  let nameEdited = false;
  let lastAddress = "";

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

  function go(name) {
    screen = name;
    if (phase === "answering") show(name);
    if (name === "public") $("#domain").focus();
  }

  function render(state) {
    phase = state.phase;
    if (phase === "answering") {
      show(screen);
      return;
    }
    if (phase === "running" || phase === "approval") {
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
    const list = $("[data-steps]");
    const steps = state.steps || [];
    const current = steps.indexOf(state.step);
    list.replaceChildren(
      ...steps.map((step, i) => {
        const li = document.createElement("li");
        li.textContent = step === "start" ? startNames[state.starting] || "Starting CYFR" : (stepNames[step] || (() => step))(state.mode);
        li.className = i < current ? "done" : i === current ? "current" : "";
        return li;
      }),
    );
    const joined = $("[data-joined]");
    joined.hidden = !state.joined;
    joined.textContent = state.joined ? `This machine is on your tailnet as ${state.joined}.` : "";

    const approval = $("[data-approval]");
    const waiting = state.phase === "approval" && !!state.auth_url;
    approval.hidden = !waiting;
    list.hidden = waiting;
    if (!waiting) {
      nameEdited = false;
      return;
    }
    // The QR code is the program's own drawing of the link, an SVG image
    // carrying no text of its own.
    const qr = $("[data-qr]");
    if (qr.dataset.drawn !== state.auth_url) {
      qr.innerHTML = state.qr || "";
      qr.dataset.drawn = state.auth_url;
      const svg = $("svg", qr);
      if (svg) {
        svg.setAttribute("role", "img");
        svg.setAttribute("aria-label", "QR code of the approval link");
      }
    }
    // Set only when it changes: each poll would end a selection of it.
    const link = $("[data-link]");
    if (link.textContent !== state.auth_url) link.textContent = state.auth_url;
    const name = $("#name");
    if (!nameEdited && document.activeElement !== name) name.value = state.name || "";
  }

  function renderDone(state) {
    const section = $('[data-screen="done"]');
    lastAddress = state.address || "";
    const address = $("[data-address]", section);
    if (address.textContent !== lastAddress) address.textContent = lastAddress;
    $("[data-sentence]", section).textContent = state.sentence || "";
    let tailnet = false;
    try {
      tailnet = new URL(lastAddress).hostname.endsWith(".ts.net");
    } catch {
      tailnet = false;
    }
    $("[data-tailnet]", section).hidden = !(tailnet && !state.sentence);
    $('[data-action="open"]', section).hidden = !lastAddress;
    $("[data-copy]", section).hidden = !lastAddress;
    if (state.moves && lastAddress && !moved) {
      moved = true;
      setTimeout(() => location.assign(lastAddress), 1500);
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
    for (const b of $$("[data-go]")) b.addEventListener("click", () => go(b.dataset.go));
    for (const b of $$("[data-mode]")) {
      b.addEventListener("click", () => {
        answers.mode = b.dataset.mode;
        answers.domain = "";
        answers.acme_email = "";
        if (answers.mode === "public") {
          go("public");
        } else {
          act("how", async () => render(await api("/api/start", answers)));
        }
      });
    }
    const on = (action, fn) => $(`[data-action="${action}"]`).addEventListener("click", fn);
    on("public-start", () =>
      act("public", async () => {
        answers.domain = $("#domain").value.trim();
        answers.acme_email = $("#acme-email").value.trim();
        render(await api("/api/start", answers));
      }),
    );
    $("#name").addEventListener("input", () => {
      nameEdited = true;
      setError("approval", "");
    });
    // A refusal shown under a field goes once the field is typed in again.
    for (const [field, where] of [["#domain", "public"], ["#acme-email", "public"]]) {
      $(field).addEventListener("input", () => setError(where, ""));
    }
    on("rename", () =>
      act("approval", async () => {
        const state = await api("/api/name", { name: $("#name").value.trim() });
        nameEdited = false;
        render(state);
      }),
    );
    on("cancel", () => act("approval", async () => render(await api("/api/cancel", {}))));
    for (const b of $$("[data-offer]")) {
      b.addEventListener("click", () => act("problem", async () => render(await api("/api/choose", { offer: b.dataset.offer }))));
    }
    for (const b of $$("[data-copy]")) b.addEventListener("click", () => copy(b));
    on("open", () => {
      if (lastAddress) location.assign(lastAddress);
    });
  }

  if (!token) {
    show("nokey");
    return;
  }
  wire();
  show(screen);
  poll();
  polling = setInterval(poll, 1000);
})();
