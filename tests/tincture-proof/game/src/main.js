// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// The tincture proof's game. The patterns the tincture guide names, each
// once: physics off the main thread (Rapier's WebAssembly module in an
// inline worker, stepping at a fixed timestep), objects pooled (one
// instanced mesh for every box), particles on the GPU (positions computed
// in the vertex shader from a time uniform), a fixed set of lights, one
// sound decoded once, pointer lock and fullscreen from a gesture, and one
// save — an invocation on an event, never per frame.
//
// `window.__game` is what the proof reads: when the game was ready, what
// ran, and the save's answer.

import {
  AdditiveBlending,
  AmbientLight,
  BoxGeometry,
  BufferAttribute,
  BufferGeometry,
  Color,
  DirectionalLight,
  InstancedMesh,
  Matrix4,
  MeshStandardMaterial,
  PerspectiveCamera,
  Points,
  Quaternion,
  Scene,
  ShaderMaterial,
  Vector3,
  WebGLRenderer,
} from "three";
import PhysicsWorker from "./physics.worker.js?worker&inline";

const PARTICLES = 4096;

const game = {
  startedAt: Date.now(),
  readyAt: null,
  renderer: null,
  engine: null,
  steps: 0,
  frames: 0,
  audio: null,
  worker: "inline",
  saved: null,
  errors: [],
  async save() {
    try {
      const result = await cyfr.invoke("c:local.files", "save", { slot: "proof", state: { steps: game.steps } });
      game.saved = { ok: true, result };
    } catch (error) {
      game.saved = { ok: false, code: error.code, stage: error.stage || null, message: error.message };
    }
    return game.saved;
  },
  resources() {
    return performance.getEntriesByType("resource").map((entry) => ({
      name: entry.name, start: entry.startTime, duration: entry.duration, type: entry.initiatorType,
    }));
  },
};
window.__game = game;

const stage = document.getElementById("stage");

// ---- rendering --------------------------------------------------------------

let renderer = null;
const scene = new Scene();
scene.background = new Color(0x0b0d17);
const camera = new PerspectiveCamera(55, window.innerWidth / Math.max(window.innerHeight, 1), 0.1, 200);
camera.position.set(7, 6, 9);
camera.lookAt(0, 1.5, 0);

// A fixed set of lights, chosen once.
scene.add(new AmbientLight(0x8090b0, 0.6));
const sun = new DirectionalLight(0xffffff, 1.4);
sun.position.set(5, 10, 4);
scene.add(sun);

// Every box, pooled in one instanced mesh.
const boxes = new InstancedMesh(new BoxGeometry(1, 1, 1), new MeshStandardMaterial({ color: 0x6366f1 }), 64);
scene.add(boxes);

// Particles on the GPU: each point's path is a function of its seed and
// the time, computed in the vertex shader.
const seeds = new Float32Array(PARTICLES * 3);
for (let i = 0; i < seeds.length; i++) seeds[i] = Math.random();
const particleGeometry = new BufferGeometry();
particleGeometry.setAttribute("position", new BufferAttribute(new Float32Array(PARTICLES * 3), 3));
particleGeometry.setAttribute("seed", new BufferAttribute(seeds, 3));
const particles = new ShaderMaterial({
  uniforms: { time: { value: 0 } },
  vertexShader: `
    attribute vec3 seed;
    uniform float time;
    void main() {
      float t = mod(time * (0.2 + seed.y) + seed.z * 10.0, 10.0);
      vec3 p = vec3((seed.x - 0.5) * 16.0, t * 1.2, (seed.z - 0.5) * 16.0);
      p.x += sin(time + seed.y * 6.28) * 0.5;
      gl_PointSize = 2.0 + seed.y * 3.0;
      gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 1.0);
    }`,
  fragmentShader: `
    void main() { gl_FragColor = vec4(0.55, 0.65, 1.0, 0.6); }`,
  transparent: true,
  depthWrite: false,
  blending: AdditiveBlending,
});
scene.add(new Points(particleGeometry, particles));

try {
  renderer = new WebGLRenderer({ antialias: false });
  renderer.setSize(window.innerWidth, window.innerHeight);
  stage.appendChild(renderer.domElement);
  game.renderer = "webgl";
} catch (error) {
  // A browser without WebGL still runs the physics and the sound.
  game.renderer = "unavailable";
  game.errors.push(`renderer: ${error.message}`);
}

const matrix = new Matrix4();
const position = new Vector3();
const rotation = new Quaternion();
const unit = new Vector3(1, 1, 1);
let latest = null;

function frame(now) {
  if (latest) {
    for (let i = 0; i < 64; i++) {
      const o = i * 7;
      position.set(latest[o], latest[o + 1], latest[o + 2]);
      rotation.set(latest[o + 3], latest[o + 4], latest[o + 5], latest[o + 6]);
      boxes.setMatrixAt(i, matrix.compose(position, rotation, unit));
    }
    boxes.instanceMatrix.needsUpdate = true;
  }
  particles.uniforms.time.value = now / 1000;
  if (renderer) renderer.render(scene, camera);
  game.frames += 1;
  maybeReady();
  requestAnimationFrame(frame);
}

// ---- physics ----------------------------------------------------------------

const physics = new PhysicsWorker();
physics.onmessage = (event) => {
  const message = event.data;
  if (message.type === "ready") game.engine = message.engine;
  if (message.type === "step") {
    game.steps = message.steps;
    latest = message.transforms;
    maybeReady();
  }
  if (message.type === "error") game.errors.push(`physics: ${message.message}`);
};
physics.onerror = (event) => game.errors.push(`physics worker: ${event.message || "error"}`);

// ---- sound: decoded once ----------------------------------------------------

const audio = new AudioContext();
let tone = null;
// A version's files never change under their address, so the browser's
// cached copy is used whenever it holds one.
fetch(new URL("sound.wav", document.baseURI), { cache: "force-cache" })
  .then((response) => response.arrayBuffer())
  .then((bytes) => audio.decodeAudioData(bytes))
  .then((buffer) => {
    tone = buffer;
    game.audio = { decoded: true, seconds: Math.round(buffer.duration * 100) / 100 };
    maybeReady();
  })
  .catch((error) => {
    game.audio = { decoded: false, error: String(error && error.message || error) };
    maybeReady();
  });

function play() {
  if (!tone) return;
  const source = audio.createBufferSource();
  source.buffer = tone;
  source.connect(audio.destination);
  source.start();
}

// ---- input ------------------------------------------------------------------

stage.addEventListener("click", () => {
  if (stage.requestPointerLock) stage.requestPointerLock();
  physics.postMessage({ type: "push", index: Math.floor(Math.random() * 64), x: 3, z: -2 });
  play();
});

window.addEventListener("keydown", (event) => {
  if (event.key === "f" && document.documentElement.requestFullscreen) {
    document.documentElement.requestFullscreen().catch(() => {});
  }
  if (event.key === "s") game.save();
});

window.addEventListener("resize", () => {
  camera.aspect = window.innerWidth / Math.max(window.innerHeight, 1);
  camera.updateProjectionMatrix();
  if (renderer) renderer.setSize(window.innerWidth, window.innerHeight);
});

// ---- ready: the first rendered frame after physics stepped and the sound decoded

function maybeReady() {
  if (game.readyAt || game.steps < 1 || game.frames < 1 || !game.audio) return;
  game.readyAt = Date.now();
  cyfr.title("proof-game");
  cyfr.ready();
}

requestAnimationFrame(frame);
