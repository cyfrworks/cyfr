// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The frame sandbox containment proof's probe, run from inside a frame the
// shell created. The tincture declares nothing, so everything it attempts
// beyond its own bundle is something the frame's sandbox, its derived policy,
// the endpoint or the shell must refuse.
//
// The harness (../../proof.mjs) drives one attempt at a time through
// `window.__containment.run(name, args)` and reads what the frame itself
// could see of it; what only the network or another window can see, the
// harness reads there. Nothing here asserts. The addresses an attempt names
// are the harness's own: its recording endpoint and the tinctures it
// published into the release under test.

(function () {
  "use strict";

  var TIMEOUT_MS = 4000;
  var WIRE_VERSION = 1;
  var violations = [];

  document.addEventListener("securitypolicyviolation", function (event) {
    violations.push({
      directive: event.effectiveDirective || event.violatedDirective,
      blocked: event.blockedURI
    });
  });

  function describe(error) {
    return error && (error.name || "Error") + ": " + (error.message || String(error));
  }

  function within(promise) {
    return Promise.race([
      promise,
      new Promise(function (resolve) {
        setTimeout(function () {
          resolve({ settled: false, detail: "no answer within " + TIMEOUT_MS + " ms" });
        }, TIMEOUT_MS);
      })
    ]);
  }

  function fetchProbe(url, init) {
    return within(
      fetch(url, init).then(
        function (response) {
          return response.text().then(function (body) {
            return {
              settled: true,
              answered: true,
              status: response.status,
              type: response.type,
              redirected: response.redirected,
              url: response.url,
              body: body.slice(0, 400)
            };
          });
        },
        function (error) { return { settled: true, answered: false, detail: describe(error) }; }
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
      script.onerror = function () {
        resolve({ settled: true, loaded: false, ran: window[mark] === "ran" });
      };
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

  // A call through the SDK, read as the frame reads it: its value, or the
  // refusal's class, stage and sentence.
  function sdkProbe(call) {
    if (!window.cyfr) return Promise.resolve({ settled: true, ok: false, detail: "no SDK in this page" });
    var attempt;
    try {
      attempt = Promise.resolve(call(window.cyfr));
    } catch (error) {
      attempt = Promise.reject(error);
    }
    return within(attempt.then(
      function (value) {
        var summary = value;
        try { summary = JSON.parse(JSON.stringify(value)); } catch (_error) { summary = String(value); }
        return { settled: true, ok: true, value: summary };
      },
      function (error) {
        return {
          settled: true,
          ok: false,
          code: error && error.code,
          stage: error && error.stage,
          message: error && error.message
        };
      }
    ));
  }

  var probes = {
    // ---- the bundle's own function -------------------------------------
    module_script: function () { return scriptProbe("module.js", true, "__containmentModule"); },
    blob_worker: workerProbe,
    wasm_instantiate: wasmProbe,
    public_neighbour_script: function (args) {
      return scriptProbe(args.publicNeighbour, false, "__frameFactsNeighbour");
    },

    // ---- what the frame must not reach -----------------------------------
    private_neighbour_script: function (args) {
      return scriptProbe(args.privateNeighbour, false, "__containmentNeighbour");
    },

    form_post: function (args) {
      try {
        var form = document.createElement("form");
        form.method = "post";
        form.action = args.receiver + "/form";
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
    },

    top_read: function () {
      var result = { settled: true };
      try {
        result.href = String(window.top.location.href);
        result.read = true;
      } catch (error) {
        result.read = false;
        result.detail = describe(error);
      }
      try {
        result.parent_document = !!window.parent.document;
      } catch (error) {
        result.parent_document = false;
      }
      return Promise.resolve(result);
    },

    top_navigate: function (args) {
      try {
        window.top.location = args.receiver + "/top";
        return Promise.resolve({ settled: true, threw: false });
      } catch (error) {
        return Promise.resolve({ settled: true, threw: true, detail: describe(error) });
      }
    },

    opener: function () {
      return Promise.resolve({ settled: true, opener: window.opener === null ? null : "present" });
    },

    popup: function (args) {
      try {
        var opened = window.open(args.receiver + "/popup");
        return Promise.resolve({ settled: true, opened: !!opened });
      } catch (error) {
        return Promise.resolve({ settled: true, opened: false, detail: describe(error) });
      }
    },

    fetch_undeclared: function (args) { return fetchProbe(args.receiver + "/fetch"); },

    image_beacon: function (args) {
      return within(new Promise(function (resolve) {
        var image = new Image();
        image.onload = function () { resolve({ settled: true, loaded: true }); };
        image.onerror = function () { resolve({ settled: true, loaded: false }); };
        image.src = args.receiver + "/img";
      }));
    },

    send_beacon: function (args) {
      try {
        var queued = navigator.sendBeacon(args.receiver + "/beacon", "probe=beacon");
        return Promise.resolve({ settled: true, queued: !!queued });
      } catch (error) {
        return Promise.resolve({ settled: true, queued: false, detail: describe(error) });
      }
    },

    // An asset of the probe's own that the harness answers with a redirect
    // to its recording endpoint.
    redirect_fetch: function () { return fetchProbe("moved.json"); },

    // The credential the frame's own address carries is for reading bytes;
    // presented to a data route it must open nothing.
    asset_credential_on_data_route: function (args) {
      return fetchProbe("/_f/v1/invoke", {
        method: "POST",
        headers: { "content-type": "application/json", authorization: "Bearer " + args.credential },
        body: JSON.stringify({ v: WIRE_VERSION, ref: "c:local.files", operation: "save", args: {} })
      });
    },

    undeclared_invoke: function () {
      return sdkProbe(function (cyfr) { return cyfr.invoke("c:local.files", "save", { slot: "probe" }); });
    },

    undeclared_action: function () {
      return sdkProbe(function (cyfr) { return cyfr.action("vault.list", {}); });
    },

    undeclared_stream: function () {
      return sdkProbe(function (cyfr) {
        return cyfr.stream("mcp_servers.changes", null, function () {}).then(function (handle) {
          if (handle && handle.close) handle.close();
          return { opened: true };
        });
      });
    },

    // The same call as undeclared_invoke, made once the shell has hidden and
    // suspended this frame.
    suspended_invoke: function () {
      return sdkProbe(function (cyfr) { return cyfr.invoke("c:local.files", "save", { slot: "probe" }); });
    },

    fullscreen_undeclared: function () {
      try {
        return within(
          document.documentElement.requestFullscreen().then(
            function () { return { settled: true, entered: true }; },
            function (error) { return { settled: true, entered: false, detail: describe(error) }; }
          )
        );
      } catch (error) {
        return Promise.resolve({ settled: true, entered: false, detail: describe(error) });
      }
    },

    cookie_and_storage: function () {
      var result = { settled: true };
      try { result.cookie = String(document.cookie); } catch (error) { result.cookie_detail = describe(error); }
      try {
        window.localStorage.setItem("probe", "1");
        result.local_storage = true;
      } catch (error) {
        result.local_storage = false;
        result.storage_detail = describe(error);
      }
      return Promise.resolve(result);
    },

    // ---- the shell verb the proof uses to get a sibling frame ------------
    open_neighbour: function (args) {
      if (!window.cyfr) return Promise.resolve({ settled: true, asked: false, detail: "no SDK in this page" });
      try {
        window.cyfr.open(args.ref);
        return Promise.resolve({ settled: true, asked: true });
      } catch (error) {
        return Promise.resolve({ settled: true, asked: false, detail: describe(error) });
      }
    },

    // A post to every sibling window, once as a plain message and once
    // shaped like the shell's handshake.
    sibling_message: function () {
      var posted = 0;
      var detail = null;
      try {
        var frames = window.parent.frames;
        for (var i = 0; i < frames.length; i++) {
          if (frames[i] === window) continue;
          frames[i].postMessage({ containment: "hello from a sibling" }, "*");
          frames[i].postMessage({ type: "cyfr:handshake", frame: "frm_forged0000" }, "*");
          posted += 1;
        }
      } catch (error) {
        detail = describe(error);
      }
      return Promise.resolve({ settled: true, posted: posted, detail: detail });
    },

    // ---- navigating itself ----------------------------------------------
    // The frame navigates itself to `args.target`, carrying what it has:
    // its own address. The document is gone afterwards, so each of these
    // is the last attempt of the frame it runs in.
    self_navigation: function (args) {
      try {
        var mark = args.target.indexOf("?") === -1 ? "?" : "&";
        window.location.assign(args.target + mark + "carried=" + encodeURIComponent(window.location.pathname));
        return Promise.resolve({ settled: true, attempted: true });
      } catch (error) {
        return Promise.resolve({ settled: true, attempted: false, detail: describe(error) });
      }
    }
  };

  window.__containment = {
    names: Object.keys(probes),
    violations: function () { return violations.slice(); },
    origin: String(window.origin),
    run: function (name, args) {
      var probe = probes[name];
      if (!probe) return Promise.resolve({ settled: true, detail: "no such probe: " + name });
      var attempt;
      try {
        attempt = Promise.resolve(probe(args || {}));
      } catch (error) {
        attempt = Promise.resolve({ settled: true, detail: describe(error) });
      }
      return attempt.then(function (result) {
        result.violations = violations.slice();
        return result;
      });
    }
  };

  document.getElementById("results").setAttribute("data-ready", "yes");
})();
