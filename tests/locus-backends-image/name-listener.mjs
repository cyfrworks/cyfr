// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The image suites' name listener: an upstream resolver the suites run
// beside a namespace (it shares the namespace, listening on 127.0.0.53:53,
// where that namespace's resolver configuration points), which the code
// under test did not write. It answers every name under `l5.test` with
// 192.0.2.7 and refuses every other, and prints `heard <name>` for each
// query it is asked, so a suite reads which names reached it.
import dgram from "node:dgram";

const socket = dgram.createSocket("udp4");

function name(query) {
  const labels = [];
  let at = 12;
  while (at < query.length && query[at] !== 0) {
    labels.push(query.subarray(at + 1, at + 1 + query[at]).toString());
    at += query[at] + 1;
  }
  return { name: labels.join(".").toLowerCase(), end: at + 5 };
}

socket.on("message", (query, from) => {
  if (query.length < 17) return;
  const { name: asked, end } = name(query);
  console.log(`heard ${asked}`);
  const question = query.subarray(12, end);
  const ours = asked === "l5.test" || asked.endsWith(".l5.test");
  const type = query.readUInt16BE(end - 4);
  const header = Buffer.from([query[0], query[1], 0x81, ours ? 0x80 : 0x85, 0, 1, 0, ours && type === 1 ? 1 : 0, 0, 0, 0, 0]);
  const answer = ours && type === 1 ? Buffer.from([0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 7]) : Buffer.alloc(0);
  socket.send(Buffer.concat([header, question, answer]), from.port, from.address);
});
socket.bind(53, "127.0.0.53", () => console.log("listening 127.0.0.53:53"));
