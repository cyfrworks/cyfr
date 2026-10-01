// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The containment proof's malicious fullscreen frame. A click on `#take`
// (the person's gesture, which the browser requires) takes fullscreen for
// the whole frame, and once it is fullscreen the frame locks the pointer
// too; every time fullscreen is left, the frame asks for it again at once.
// A click on `#ask` locks the pointer and, inside the same activation, asks
// the shell for a credential prompt (`window.cyfr.credential`). Every time
// the pointer is lost, the frame asks for it again at once: a hostile frame
// would, to stay over the shell. `attack()` tries, from inside the frame,
// everything it can reach to confirm or dismiss a prompt. What it holds,
// what it was refused and how its credential prompt ended are kept in
// `window.__fullscreen` for the proof to read.
(function () {
  "use strict";
  var state = { taken: 0, fullscreen: false, pointer_lock: false, refusals: [], left: 0, locks: 0, lost: 0, asked: 0, credential: null, attacks: [] };
  var out = document.getElementById("state");

  function show() {
    state.fullscreen = !!document.fullscreenElement;
    state.pointer_lock = !!document.pointerLockElement;
    out.textContent = JSON.stringify(state);
  }

  function refused(what) {
    return function (error) {
      state.refusals.push(what + ": " + (error && error.name ? error.name : String(error)));
      show();
    };
  }

  function fullscreen() {
    try {
      var asked = document.documentElement.requestFullscreen();
      if (asked && asked.catch) asked.catch(refused("fullscreen"));
    } catch (error) {
      refused("fullscreen")(error);
    }
  }

  function lock() {
    try {
      var asked = document.body.requestPointerLock();
      if (asked && asked.catch) asked.catch(refused("pointer_lock"));
    } catch (error) {
      refused("pointer_lock")(error);
    }
  }

  document.getElementById("take").addEventListener("click", function () {
    state.taken += 1;
    fullscreen();
  });

  // The pointer, and a credential prompt asked for under the same gesture.
  document.getElementById("ask").addEventListener("click", function () {
    state.asked += 1;
    lock();
    if (window.cyfr && window.cyfr.credential) {
      window.cyfr.credential("fullscreen-probe-entry").then(
        function (answer) { state.credential = answer; show(); },
        function (error) { state.credential = { refused: error && error.code }; show(); }
      );
    }
  });

  // Fullscreen, then the pointer; fullscreen left, asked for again.
  document.addEventListener("fullscreenchange", function () {
    show();
    if (document.fullscreenElement) {
      if (!document.pointerLockElement) lock();
    } else {
      state.left += 1;
      fullscreen();
    }
  });

  // The pointer lost, asked for again at once.
  document.addEventListener("pointerlockchange", function () {
    if (document.pointerLockElement) {
      state.locks += 1;
    } else {
      state.lost += 1;
      lock();
    }
    show();
  });

  // Everything the frame can try against a prompt it cannot see.
  function attack() {
    var tried = [];
    function attempt(name, act) {
      try { act(); tried.push(name); } catch (error) { tried.push(name + ": " + (error && error.name)); }
    }
    attempt("credential_again", function () {
      if (window.cyfr && window.cyfr.credential) {
        window.cyfr.credential("fullscreen-probe-again").then(
          function () { state.attacks.push("credential_again: answered"); },
          function (error) { state.attacks.push("credential_again: " + (error && error.code)); }
        );
      }
    });
    attempt("post_to_shell", function () {
      window.parent.postMessage({ verb: "dismiss" }, "*");
      window.parent.postMessage({ verb: "confirm" }, "*");
    });
    attempt("synthetic_keys", function () {
      ["Escape", "Enter", "Tab"].forEach(function (key) {
        document.dispatchEvent(new KeyboardEvent("keydown", { key: key, bubbles: true }));
      });
    });
    attempt("reach_shell_document", function () {
      window.parent.document.querySelector("dialog");
    });
    attempt("focus_shell", function () { window.top.focus(); });
    attempt("relock", function () { document.exitPointerLock(); lock(); });
    state.attacks = state.attacks.concat(tried);
    show();
    return tried;
  }

  window.__fullscreen = {
    state: function () { show(); return JSON.parse(JSON.stringify(state)); },
    attack: attack
  };
  out.dataset.ready = "yes";
  show();
})();
