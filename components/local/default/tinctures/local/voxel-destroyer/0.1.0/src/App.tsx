// ═══════════════════════════════════════════════════════════════
//  VOXEL DESTROYER  —  App.tsx  (v3 — dest marker, mobile touch, laser steer)
// ═══════════════════════════════════════════════════════════════
import { useEffect, useRef, useState, useCallback } from 'react';
import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';

// ── CONSTANTS ───────────────────────────────────────────────────
const GRID_W = 44;
const GRID_H = 22;
const GRID_D = 44;
const MAX_VOXELS  = GRID_W * GRID_H * GRID_D;
const MAX_DEBRIS  = 1200;
const MAX_SPARKS  = 300;
const VOXEL_SIZE  = 1;

const MAT_GRASS   = 1;
const MAT_DIRT    = 2;
const MAT_STONE   = 3;
const MAT_GRAVEL  = 4;
const MAT_BEDROCK = 5;

const VOXEL_COLORS: Record<number, THREE.Color> = {
  [MAT_GRASS]:   new THREE.Color(0x4caf50),
  [MAT_DIRT]:    new THREE.Color(0x8d5524),
  [MAT_STONE]:   new THREE.Color(0x9e9e9e),
  [MAT_GRAVEL]:  new THREE.Color(0x78909c),
  [MAT_BEDROCK]: new THREE.Color(0x455a64),
};

// ── WEAPONS CONFIG ───────────────────────────────────────────────
interface WeaponDef {
  radius: number;
  delay: number;
  speed: number;
  color: number;
  sparksPerVoxel: number;
  debrisPerVoxel: number;
  shake: number;
  isLaser?: boolean;
  isNuke?: boolean;
  subCount?: number;
  gravityAffected?: boolean;
}

const WEAPONS: Record<string, WeaponDef> = {
  cannon:  { radius: 3,  delay: 0,    speed: 28, color: 0xaaaaaa, sparksPerVoxel: 3,  debrisPerVoxel: 4,  shake: 0.4 },
  bomb:    { radius: 6,  delay: 1200, speed: 10, color: 0xff5500, sparksPerVoxel: 4,  debrisPerVoxel: 6,  shake: 1.2, gravityAffected: true },
  laser:   { radius: 1,  delay: 0,    speed: 60, color: 0xff0000, sparksPerVoxel: 2,  debrisPerVoxel: 2,  shake: 0.1, isLaser: true },
  cluster: { radius: 2,  delay: 0,    speed: 22, color: 0xffcc00, sparksPerVoxel: 3,  debrisPerVoxel: 4,  shake: 0.6, subCount: 5 },
  nuke:    { radius: 13, delay: 800,  speed: 7,  color: 0x00ffcc, sparksPerVoxel: 6,  debrisPerVoxel: 10, shake: 3.0, isNuke: true },
};

const WEAPON_META: Record<string, { icon: string; name: string; info: string }> = {
  cannon:  { icon: '💣', name: 'CANNON',  info: 'R=3  Fast'    },
  bomb:    { icon: '💥', name: 'BOMB',    info: 'R=6  Arcing'  },
  laser:   { icon: '🔴', name: 'LASER',   info: 'Hold to drill'},
  cluster: { icon: '🌟', name: 'CLUSTER', info: 'R=2×5 Multi'  },
  nuke:    { icon: '☢️', name: 'NUKE',    info: 'R=13 KABOOM'  },
};

// ── TYPES ────────────────────────────────────────────────────────
interface DebrisPiece {
  x: number; y: number; z: number;
  vx: number; vy: number; vz: number;
  rx: number; ry: number; rz: number;
  angVx: number; angVy: number; angVz: number;
  life: number; maxLife: number;
  r: number; g: number; b: number;
  active: boolean;
}

interface SparkParticle {
  x: number; y: number; z: number;
  vx: number; vy: number; vz: number;
  life: number; maxLife: number;
  r: number; g: number; b: number;
  scale: number;
  active: boolean;
}

interface Projectile {
  mesh: THREE.Object3D;
  dir: THREE.Vector3;
  speed: number;
  target: THREE.Vector3;
  weaponKey: string;
  exploded: boolean;
  startDist: number;
  travelDist: number;
  animLight?: THREE.PointLight;
  gravityAffected?: boolean;
}

// ── GRID HELPERS ─────────────────────────────────────────────────
function gIdx(x: number, y: number, z: number) { return x + GRID_W * (y + GRID_H * z); }
function inBounds(x: number, y: number, z: number) {
  return x >= 0 && x < GRID_W && y >= 0 && y < GRID_H && z >= 0 && z < GRID_D;
}

// ── NOISE HELPERS ────────────────────────────────────────────────
function hash(n: number) { const x = Math.sin(n) * 43758.5453123; return x - Math.floor(x); }
function noise2(x: number, z: number) {
  const ix = Math.floor(x), iz = Math.floor(z);
  const fx = x - ix, fz = z - iz;
  const ux = fx * fx * (3 - 2 * fx), uz = fz * fz * (3 - 2 * fz);
  const a = hash(ix + iz * 57), b = hash(ix+1 + iz * 57);
  const c = hash(ix + (iz+1) * 57), d = hash(ix+1 + (iz+1) * 57);
  return a + (b-a)*ux + (c-a)*uz + (d-b+a-c)*ux*uz;
}
function fbm(x: number, z: number) {
  return noise2(x*0.08,z*0.08)*0.55 + noise2(x*0.2,z*0.2)*0.28
       + noise2(x*0.5,z*0.5)*0.12  + noise2(x*1.2,z*1.2)*0.05;
}

