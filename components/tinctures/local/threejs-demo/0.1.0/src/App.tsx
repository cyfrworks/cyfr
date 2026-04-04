import { useEffect, useRef } from "react";
import * as THREE from "three";

declare const cyfr: {
  ready(): Promise<{ ok: true }>;
  mode: "shell" | "public";
  query(
    name: string,
    params?: Record<string, unknown>
  ): Promise<{ data: Record<string, unknown>[]; columns: string[]; cached: boolean }>;
  setTitle(title: string): Promise<{ ok: true }>;
  close(): Promise<{ ok: true }>;
  getContext(): Promise<{ tincture_id: string; window_id: string }>;
  on(event: string, cb: (d: unknown) => void): void;
  off(event: string, cb: (d: unknown) => void): void;
};

// ── Grid config ────────────────────────────────────────────────────────────
const GRID_COUNT = 7;          // spheres per side
const GRID_SPREAD = 10;        // total width/depth of grid
const SPHERE_RADIUS = 0.18;
const WAVE_AMPLITUDE = 0.6;
const WAVE_SPEED = 1.4;
const WAVE_FREQ = 0.55;

export default function App() {
  const mountRef = useRef<HTMLDivElement>(null);
  const fpsRef = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    const mount = mountRef.current!;

    // ── Renderer ───────────────────────────────────────────────────────────
    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setSize(window.innerWidth, window.innerHeight);
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.2;
    mount.appendChild(renderer.domElement);

    // ── Scene ──────────────────────────────────────────────────────────────
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x0a0a0f);
    scene.fog = new THREE.FogExp2(0x0a0a0f, 0.032);

    // ── Camera ─────────────────────────────────────────────────────────────
    const camera = new THREE.PerspectiveCamera(
      60,
      window.innerWidth / window.innerHeight,
      0.1,
      200
    );
    camera.position.set(0, 5, 18);
    camera.lookAt(0, 0, 0);

    // ── Lights ─────────────────────────────────────────────────────────────
    const ambient = new THREE.AmbientLight(0x1a1a3a, 1.2);
    scene.add(ambient);

    const dirLight = new THREE.DirectionalLight(0xffffff, 2.5);
    dirLight.position.set(8, 14, 6);
    dirLight.castShadow = true;
    dirLight.shadow.mapSize.set(1024, 1024);
    dirLight.shadow.camera.near = 0.5;
    dirLight.shadow.camera.far = 60;
    dirLight.shadow.camera.top = 15;
    dirLight.shadow.camera.bottom = -15;
    dirLight.shadow.camera.left = -15;
    dirLight.shadow.camera.right = 15;
    scene.add(dirLight);

    const pointA = new THREE.PointLight(0x6644ff, 6, 25);
    pointA.position.set(-5, 4, 3);
    scene.add(pointA);

    const pointB = new THREE.PointLight(0xff4466, 6, 25);
    pointB.position.set(5, -3, 4);
    scene.add(pointB);

    const pointC = new THREE.PointLight(0x44ffcc, 4, 20);
    pointC.position.set(0, -6, -5);
    scene.add(pointC);

    // ── Torus knot ─────────────────────────────────────────────────────────
    const knotGeo = new THREE.TorusKnotGeometry(2.2, 0.65, 180, 24, 2, 3);
    const knotMat = new THREE.MeshStandardMaterial({
      color: 0x8866ff,
      metalness: 0.85,
      roughness: 0.12,
      envMapIntensity: 1.0,
    });
    const knot = new THREE.Mesh(knotGeo, knotMat);
    knot.castShadow = true;
    knot.receiveShadow = false;
    scene.add(knot);

    // ── Icosahedron wireframe orbiter ──────────────────────────────────────
    const icoGeo = new THREE.IcosahedronGeometry(4.5, 1);
    const icoMat = new THREE.MeshBasicMaterial({
      color: 0x44ccff,
      wireframe: true,
      transparent: true,
      opacity: 0.35,
    });
    const ico = new THREE.Mesh(icoGeo, icoMat);
    scene.add(ico);

    // ── Sphere grid ────────────────────────────────────────────────────────
    const sphereGeo = new THREE.SphereGeometry(SPHERE_RADIUS, 14, 14);
    const sphereMeshes: THREE.Mesh[] = [];
    const sphereMaterials: THREE.MeshStandardMaterial[] = [];

    for (let ix = 0; ix < GRID_COUNT; ix++) {
      for (let iz = 0; iz < GRID_COUNT; iz++) {
        const t = (ix * GRID_COUNT + iz) / (GRID_COUNT * GRID_COUNT);
        const hue = t * 0.75 + 0.55;           // blue → purple → magenta
        const color = new THREE.Color().setHSL(hue, 0.9, 0.6);

        const mat = new THREE.MeshStandardMaterial({
          color,
          metalness: 0.4,
          roughness: 0.3,
          emissive: color,
          emissiveIntensity: 0.25,
        });
        sphereMaterials.push(mat);

        const mesh = new THREE.Mesh(sphereGeo, mat);
        const x = (ix / (GRID_COUNT - 1) - 0.5) * GRID_SPREAD;
        const z = (iz / (GRID_COUNT - 1) - 0.5) * GRID_SPREAD;
        mesh.position.set(x, -4, z);
        mesh.castShadow = true;
        mesh.receiveShadow = true;
        scene.add(mesh);
        sphereMeshes.push(mesh);
      }
    }

    // ── FPS tracking ───────────────────────────────────────────────────────
    let frameCount = 0;
    let fpsLastTime = performance.now();
    let fps = 0;

    // ── Animation loop ─────────────────────────────────────────────────────
    let rafId: number;
    const clock = new THREE.Clock();

    function animate() {
      rafId = requestAnimationFrame(animate);
      const elapsed = clock.getElapsedTime();

      // Torus knot — dual-axis rotation
      knot.rotation.x = elapsed * 0.38;
      knot.rotation.y = elapsed * 0.55;

      // Icosahedron — slow orbit + counter-roll
      ico.rotation.x = elapsed * 0.12;
      ico.rotation.y = elapsed * 0.18;
      ico.rotation.z = elapsed * 0.09;

      // Sphere wave
      for (let ix = 0; ix < GRID_COUNT; ix++) {
        for (let iz = 0; iz < GRID_COUNT; iz++) {
          const mesh = sphereMeshes[ix * GRID_COUNT + iz];
          const x = mesh.position.x;
          const z = mesh.position.z;
          const dist = Math.sqrt(x * x + z * z);
          mesh.position.y =
            -4 +
            Math.sin(elapsed * WAVE_SPEED - dist * WAVE_FREQ) * WAVE_AMPLITUDE;

          // Pulse emissive brightness
          const mat = sphereMaterials[ix * GRID_COUNT + iz];
          mat.emissiveIntensity =
            0.15 + 0.35 * (0.5 + 0.5 * Math.sin(elapsed * WAVE_SPEED - dist * WAVE_FREQ));
        }
      }

      // Orbit point lights for dynamic colour wash
      pointA.position.x = Math.cos(elapsed * 0.7) * 7;
      pointA.position.z = Math.sin(elapsed * 0.7) * 7;
      pointB.position.x = Math.cos(elapsed * 0.5 + Math.PI) * 7;
      pointB.position.z = Math.sin(elapsed * 0.5 + Math.PI) * 7;

      // Camera gentle bob
      camera.position.y = 5 + Math.sin(elapsed * 0.22) * 0.8;
      camera.lookAt(0, 0, 0);

      renderer.render(scene, camera);

      // FPS counter
      frameCount++;
      const now = performance.now();
      if (now - fpsLastTime >= 500) {
        fps = Math.round((frameCount * 1000) / (now - fpsLastTime));
        frameCount = 0;
        fpsLastTime = now;
        if (fpsRef.current) fpsRef.current.textContent = `${fps} FPS`;
      }
    }

    animate();

    // ── Resize handler ─────────────────────────────────────────────────────
    function onResize() {
      const w = window.innerWidth;
      const h = window.innerHeight;
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
      renderer.setSize(w, h);
    }
    window.addEventListener("resize", onResize);

    // ── Signal ready ───────────────────────────────────────────────────────
    cyfr.ready();

    // ── Cleanup ────────────────────────────────────────────────────────────
    return () => {
      cancelAnimationFrame(rafId);
      window.removeEventListener("resize", onResize);
      renderer.dispose();
      knotGeo.dispose();
      knotMat.dispose();
      icoGeo.dispose();
      icoMat.dispose();
      sphereGeo.dispose();
      sphereMaterials.forEach((m) => m.dispose());
      if (mount.contains(renderer.domElement)) {
        mount.removeChild(renderer.domElement);
      }
    };
  }, []);

  return (
    <div style={{ position: "relative", width: "100vw", height: "100vh", overflow: "hidden" }}>
      {/* Three.js canvas mount point */}
      <div
        ref={mountRef}
        style={{ position: "absolute", inset: 0 }}
      />

      {/* HUD overlay */}
      <div
        style={{
          position: "absolute",
          top: 16,
          left: 16,
          color: "rgba(200, 190, 255, 0.9)",
          fontFamily: "'SF Mono', 'Fira Code', 'Consolas', monospace",
          fontSize: 13,
          lineHeight: 1.6,
          pointerEvents: "none",
          userSelect: "none",
          textShadow: "0 0 12px rgba(120, 80, 255, 0.8)",
        }}
      >
        <div
          style={{
            fontSize: 17,
            fontWeight: 700,
            letterSpacing: "0.08em",
            textTransform: "uppercase",
            color: "rgba(180, 160, 255, 1)",
            marginBottom: 4,
          }}
        >
          three.js demo
        </div>
        <div style={{ opacity: 0.75 }}>
          torus knot · wireframe orbiter · sphere grid
        </div>
        <div style={{ marginTop: 6, color: "rgba(100, 255, 180, 0.9)" }}>
          <span ref={fpsRef}>— FPS</span>
        </div>
      </div>
    </div>
  );
}
