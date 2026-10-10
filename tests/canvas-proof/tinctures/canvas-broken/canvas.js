// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The canvas proof's broken canvas. Every version runs this one module, and
// the stream the version declares chooses how it behaves; the flag is the
// feed its stream's events name:
//
//   * a version that declares no feed answers a tree naming its version;
//   * one that reads `broken-quiet` waits for that feed's event and answers
//     nothing until then. No feed is bound under that name, so its
//     validation's stream answers no event, and it answers no tree;
//   * one that reads `broken-die` dies on that feed's event, so its
//     validation, whose stream answers the binding's fixture, sees it die;
//   * one that reads `broken-crash` answers a tree for its validation's
//     fixture (revision 0) and dies on a result the feed accepted (a
//     revision above 0), so it is activated and then crashes live.
//
// The version is read from the module's own address, which names it.

const FEEDS = ["broken-quiet", "broken-die", "broken-crash"]

export default function broken(canvas) {
  const version = versionOf(import.meta.url)
  const draw = (note) =>
    canvas.render({
      type: "stack",
      direction: "column",
      gap: "m",
      children: [
        {type: "text", value: "broken " + version, size: "l", weight: "strong"},
        {type: "text", value: note, tone: "muted"}
      ]
    })

  const opened = FEEDS.map((feed) => canvas.stream("feed.results", feed, (event) => heard(feed, event)))

  Promise.allSettled(opened).then((settled) => {
    if (settled.every((one) => one.status === "rejected")) draw("declares no feed")
  })

  function heard(feed, event) {
    const envelope = event && event.data
    if (!envelope || envelope.feed !== feed) return
    if (feed === "broken-die") throw new Error("the stream's event names broken-die")
    if (feed === "broken-crash") {
      if (envelope.revision > 0) throw new Error("the feed's accepted result names broken-crash")
      draw("answered its fixture")
    }
  }
}

function versionOf(url) {
  const segments = new URL(url).pathname.split("/")
  return segments.length >= 2 ? segments[segments.length - 2] : "unknown"
}