// ═══════════════════════════════════════════════════════════════
//  REACT COMPONENT
// ═══════════════════════════════════════════════════════════════
export default function App() {
  const canvasRef       = useRef<HTMLCanvasElement>(null);
  const flashRef        = useRef<HTMLDivElement>(null);
  const counterValueRef = useRef<HTMLSpanElement>(null);

  const [destroyCount, setDestroyCount] = useState(0);
  const [currentWeapon, setCurrentWeapon] = useState('cannon');
  const [statusText, setStatusText] = useState(
    'Tap/click terrain to fire • Drag to rotate • Pinch to zoom • 1-5: weapons • R: restart'
  );

  const currentWeaponRef  = useRef('cannon');
  const destroyCountRef   = useRef(0);

  const syncWeapon = useCallback((key: string) => {
    currentWeaponRef.current = key;
    setCurrentWeapon(key);
  }, []);

  useEffect(() => {
    // ── MUTABLE GAME STATE ───────────────────────────────────────
    const voxelState     = new Uint8Array(MAX_VOXELS);
    const instanceToGrid = new Int32Array(MAX_VOXELS);
    const gridToInstance = new Int32Array(MAX_VOXELS).fill(-1);
    let instanceCount    = 0;

    let activeProjectiles: Projectile[] = [];

    // Debris pool
    const debrisPool: DebrisPiece[] = Array.from({ length: MAX_DEBRIS }, () => ({
      x:0,y:0,z:0, vx:0,vy:0,vz:0, rx:0,ry:0,rz:0,
      angVx:0,angVy:0,angVz:0, life:0,maxLife:1, r:1,g:1,b:1, active:false
    }));

    // Spark pool
    const sparkPool: SparkParticle[] = Array.from({ length: MAX_SPARKS }, () => ({
      x:0,y:0,z:0, vx:0,vy:0,vz:0, life:0,maxLife:1, r:1,g:1,b:1, scale:0.1, active:false
    }));

    let laserBeam: THREE.Line | null   = null;
    let laserHitLight: THREE.PointLight | null = null;
    let laserHitMarker: THREE.Group | null = null;
    let cameraShake = 0, shakeDecay = 0;
    const dummy  = new THREE.Object3D();
    const dummy2 = new THREE.Object3D();
    const dummy3 = new THREE.Object3D();
    const pointer    = new THREE.Vector2();
    const raycaster  = new THREE.Raycaster();

    // Multi-touch / pointer tracking
    const activePointers = new Set<number>();
    let firingPointerId  = -1;
    let isPointerDown    = false;
    let didDrag          = false;
    let pointerDownPos   = { x: 0, y: 0 };
    let currentMousePos  = { x: 0, y: 0 };
    let isLaserFiring    = false;
    let lastLaserFireTime = 0;
    let animFrameId: number;

    // Scene objects
    let scene: THREE.Scene;
    let camera: THREE.PerspectiveCamera;
    let renderer: THREE.WebGLRenderer;
    let controls: OrbitControls;
    let terrainMesh: THREE.InstancedMesh;
    let debrisMesh: THREE.InstancedMesh;
    let sparkMesh: THREE.InstancedMesh;
    let clock: THREE.Clock;

    // ── TERRAIN ──────────────────────────────────────────────────
    function buildTerrain() {
      voxelState.fill(0);
      gridToInstance.fill(-1);
      instanceCount = 0;

      for (let x = 0; x < GRID_W; x++) {
        for (let z = 0; z < GRID_D; z++) {
          const n = fbm(x, z);
          const h = Math.floor(3 + n * (GRID_H - 5));
          for (let y = 0; y <= h; y++) {
            let mat: number;
            if      (y === h)    mat = MAT_GRASS;
            else if (y >= h-2)   mat = MAT_DIRT;
            else if (y >= h-6)   mat = MAT_STONE;
            else if (y >= 1)     mat = MAT_GRAVEL;
            else                 mat = MAT_BEDROCK;
            voxelState[gIdx(x, y, z)] = mat;
          }
        }
      }
      for (let x = 0; x < GRID_W; x++) {
        for (let y = 0; y < GRID_H; y++) {
          for (let z = 0; z < GRID_D; z++) {
            const g = gIdx(x, y, z);
            if (!voxelState[g]) continue;
            const i = instanceCount++;
            instanceToGrid[i] = g;
            gridToInstance[g] = i;
            dummy.position.set(x, y, z);
            dummy.updateMatrix();
            terrainMesh.setMatrixAt(i, dummy.matrix);
            terrainMesh.setColorAt(i, VOXEL_COLORS[voxelState[g]]);
          }
        }
      }
      terrainMesh.count = instanceCount;
      terrainMesh.instanceMatrix.needsUpdate = true;
      if (terrainMesh.instanceColor) terrainMesh.instanceColor.needsUpdate = true;
    }

    function hideVoxel(gridIdx: number) {
      const inst = gridToInstance[gridIdx];
      if (inst < 0) return;
      const last = instanceCount - 1;
      if (inst !== last) {
        const lastGrid = instanceToGrid[last];
        terrainMesh.getMatrixAt(last, dummy.matrix);
        terrainMesh.setMatrixAt(inst, dummy.matrix);
        const c = new THREE.Color();
        terrainMesh.getColorAt(last, c);
        terrainMesh.setColorAt(inst, c);
        instanceToGrid[inst] = lastGrid;
        gridToInstance[lastGrid] = inst;
      }
      gridToInstance[gridIdx] = -1;
      instanceCount--;
      terrainMesh.count = instanceCount;
    }

    // ── DEBRIS SYSTEM ────────────────────────────────────────────
    function spawnDebris(
      wx: number, wy: number, wz: number,
      color: THREE.Color,
      blastCx: number, blastCy: number, blastCz: number,
      count: number
    ) {
      let spawned = 0;
      const bx = wx - blastCx, bz = wz - blastCz;
      const blen = Math.sqrt(bx*bx + bz*bz) || 1;
      const ndx = bx/blen, ndz = bz/blen;

      for (let i = 0; i < MAX_DEBRIS && spawned < count; i++) {
        if (debrisPool[i].active) continue;
        const d = debrisPool[i];
        d.active = true;
        d.x = wx; d.y = wy; d.z = wz;
        d.vx = (Math.random()-0.5)*16 + ndx*9;
        d.vy = Math.random()*14 + 5;
        d.vz = (Math.random()-0.5)*16 + ndz*9;
        d.rx = Math.random()*Math.PI*2;
        d.ry = Math.random()*Math.PI*2;
        d.rz = Math.random()*Math.PI*2;
        d.angVx = (Math.random()-0.5)*14;
        d.angVy = (Math.random()-0.5)*14;
        d.angVz = (Math.random()-0.5)*14;
        d.life = 3.0 + Math.random()*1.5;
        d.maxLife = d.life;
        d.r = color.r; d.g = color.g; d.b = color.b;
        spawned++;
      }
    }

    function updateDebris(dt: number) {
      const gravity = 22;
      const tmpColor = new THREE.Color();
      for (let i = 0; i < MAX_DEBRIS; i++) {
        const d = debrisPool[i];
        if (!d.active) {
          dummy2.scale.setScalar(0);
          dummy2.position.set(0, -999, 0);
          dummy2.updateMatrix();
          debrisMesh.setMatrixAt(i, dummy2.matrix);
          continue;
        }
        d.vy -= gravity * dt;
        d.x  += d.vx * dt;
        d.y  += d.vy * dt;
        d.z  += d.vz * dt;
        d.rx += d.angVx * dt;
        d.ry += d.angVy * dt;
        d.rz += d.angVz * dt;
        d.life -= dt;

        if (d.y < 0.45 && d.vy < -1) {
          d.y = 0.45;
          d.vy *= -0.32;
          d.vx *= 0.65;
          d.vz *= 0.65;
          d.angVx *= 0.7;
          d.angVz *= 0.7;
        }

        if (d.life <= 0) {
          d.active = false;
          dummy2.scale.setScalar(0);
          dummy2.position.set(0, -999, 0);
          dummy2.updateMatrix();
          debrisMesh.setMatrixAt(i, dummy2.matrix);
          continue;
        }

        const fadeT = Math.min(d.life / 0.6, 1.0);
        dummy2.position.set(d.x, d.y, d.z);
        dummy2.rotation.set(d.rx, d.ry, d.rz);
        dummy2.scale.setScalar(fadeT);
        dummy2.updateMatrix();
        debrisMesh.setMatrixAt(i, dummy2.matrix);

        const bright = 0.5 + (d.life / d.maxLife) * 0.5;
        tmpColor.setRGB(d.r * bright, d.g * bright, d.b * bright);
        debrisMesh.setColorAt(i, tmpColor);
      }
      debrisMesh.instanceMatrix.needsUpdate = true;
      if (debrisMesh.instanceColor) debrisMesh.instanceColor.needsUpdate = true;
    }

    // ── SPARK SYSTEM ─────────────────────────────────────────────
    function spawnSparks(wx: number, wy: number, wz: number, color: THREE.Color, count: number) {
      let spawned = 0;
      for (let i = 0; i < MAX_SPARKS && spawned < count; i++) {
        if (sparkPool[i].active) continue;
        const p = sparkPool[i];
        p.active = true;
        p.x = wx; p.y = wy; p.z = wz;
        p.vx = (Math.random()-0.5)*10;
        p.vy = Math.random()*7 + 2;
        p.vz = (Math.random()-0.5)*10;
        p.life = 0.5 + Math.random()*0.4;
        p.maxLife = p.life;
        p.r = color.r; p.g = color.g; p.b = color.b;
        p.scale = 0.08 + Math.random()*0.1;
        spawned++;
      }
    }

    function updateSparks(dt: number) {
      const gravity = 18;
      const tmpColor = new THREE.Color();
      for (let i = 0; i < MAX_SPARKS; i++) {
        const p = sparkPool[i];
        if (!p.active) {
          dummy3.scale.setScalar(0);
          dummy3.position.set(0, -999, 0);
          dummy3.updateMatrix();
          sparkMesh.setMatrixAt(i, dummy3.matrix);
          continue;
        }
        p.vy -= gravity * dt;
        p.x += p.vx * dt; p.y += p.vy * dt; p.z += p.vz * dt;
        p.life -= dt;
        if (p.life <= 0 || p.y < -5) {
          p.active = false;
          dummy3.scale.setScalar(0);
          dummy3.position.set(0, -999, 0);
          dummy3.updateMatrix();
          sparkMesh.setMatrixAt(i, dummy3.matrix);
          continue;
        }
        const t = p.life / p.maxLife;
        dummy3.position.set(p.x, p.y, p.z);
        dummy3.scale.setScalar(p.scale * t);
        dummy3.updateMatrix();
        sparkMesh.setMatrixAt(i, dummy3.matrix);
        tmpColor.setRGB(p.r, p.g * t, 0.1);
        sparkMesh.setColorAt(i, tmpColor);
      }
      sparkMesh.instanceMatrix.needsUpdate = true;
      if (sparkMesh.instanceColor) sparkMesh.instanceColor.needsUpdate = true;
    }

    // ── DESTINATION MARKER ───────────────────────────────────────
    function spawnDestMarker(pos: THREE.Vector3, weaponColor: number) {
      const group = new THREE.Group();

      // Flat ring on the ground
      const ringGeo = new THREE.RingGeometry(0.4, 0.7, 32);
      const ringMat = new THREE.MeshBasicMaterial({
        color: weaponColor,
        transparent: true,
        opacity: 0.9,
        side: THREE.DoubleSide,
      });
      const ring = new THREE.Mesh(ringGeo, ringMat);
      ring.rotation.x = -Math.PI / 2;
      group.add(ring);

      // Vertical spike
      const spikeGeo = new THREE.CylinderGeometry(0.04, 0.04, 2.2, 6);
      const spikeMat = new THREE.MeshBasicMaterial({ color: weaponColor, transparent: true, opacity: 0.85 });
      const spike = new THREE.Mesh(spikeGeo, spikeMat);
      spike.position.y = 1.1;
      group.add(spike);

      // Glow light
      const light = new THREE.PointLight(weaponColor, 4, 6);
      group.add(light);

      group.position.set(pos.x, pos.y + 0.05, pos.z);
      scene.add(group);

      // Animate fade-out
      const startTime = Date.now();
      const duration = 1200;
      const tick = () => {
        const elapsed = Date.now() - startTime;
        const t = Math.max(0, 1 - elapsed / duration);
        if (t <= 0) {
          scene.remove(group);
          ringMat.dispose(); spikeMat.dispose();
          ringGeo.dispose(); spikeGeo.dispose();
          return;
        }
        ringMat.opacity = 0.9 * t;
        spikeMat.opacity = 0.85 * t;
        light.intensity = 4 * t;
        // Pulse scale
        const pulse = 1 + (1 - t) * 0.5;
        group.scale.setScalar(pulse);
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    }

    // Laser hit marker (stays while firing)
    function showLaserHitMarker(pos: THREE.Vector3) {
      if (!laserHitMarker) {
        const group = new THREE.Group();
        const ringGeo = new THREE.RingGeometry(0.3, 0.55, 24);
        const ringMat = new THREE.MeshBasicMaterial({
          color: 0xff1111, transparent: true, opacity: 0.85, side: THREE.DoubleSide
        });
        const ring = new THREE.Mesh(ringGeo, ringMat);
        ring.rotation.x = -Math.PI / 2;
        group.add(ring);
        laserHitMarker = group;
        scene.add(group);
      }
      laserHitMarker.position.set(pos.x, pos.y + 0.05, pos.z);
      // Pulse
      const t = (Math.sin(Date.now() * 0.012) * 0.5 + 0.5);
      laserHitMarker.scale.setScalar(0.8 + t * 0.6);
    }

    function clearLaserHitMarker() {
      if (laserHitMarker) { scene.remove(laserHitMarker); laserHitMarker = null; }
    }

    // ── DESTRUCTION ──────────────────────────────────────────────
    function destroyInRadius(
      cx: number, cy: number, cz: number,
      radius: number, sparksppv: number, debrisppv: number
    ) {
      let destroyed = 0;
      const r2 = radius * radius;
      for (let x = Math.floor(cx-radius); x <= Math.ceil(cx+radius); x++) {
        for (let y = Math.floor(cy-radius); y <= Math.ceil(cy+radius); y++) {
          for (let z = Math.floor(cz-radius); z <= Math.ceil(cz+radius); z++) {
            if (!inBounds(x,y,z)) continue;
            const dx=x-cx, dy=y-cy, dz=z-cz;
            if (dx*dx+dy*dy+dz*dz > r2) continue;
            const g = gIdx(x,y,z);
            if (!voxelState[g]) continue;
            const mat = voxelState[g];
            spawnDebris(x, y, z, VOXEL_COLORS[mat], cx, cy, cz, debrisppv);
            spawnSparks(x, y, z, VOXEL_COLORS[mat], sparksppv);
            voxelState[g] = 0;
            hideVoxel(g);
            destroyed++;
          }
        }
      }
      terrainMesh.instanceMatrix.needsUpdate = true;
      if (terrainMesh.instanceColor) terrainMesh.instanceColor.needsUpdate = true;
      return destroyed;
    }

    function destroyLaserColumn(
      cx: number, cy: number, cz: number,
      dirX: number, dirY: number, dirZ: number,
      sparksppv: number, debrisppv: number
    ) {
      let destroyed = 0;
      const steps = 40;
      for (let t = 0; t < steps; t++) {
        const x = Math.round(cx + dirX * t);
        const y = Math.round(cy + dirY * t);
        const z = Math.round(cz + dirZ * t);
        if (!inBounds(x,y,z)) break;
        const g = gIdx(x,y,z);
        if (voxelState[g]) {
          const mat = voxelState[g];
          spawnDebris(x, y, z, VOXEL_COLORS[mat], cx, cy, cz, debrisppv);
          spawnSparks(x, y, z, VOXEL_COLORS[mat], sparksppv);
          voxelState[g] = 0;
          hideVoxel(g);
          destroyed++;
        }
      }
      terrainMesh.instanceMatrix.needsUpdate = true;
      if (terrainMesh.instanceColor) terrainMesh.instanceColor.needsUpdate = true;
      return destroyed;
    }

    // ── WEAPON MODELS ────────────────────────────────────────────
    function buildCannonball(): { obj: THREE.Object3D; animLight?: THREE.PointLight } {
      const geo = new THREE.SphereGeometry(0.4, 10, 8);
      const mat = new THREE.MeshStandardMaterial({ color: 0x222222, metalness: 0.95, roughness: 0.15 });
      const mesh = new THREE.Mesh(geo, mat);
      const light = new THREE.PointLight(0x888888, 1.2, 5);
      mesh.add(light);
      return { obj: mesh, animLight: light };
    }

    function buildBomb(): { obj: THREE.Object3D; animLight?: THREE.PointLight } {
      const group = new THREE.Group();
      const bodyGeo = new THREE.SphereGeometry(0.5, 10, 8);
      const bodyMat = new THREE.MeshStandardMaterial({ color: 0x111111, metalness: 0.7, roughness: 0.4 });
      group.add(new THREE.Mesh(bodyGeo, bodyMat));
      const fuseGeo = new THREE.CylinderGeometry(0.03, 0.03, 0.45, 5);
      const fuseMat = new THREE.MeshStandardMaterial({ color: 0x8B4513 });
      const fuse = new THREE.Mesh(fuseGeo, fuseMat);
      fuse.position.set(0.1, 0.55, 0);
      fuse.rotation.z = 0.4;
      group.add(fuse);
      const tipGeo = new THREE.SphereGeometry(0.07, 4, 4);
      const tipMat = new THREE.MeshStandardMaterial({ color: 0xffcc00, emissive: 0xffaa00, emissiveIntensity: 2 });
      const tip = new THREE.Mesh(tipGeo, tipMat);
      tip.position.set(0.22, 0.78, 0);
      group.add(tip);
      const light = new THREE.PointLight(0xff6600, 2.5, 6);
      light.position.set(0.22, 0.78, 0);
      group.add(light);
      return { obj: group, animLight: light };
    }

    function buildCluster(): { obj: THREE.Object3D; animLight?: THREE.PointLight } {
      const group = new THREE.Group();
      const mainGeo = new THREE.SphereGeometry(0.35, 8, 6);
      const mainMat = new THREE.MeshStandardMaterial({
        color: 0xffaa00, emissive: 0xffaa00, emissiveIntensity: 1.2,
        metalness: 0.3, roughness: 0.4
      });
      group.add(new THREE.Mesh(mainGeo, mainMat));
      const subMat = new THREE.MeshStandardMaterial({ color: 0xff5500, emissive: 0xff3300, emissiveIntensity: 0.8 });
      for (let i = 0; i < 4; i++) {
        const subGeo = new THREE.SphereGeometry(0.13, 5, 4);
        const sub = new THREE.Mesh(subGeo, subMat);
        const angle = (i / 4) * Math.PI * 2;
        sub.position.set(Math.cos(angle)*0.42, 0, Math.sin(angle)*0.42);
        group.add(sub);
      }
      const light = new THREE.PointLight(0xffaa00, 2, 6);
      group.add(light);
      return { obj: group, animLight: light };
    }

    function buildNuke(): { obj: THREE.Object3D; animLight?: THREE.PointLight } {
      const group = new THREE.Group();
      const bodyGeo = new THREE.CylinderGeometry(0.16, 0.22, 1.3, 8);
      const bodyMat = new THREE.MeshStandardMaterial({ color: 0x778899, metalness: 0.85, roughness: 0.2 });
      group.add(new THREE.Mesh(bodyGeo, bodyMat));
      const noseGeo = new THREE.ConeGeometry(0.16, 0.55, 8);
      const noseMat = new THREE.MeshStandardMaterial({ color: 0xcc2222, metalness: 0.7, roughness: 0.3 });
      const nose = new THREE.Mesh(noseGeo, noseMat);
      nose.position.y = 0.92;
      group.add(nose);
      const finMat = new THREE.MeshStandardMaterial({ color: 0x556677, metalness: 0.8 });
      for (let i = 0; i < 3; i++) {
        const finGeo = new THREE.BoxGeometry(0.06, 0.35, 0.45);
        const fin = new THREE.Mesh(finGeo, finMat);
        const angle = (i / 3) * Math.PI * 2;
        fin.position.set(Math.cos(angle)*0.22, -0.55, Math.sin(angle)*0.22);
        fin.rotation.y = angle;
        group.add(fin);
      }
      const engineLight = new THREE.PointLight(0x00ffcc, 4, 10);
      engineLight.position.y = -0.8;
      group.add(engineLight);
      const exhaustGeo = new THREE.ConeGeometry(0.14, 0.4, 8);
      const exhaustMat = new THREE.MeshStandardMaterial({
        color: 0x00ffcc, emissive: 0x00ffcc, emissiveIntensity: 2, transparent: true, opacity: 0.7
      });
      const exhaust = new THREE.Mesh(exhaustGeo, exhaustMat);
      exhaust.rotation.x = Math.PI;
      exhaust.position.y = -0.9;
      group.add(exhaust);
      return { obj: group, animLight: engineLight };
    }

    function createProjectileObject(weaponKey: string): { obj: THREE.Object3D; animLight?: THREE.PointLight } {
      switch (weaponKey) {
        case 'cannon':  return buildCannonball();
        case 'bomb':    return buildBomb();
        case 'cluster': return buildCluster();
        case 'nuke':    return buildNuke();
        default: {
          const geo = new THREE.SphereGeometry(0.3, 6, 6);
          const mat = new THREE.MeshStandardMaterial({ color: WEAPONS[weaponKey]?.color ?? 0xffffff });
          return { obj: new THREE.Mesh(geo, mat) };
        }
      }
    }

    function addProjectile(startPos: THREE.Vector3, targetPos: THREE.Vector3, weaponKey: string) {
      const def = WEAPONS[weaponKey];
      const dir = targetPos.clone().sub(startPos).normalize();
      const { obj, animLight } = createProjectileObject(weaponKey);
      obj.position.copy(startPos);

      if (weaponKey === 'nuke') {
        obj.quaternion.setFromUnitVectors(new THREE.Vector3(0,1,0), dir);
      }

      scene.add(obj);
      activeProjectiles.push({
        mesh: obj, dir, speed: def.speed,
        target: targetPos.clone(),
        weaponKey, exploded: false,
        startDist: startPos.distanceTo(targetPos),
        travelDist: 0,
        animLight,
        gravityAffected: def.gravityAffected,
      });
    }

    function updateProjectiles(dt: number) {
      const now = Date.now();
      for (let i = activeProjectiles.length - 1; i >= 0; i--) {
        const p = activeProjectiles[i];
        if (p.exploded) { activeProjectiles.splice(i, 1); continue; }

        if (p.animLight) {
          if (p.weaponKey === 'bomb') {
            p.animLight.intensity = 1.8 + Math.sin(now * 0.025) * 0.7;
          } else if (p.weaponKey === 'nuke') {
            p.animLight.intensity = 3.5 + Math.sin(now * 0.015) * 1.5;
          } else if (p.weaponKey === 'cluster') {
            p.animLight.intensity = 1.5 + Math.sin(now * 0.03) * 0.5;
          }
        }

        if (p.weaponKey === 'cluster') p.mesh.rotation.z += 5 * dt;

        if (p.gravityAffected) {
          p.dir.y -= (9.8 / p.speed) * dt;
          if (p.dir.y < -0.9) p.dir.y = -0.9;
          p.dir.normalize();
        }

        if (p.weaponKey === 'nuke') {
          p.mesh.quaternion.setFromUnitVectors(new THREE.Vector3(0,1,0), p.dir);
        }

        const step = p.speed * dt;
        p.mesh.position.addScaledVector(p.dir, step);
        p.travelDist += step;

        if (p.travelDist >= p.startDist) {
          p.exploded = true;
          explodeAt(p.target, p.weaponKey);
          scene.remove(p.mesh);
          activeProjectiles.splice(i, 1);
        }
      }
    }

    function explodeAt(pos: THREE.Vector3, weaponKey: string) {
      const def = WEAPONS[weaponKey];
      const cx = Math.round(pos.x), cy = Math.round(pos.y), cz = Math.round(pos.z);
      let totalDestroyed = 0;

      if (def.isLaser) {
        const dir = pos.clone().normalize();
        totalDestroyed = destroyLaserColumn(cx, cy, cz, dir.x, dir.y, dir.z, def.sparksPerVoxel, def.debrisPerVoxel);
      } else if (def.subCount) {
        totalDestroyed += destroyInRadius(cx, cy, cz, def.radius, def.sparksPerVoxel, def.debrisPerVoxel);
        for (let s = 0; s < def.subCount; s++) {
          const ox = cx + Math.round((Math.random()-0.5)*8);
          const oy = cy + Math.round(Math.random()*3);
          const oz = cz + Math.round((Math.random()-0.5)*8);
          totalDestroyed += destroyInRadius(ox, oy, oz, def.radius, def.sparksPerVoxel, def.debrisPerVoxel);
        }
      } else {
        totalDestroyed = destroyInRadius(cx, cy, cz, def.radius, def.sparksPerVoxel, def.debrisPerVoxel);
      }

      destroyCountRef.current += totalDestroyed;
      updateCounter();
      if (def.shake > 0) triggerShake(def.shake);
      if (def.isNuke) triggerNukeFlash();

      const flashLight = new THREE.PointLight(def.color, 8, def.radius * 7);
      flashLight.position.set(cx, cy, cz);
      scene.add(flashLight);
      setTimeout(() => scene.remove(flashLight), 350);

      if (totalDestroyed > 0) showDamagePopup(totalDestroyed, weaponKey);
    }

    // ── LASER ────────────────────────────────────────────────────
    function clearLaserBeam() {
      if (laserBeam) { scene.remove(laserBeam); laserBeam = null; }
      if (laserHitLight) { scene.remove(laserHitLight); laserHitLight = null; }
      clearLaserHitMarker();
    }

    function showLaserBeam(from: THREE.Vector3, to: THREE.Vector3, hitPos: THREE.Vector3) {
      if (laserBeam) scene.remove(laserBeam);

      // Main beam line
      const points = [from.clone(), to.clone()];
      const geo = new THREE.BufferGeometry().setFromPoints(points);
      const mat = new THREE.LineBasicMaterial({ color: 0xff1111, linewidth: 3, transparent: true, opacity: 0.95 });
      laserBeam = new THREE.Line(geo, mat);
      scene.add(laserBeam);

      // Hit point glow
      if (!laserHitLight) {
        laserHitLight = new THREE.PointLight(0xff0000, 5, 10);
        scene.add(laserHitLight);
      }
      laserHitLight.position.copy(to);

      // Hit marker
      showLaserHitMarker(hitPos);
    }

    function fireLaserAt(mx: number, my: number) {
      pointer.x = (mx / renderer.domElement.clientWidth) * 2 - 1;
      pointer.y = -(my / renderer.domElement.clientHeight) * 2 + 1;
      raycaster.setFromCamera(pointer, camera);
      const hits = raycaster.intersectObject(terrainMesh);
      if (!hits.length) { clearLaserBeam(); return; }

      const hitPos = hits[0].point.clone();
      const dir = raycaster.ray.direction.clone();
      const cx = Math.round(hitPos.x), cy = Math.round(hitPos.y), cz = Math.round(hitPos.z);

      const beamEnd = hitPos.clone().addScaledVector(dir, 50);
      showLaserBeam(camera.position, beamEnd, hitPos);

      const def = WEAPONS['laser'];
      const destroyed = destroyLaserColumn(cx, cy, cz, dir.x, dir.y, dir.z, def.sparksPerVoxel, def.debrisPerVoxel);
      if (destroyed > 0) {
        destroyCountRef.current += destroyed;
        updateCounter();
        triggerShake(def.shake);
        showDamagePopup(destroyed, 'laser');
      }
    }

    // ── FIRE WEAPON ──────────────────────────────────────────────
    function fireWeapon(mx: number, my: number) {
      pointer.x = (mx / renderer.domElement.clientWidth) * 2 - 1;
      pointer.y = -(my / renderer.domElement.clientHeight) * 2 + 1;
      raycaster.setFromCamera(pointer, camera);

      const hits = raycaster.intersectObject(terrainMesh);
      if (!hits.length) return;

      const hitPos = hits[0].point.clone();
      const weaponKey = currentWeaponRef.current;

      if (weaponKey === 'laser') return; // laser handled by hold-fire

      // Show destination marker
      const def = WEAPONS[weaponKey];
      spawnDestMarker(hitPos, def.color);

      const startPos = camera.position.clone().addScaledVector(
        hitPos.clone().sub(camera.position).normalize(), 2
      );
      addProjectile(startPos, hitPos, weaponKey);
    }

    // ── HUD ──────────────────────────────────────────────────────
    function updateCounter() {
      setDestroyCount(destroyCountRef.current);
      const el = counterValueRef.current;
      if (!el) return;
      el.classList.remove('bump');
      void el.offsetWidth;
      el.classList.add('bump');
      setTimeout(() => el.classList.remove('bump'), 150);
    }

    function showDamagePopup(count: number, weaponKey: string) {
      const el = document.createElement('div');
      el.className = 'damage-popup';
      const emojis: Record<string, string> = { cannon:'💣', bomb:'💥', laser:'🔴', cluster:'🌟', nuke:'☢️' };
      el.textContent = `${emojis[weaponKey] || '💥'} -${count}`;
      el.style.left = (30 + Math.random()*40) + '%';
      el.style.top  = (30 + Math.random()*30) + '%';
      document.body.appendChild(el);
      setTimeout(() => el.remove(), 1100);
    }

    function triggerShake(intensity: number) {
      cameraShake = intensity;
      shakeDecay  = 5.0;
    }

    function triggerNukeFlash() {
      const overlay = flashRef.current;
      if (overlay) {
        overlay.classList.add('active');
        setTimeout(() => overlay.classList.remove('active'), 60);
      }
      scene.background = new THREE.Color(0xffffff);
      setTimeout(() => {
        scene.background = new THREE.Color(0x87ceeb);
        (scene.fog as THREE.FogExp2).color.set(0x87ceeb);
      }, 180);
    }

    // ── RESTART ──────────────────────────────────────────────────
    function restart() {
      activeProjectiles.forEach(p => scene.remove(p.mesh));
      activeProjectiles = [];
      clearLaserBeam();
      isLaserFiring = false;
      controls.enabled = true;
      activePointers.clear();
      firingPointerId = -1;

      debrisPool.forEach(d => { d.active = false; });
      sparkPool.forEach(s => { s.active = false; });

      destroyCountRef.current = 0;
      setDestroyCount(0);
      buildTerrain();
      setStatusText('New round started! Tap terrain to fire.');
      scene.background = new THREE.Color(0x87ceeb);
    }

    function selectWeapon(key: string) {
      if (currentWeaponRef.current === 'laser' && key !== 'laser') {
        isLaserFiring = false;
        clearLaserBeam();
        controls.enabled = true;
      }
      syncWeapon(key);
      const names: Record<string, string> = {
        cannon: 'Cannon', bomb: 'Bomb', laser: 'Laser Drill (hold to fire)',
        cluster: 'Cluster Bomb', nuke: 'NUKE ☢️'
      };
      setStatusText(`${names[key]} selected — ${key === 'laser' ? 'hold/tap & drag to aim laser' : 'tap terrain'} to fire!`);
    }

    // ── SCENE INIT ───────────────────────────────────────────────
    function initScene() {
      const canvas = canvasRef.current!;
      renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
      renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
      renderer.setSize(window.innerWidth, window.innerHeight);
      renderer.shadowMap.enabled = true;
      renderer.shadowMap.type = THREE.PCFSoftShadowMap;
      renderer.toneMapping = THREE.ACESFilmicToneMapping;
      renderer.toneMappingExposure = 1.1;

      scene = new THREE.Scene();
      scene.background = new THREE.Color(0x87ceeb);
      scene.fog = new THREE.FogExp2(0x87ceeb, 0.012);

      camera = new THREE.PerspectiveCamera(65, window.innerWidth/window.innerHeight, 0.5, 300);
      camera.position.set(GRID_W/2, 28, GRID_D*1.6);

      controls = new OrbitControls(camera, renderer.domElement);
      controls.target.set(GRID_W/2, 4, GRID_D/2);
      controls.enableDamping = true;
      controls.dampingFactor = 0.06;
      controls.minDistance = 8;
      controls.maxDistance = 140;
      controls.maxPolarAngle = Math.PI / 2.05;
      controls.mouseButtons = { LEFT: THREE.MOUSE.ROTATE, MIDDLE: THREE.MOUSE.DOLLY, RIGHT: THREE.MOUSE.PAN };
      controls.touches = { ONE: THREE.TOUCH.ROTATE, TWO: THREE.TOUCH.DOLLY_PAN };

      scene.add(new THREE.AmbientLight(0xc8d8ff, 0.6));
      const sun = new THREE.DirectionalLight(0xfff8e0, 1.4);
      sun.position.set(GRID_W*0.6, 60, GRID_D*0.4);
      sun.castShadow = true;
      sun.shadow.mapSize.set(2048,2048);
      sun.shadow.camera.left=-70; sun.shadow.camera.right=70;
      sun.shadow.camera.top=70;   sun.shadow.camera.bottom=-70;
      sun.shadow.camera.far=200;  sun.shadow.bias=-0.001;
      scene.add(sun);
      scene.add(new THREE.DirectionalLight(0x8899cc, 0.4).translateX(-GRID_W).translateY(20).translateZ(-GRID_D));
      scene.add(new THREE.HemisphereLight(0x87ceeb, 0x4a3728, 0.5));

      const groundGeo = new THREE.PlaneGeometry(GRID_W+20, GRID_D+20);
      const groundMat = new THREE.MeshStandardMaterial({ color: 0x2a1a0a, roughness: 1 });
      const ground = new THREE.Mesh(groundGeo, groundMat);
      ground.rotation.x = -Math.PI/2;
      ground.position.set(GRID_W/2, -0.5, GRID_D/2);
      ground.receiveShadow = true;
      scene.add(ground);

      const voxGeo = new THREE.BoxGeometry(VOXEL_SIZE, VOXEL_SIZE, VOXEL_SIZE);
      const voxMat = new THREE.MeshStandardMaterial({ roughness: 0.85, metalness: 0.05 });
      terrainMesh = new THREE.InstancedMesh(voxGeo, voxMat, MAX_VOXELS);
      terrainMesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
      terrainMesh.castShadow = true; terrainMesh.receiveShadow = true;
      terrainMesh.count = 0;
      scene.add(terrainMesh);

      const debrisGeo = new THREE.BoxGeometry(0.9, 0.9, 0.9);
      const debrisMat = new THREE.MeshStandardMaterial({ roughness: 0.75, metalness: 0.1 });
      debrisMesh = new THREE.InstancedMesh(debrisGeo, debrisMat, MAX_DEBRIS);
      debrisMesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
      debrisMesh.castShadow = false;
      debrisMesh.count = MAX_DEBRIS;
      scene.add(debrisMesh);

      const sparkGeo = new THREE.BoxGeometry(1, 1, 1);
      const sparkMat = new THREE.MeshStandardMaterial({ roughness: 0.5, metalness: 0.0 });
      sparkMesh = new THREE.InstancedMesh(sparkGeo, sparkMat, MAX_SPARKS);
      sparkMesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
      sparkMesh.count = MAX_SPARKS;
      scene.add(sparkMesh);

      for (let i = 0; i < MAX_DEBRIS; i++) {
        dummy2.scale.setScalar(0); dummy2.position.set(0,-999,0); dummy2.updateMatrix();
        debrisMesh.setMatrixAt(i, dummy2.matrix);
      }
      for (let i = 0; i < MAX_SPARKS; i++) {
        dummy3.scale.setScalar(0); dummy3.position.set(0,-999,0); dummy3.updateMatrix();
        sparkMesh.setMatrixAt(i, dummy3.matrix);
      }
      debrisMesh.instanceMatrix.needsUpdate = true;
      sparkMesh.instanceMatrix.needsUpdate = true;

      clock = new THREE.Clock();
    }

    // ── INPUT ────────────────────────────────────────────────────
    function initInput() {
      const canvas = renderer.domElement;

      canvas.addEventListener('pointerdown', (e) => {
        activePointers.add(e.pointerId);

        // Only handle primary single-touch as firing pointer
        if (activePointers.size > 1) {
          // Multi-touch: cancel any pending laser/fire, let OrbitControls handle
          if (isLaserFiring) {
            isLaserFiring = false;
            clearLaserBeam();
            controls.enabled = true;
          }
          isPointerDown = false;
          firingPointerId = -1;
          return;
        }

        firingPointerId = e.pointerId;
        isPointerDown = true;
        didDrag = false;
        pointerDownPos = { x: e.clientX, y: e.clientY };
        currentMousePos = { x: e.clientX, y: e.clientY };

        if (currentWeaponRef.current === 'laser') {
          isLaserFiring = true;
          // Disable orbit so mouse/finger steers the laser
          controls.enabled = false;
        }
      });

      canvas.addEventListener('pointermove', (e) => {
        // Always update mouse pos for all tracked pointers
        if (e.pointerId === firingPointerId) {
          currentMousePos = { x: e.clientX, y: e.clientY };
        }

        if (!isPointerDown || e.pointerId !== firingPointerId) return;

        const dx = e.clientX - pointerDownPos.x;
        const dy = e.clientY - pointerDownPos.y;
        const dragThreshold = e.pointerType === 'touch' ? 12 : 5;

        if (Math.sqrt(dx*dx+dy*dy) > dragThreshold) {
          didDrag = true;
          // For non-laser weapons, dragging is orbit — re-enable controls
          if (!isLaserFiring) {
            controls.enabled = true;
          }
          // For laser: keep firing, keep controls disabled (mouse aims beam)
        }
      });

      canvas.addEventListener('pointerup', (e) => {
        activePointers.delete(e.pointerId);

        if (e.pointerId !== firingPointerId) return;

        if (isLaserFiring) {
          isLaserFiring = false;
          clearLaserBeam();
          controls.enabled = true;
        } else if (!didDrag) {
          fireWeapon(e.clientX, e.clientY);
        }
        isPointerDown = false;
        didDrag = false;
        firingPointerId = -1;
        // Re-enable controls after any fire
        if (!isLaserFiring) controls.enabled = true;
      });

      canvas.addEventListener('pointercancel', (e) => {
        activePointers.delete(e.pointerId);
        if (e.pointerId === firingPointerId) {
          if (isLaserFiring) {
            isLaserFiring = false;
            clearLaserBeam();
          }
          controls.enabled = true;
          isPointerDown = false;
          didDrag = false;
          firingPointerId = -1;
        }
      });

      window.addEventListener('keydown', handleKeydown);
      window.addEventListener('resize', handleResize);
      window.addEventListener('vd-restart', handleVdRestart);
      window.addEventListener('vd-select-weapon', handleVdSelectWeapon as EventListener);
    }

    function handleKeydown(e: KeyboardEvent) {
      const map: Record<string, string> = { '1':'cannon','2':'bomb','3':'laser','4':'cluster','5':'nuke' };
      if (map[e.key]) selectWeapon(map[e.key]);
      if (e.key === 'r' || e.key === 'R') restart();
    }
    function handleResize() {
      camera.aspect = window.innerWidth / window.innerHeight;
      camera.updateProjectionMatrix();
      renderer.setSize(window.innerWidth, window.innerHeight);
    }
    function handleVdRestart() { restart(); }
    function handleVdSelectWeapon(e: CustomEvent<string>) { selectWeapon(e.detail); }

    // ── ANIMATION LOOP ───────────────────────────────────────────
    function animate() {
      animFrameId = requestAnimationFrame(animate);
      const dt = Math.min(clock.getDelta(), 0.05);
      controls.update();

      if (cameraShake > 0) {
        camera.position.x += (Math.random()-0.5)*cameraShake*0.3;
        camera.position.y += (Math.random()-0.5)*cameraShake*0.15;
        cameraShake -= shakeDecay * dt;
        if (cameraShake < 0) cameraShake = 0;
      }

      // Continuous laser firing — always fires while holding, steering with mouse/touch
      if (isLaserFiring) {
        const now = Date.now();
        if (now - lastLaserFireTime > 55) {
          lastLaserFireTime = now;
          fireLaserAt(currentMousePos.x, currentMousePos.y);
        }
      }

      updateDebris(dt);
      updateSparks(dt);
      updateProjectiles(dt);
      renderer.render(scene, camera);
    }

    // ── BOOTSTRAP ────────────────────────────────────────────────
    initScene();
    buildTerrain();
    initInput();
    animate();

    return () => {
      cancelAnimationFrame(animFrameId);
      window.removeEventListener('keydown', handleKeydown);
      window.removeEventListener('resize', handleResize);
      window.removeEventListener('vd-restart', handleVdRestart);
      window.removeEventListener('vd-select-weapon', handleVdSelectWeapon as EventListener);
      clearLaserBeam();
      controls.dispose();
      renderer.dispose();
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => { currentWeaponRef.current = currentWeapon; }, [currentWeapon]);

  return (
    <div style={{ width:'100%', height:'100%', position:'relative' }}>
      <canvas
        ref={canvasRef}
        id="game-canvas"
        style={{ position:'absolute', top:0, left:0, width:'100%', height:'100%', display:'block', touchAction:'none' }}
      />
      <div id="hud">
        <div id="top-bar">
          <span id="game-title">💥 VOXEL DESTROYER</span>
          <div id="counter-display">
            <span id="counter-label">VOXELS DESTROYED</span>
            <span id="counter-value" ref={counterValueRef}>{destroyCount.toLocaleString()}</span>
          </div>
          <button id="restart-btn" onClick={() => window.dispatchEvent(new CustomEvent('vd-restart'))}>
            🔄 NEW ROUND
          </button>
        </div>

        <div id="weapon-bar">
          <span className="weapon-label">WEAPONS</span>
          {Object.entries(WEAPON_META).map(([key, meta]) => (
            <button
              key={key}
              className={`weapon-btn${currentWeapon === key ? ' active' : ''}`}
              onClick={() => window.dispatchEvent(new CustomEvent('vd-select-weapon', { detail: key }))}
            >
              <span className="w-icon">{meta.icon}</span>
              <span className="w-name">{meta.name}</span>
              <span className="w-info">{meta.info}</span>
            </button>
          ))}
        </div>

        <div id="status-bar">
          <span id="status-text">{statusText}</span>
        </div>
        <div id="flash-overlay" ref={flashRef} />
      </div>
    </div>
  );
}
