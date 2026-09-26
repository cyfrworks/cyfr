// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// Writes public/sound.wav, the game's one sound: a short decaying tone,
// 16-bit mono PCM. Run by `npm run build` before Vite, which copies public/
// into dist/, so the source tree stays text.

import { mkdirSync, writeFileSync } from "node:fs";

const rate = 22050;
const seconds = 0.35;
const samples = Math.floor(rate * seconds);
const data = Buffer.alloc(samples * 2);
for (let i = 0; i < samples; i++) {
  const t = i / rate;
  const value = Math.sin(2 * Math.PI * 330 * t) * Math.exp(-9 * t) * 0.6;
  data.writeInt16LE(Math.round(value * 32767), i * 2);
}

const header = Buffer.alloc(44);
header.write("RIFF", 0);
header.writeUInt32LE(36 + data.length, 4);
header.write("WAVE", 8);
header.write("fmt ", 12);
header.writeUInt32LE(16, 16);
header.writeUInt16LE(1, 20);
header.writeUInt16LE(1, 22);
header.writeUInt32LE(rate, 24);
header.writeUInt32LE(rate * 2, 28);
header.writeUInt16LE(2, 32);
header.writeUInt16LE(16, 34);
header.write("data", 36);
header.writeUInt32LE(data.length, 40);

mkdirSync("public", { recursive: true });
writeFileSync("public/sound.wav", Buffer.concat([header, data]));
