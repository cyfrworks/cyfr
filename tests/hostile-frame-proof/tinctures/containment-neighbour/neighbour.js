// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The containment proof's sibling. Loaded as a page, it keeps every window
// message that reaches it and did not come from the shell's handshake, so
// the proof can read what a sibling frame's post delivered. Loaded as a
// script by another tincture, it sets the mark the probe looks for.
window.__containmentNeighbour = "ran";

(function () {
  "use strict";
  var out = document.getElementById("messages");
  if (!out) return;
  var seen = [];
  window.addEventListener("message", function (event) {
    var data;
    try { data = JSON.parse(JSON.stringify(event.data)); } catch (_error) { data = String(event.data); }
    seen.push({ origin: event.origin, from_parent: event.source === window.parent, data: data });
    out.textContent = JSON.stringify(seen);
  });
})();
