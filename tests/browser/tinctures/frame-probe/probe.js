// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The frame-facts probes, run from inside the sandboxed frame. Each attempt
// records what the frame itself could see of it; the harness
// (tests/browser/frame_facts.py) adds what only the page can see — a
// request that left, a message that arrived, a navigation — and decides
// each outcome from both. Nothing here asserts: the record is the result.
//
// The results are written to #results as JSON with data-done="yes". The
// ninth attempt, the frame navigating itself, waits for the harness's go
// message, so the harness reads the other eight first.

(function () {
  "use strict";

  var out = document.getElementById("results");
  var params = new URLSearchParams(window.location.search);
  var here = window.location.pathname.replace(/\/$/, "");
  // The tinctures' common prefix: /t/<athanor>/<publisher>/.
  var prefix = here.slice(0, here.lastIndexOf("/") + 1);
  var results = { origin: String(window.origin), url: window.location.href, violations: [] };
  var TIMEOUT_MS = 4000;

  document.addEventListener("securitypolicyviolation", function (event) {
    results.violations.push({
      directive: event.effectiveDirective || event.violatedDirective,
      blocked: event.blockedURI
    });
  });

  function write(done) {
    out.textContent = JSON.stringify(results);
    out.setAttribute("data-done", done ? "yes" : "no");
  }

  function describe(error) {
    return error && (error.name || "Error") + ": " + (error.message || String(error));
  }

  function within(promise) {
    return Promise.race([
      promise,
      new Promise(function (resolve) {
        setTimeout(function () { resolve({ settled: false, detail: "no answer within " + TIMEOUT_MS + " ms" }); }, TIMEOUT_MS);
      })
    ]);
  }

  // The second document, after the frame navigated itself.
  if (params.get("navigated") === "1") {
    results.navigated = true;
    write(true);
    return;
  }

  function fetchProbe(path) {
    return within(
      fetch(path).then(
        function (response) {
          return response.text().then(function (body) {
            return {
              settled: true,
              ok: true,
              status: response.status,
              type: response.type,
              redirected: response.redirected,
              url: response.url,
              body: body.slice(0, 80)
            };
          });
        },
        function (error) { return { settled: true, ok: false, detail: describe(error) }; }
      )
    );
  }

  function scriptProbe(src, module, mark) {
    return within(new Promise(function (resolve) {
      var script = document.createElement("script");
      if (module) script.type = "module";
      script.src = src;
      script.onload = function () {
        // A module runs after its load event is queued; give it a turn.
        setTimeout(function () {
          resolve({ settled: true, loaded: true, ran: window[mark] === "ran" });
        }, 50);
      };
      script.onerror = function () { resolve({ settled: true, loaded: false, ran: window[mark] === "ran" }); };
      document.body.appendChild(script);
    }));
  }

  function workerProbe() {
    return within(new Promise(function (resolve) {
      try {
        var url = URL.createObjectURL(new Blob(["postMessage('worker ran')"], { type: "text/javascript" }));
        var worker = new Worker(url);
        worker.onmessage = function (event) { resolve({ settled: true, ran: true, detail: String(event.data) }); };
        worker.onerror = function (event) {
          resolve({ settled: true, ran: false, detail: "error event: " + (event.message || "no message") });
        };
      } catch (error) {
        resolve({ settled: true, ran: false, detail: describe(error) });
      }
    }));
  }

  function wasmProbe() {
    // The smallest module: the magic number and version 1.
    var bytes = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);
    try {
      return within(
        WebAssembly.instantiate(bytes).then(
          function () { return { settled: true, instantiated: true }; },
          function (error) { return { settled: true, instantiated: false, detail: describe(error) }; }
        )
      );
    } catch (error) {
      return Promise.resolve({ settled: true, instantiated: false, detail: describe(error) });
    }
  }

  function formProbe() {
    // Posted into a frame of the probe's own, so an allowed post does not
    // navigate the probe away; whether the request left is the harness's.
    try {
      var form = document.createElement("form");
      form.method = "post";
      form.action = here + "/form-target.json";
      form.target = "sink";
      var field = document.createElement("input");
      field.name = "probe";
      field.value = "form";
      form.appendChild(field);
      document.body.appendChild(form);
      form.submit();
      return Promise.resolve({ settled: true, submitted: true });
    } catch (error) {
      return Promise.resolve({ settled: true, submitted: false, detail: describe(error) });
    }
  }

  function messageProbe() {
    try {
      window.parent.postMessage({ frameFacts: "hello from the frame" }, "*");
      return Promise.resolve({ settled: true, posted: true });
    } catch (error) {
      return Promise.resolve({ settled: true, posted: false, detail: describe(error) });
    }
  }

  var probes = [
    ["fetch", function () { return fetchProbe("asset.json"); }],
    ["form_post", formProbe],
    ["message_to_parent", messageProbe],
    ["neighbour_script", function () {
      return scriptProbe(prefix + "frame-neighbour/neighbour.js", false, "__frameFactsNeighbour");
    }],
    ["module_script", function () { return scriptProbe("module.js", true, "__frameFactsModule"); }],
    ["blob_worker", workerProbe],
    ["wasm_instantiate", wasmProbe],
    // An asset the harness answers with a 302 to asset.json (no /t/ route
    // redirects today) carrying the CORS header today's asset answers
    // carry, the same 302 without it, and a route the server itself
    // redirects (/chat, to the sign-in page).
    ["redirect_fetch", function () {
      return fetchProbe("moved.json").then(function (asset) {
        return fetchProbe("moved-bare.json").then(function (bare) {
          return fetchProbe("/chat").then(function (server) {
            return { settled: true, asset: asset, bare: bare, server: server };
          });
        });
      });
    }]
  ];

  function run(index) {
    if (index === probes.length) {
      write(true);
      window.addEventListener("message", function (event) {
        if (event.data && event.data.frameFacts === "navigate") {
          try {
            window.location.assign(here + "?navigated=1");
            results.self_navigation = { attempted: true };
          } catch (error) {
            results.self_navigation = { attempted: false, detail: describe(error) };
          }
          write(true);
        }
      });
      return;
    }
    var name = probes[index][0];
    var attempt;
    try {
      attempt = Promise.resolve(probes[index][1]());
    } catch (error) {
      attempt = Promise.resolve({ settled: true, detail: describe(error) });
    }
    attempt.then(function (result) {
      results[name] = result;
      write(false);
      run(index + 1);
    });
  }

  write(false);
  run(0);
})();
