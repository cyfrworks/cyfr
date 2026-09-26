// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The game's physics, off the main thread: Rapier's WebAssembly module
// stepping a tower of boxes at a fixed timestep. Bundled inline, so the
// worker starts from a blob: URL. Every step posts the boxes' positions and
// rotations in one transferred buffer; nothing is allocated per step but
// that buffer.

import RAPIER from "@dimforge/rapier3d-compat";

const STEP = 1 / 60;
const BOXES = 64;

let world = null;
let bodies = [];
let steps = 0;

async function start() {
  await RAPIER.init();
  world = new RAPIER.World({ x: 0, y: -9.81, z: 0 });
  world.timestep = STEP;

  const ground = world.createRigidBody(RAPIER.RigidBodyDesc.fixed());
  world.createCollider(RAPIER.ColliderDesc.cuboid(20, 0.5, 20).setTranslation(0, -0.5, 0), ground);

  // The pool: every box the game will ever have, made once.
  for (let i = 0; i < BOXES; i++) {
    const x = (i % 4) - 1.5;
    const y = 0.5 + Math.floor(i / 16) * 1.05;
    const z = (Math.floor(i / 4) % 4) - 1.5;
    const body = world.createRigidBody(RAPIER.RigidBodyDesc.dynamic().setTranslation(x, y, z));
    world.createCollider(RAPIER.ColliderDesc.cuboid(0.5, 0.5, 0.5).setRestitution(0.2), body);
    bodies.push(body);
  }

  postMessage({ type: "ready", boxes: BOXES, engine: RAPIER.version() });
  setInterval(step, STEP * 1000);
}

function step() {
  world.step();
  steps += 1;
  const out = new Float32Array(BOXES * 7);
  for (let i = 0; i < BOXES; i++) {
    const t = bodies[i].translation();
    const r = bodies[i].rotation();
    out.set([t.x, t.y, t.z, r.x, r.y, r.z, r.w], i * 7);
  }
  postMessage({ type: "step", steps, transforms: out }, [out.buffer]);
}

onmessage = (event) => {
  if (event.data && event.data.type === "push" && world) {
    const body = bodies[event.data.index % BOXES];
    body.applyImpulse({ x: event.data.x, y: 2, z: event.data.z }, true);
  }
};

start().catch((error) => postMessage({ type: "error", message: String(error && error.message || error) }));
