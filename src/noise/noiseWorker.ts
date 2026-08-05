/**
 * noiseWorker.ts
 * Runs in a Web Worker — generates all 3D noise data off the main thread.
 * Returns transferable ArrayBuffers so the main thread receives them with zero copy.
 */

//  Perlin
function createPeriodic3DNoise(seed = 1) {
  const p = new Uint8Array(256);
  for (let i = 0; i < 256; i++)
    p[i] = Math.floor(Math.sin(i * 99.1 + seed * 17.3) * 128 + 128) & 255;
  const perm = new Uint8Array(512);
  for (let i = 0; i < 512; i++) perm[i] = p[i & 255];

  const grad3 = [
    [1, 1, 0],
    [-1, 1, 0],
    [1, -1, 0],
    [-1, -1, 0],
    [1, 0, 1],
    [-1, 0, 1],
    [1, 0, -1],
    [-1, 0, -1],
    [0, 1, 1],
    [0, -1, 1],
    [0, 1, -1],
    [0, -1, -1],
  ];
  const fade = (t: number) => t * t * t * (t * (t * 6 - 15) + 10);
  const lerp = (a: number, b: number, t: number) => a + t * (b - a);
  const grad = (hash: number, x: number, y: number, z: number) => {
    const g = grad3[hash % 12];
    return g[0] * x + g[1] * y + g[2] * z;
  };

  return function (x: number, y: number, z: number, rep: number) {
    const X0 = Math.floor(x),
      Y0 = Math.floor(y),
      Z0 = Math.floor(z);
    const fx = x - X0,
      fy = y - Y0,
      fz = z - Z0;
    const rx0 = ((X0 % rep) + rep) % rep,
      ry0 = ((Y0 % rep) + rep) % rep,
      rz0 = ((Z0 % rep) + rep) % rep;
    const rx1 = (rx0 + 1) % rep,
      ry1 = (ry0 + 1) % rep,
      rz1 = (rz0 + 1) % rep;
    const u = fade(fx),
      v = fade(fy),
      w = fade(fz);
    const n000 = grad(perm[rx0 + perm[ry0 + perm[rz0]]], fx, fy, fz);
    const n100 = grad(perm[rx1 + perm[ry0 + perm[rz0]]], fx - 1, fy, fz);
    const n010 = grad(perm[rx0 + perm[ry1 + perm[rz0]]], fx, fy - 1, fz);
    const n110 = grad(perm[rx1 + perm[ry1 + perm[rz0]]], fx - 1, fy - 1, fz);
    const n001 = grad(perm[rx0 + perm[ry0 + perm[rz1]]], fx, fy, fz - 1);
    const n101 = grad(perm[rx1 + perm[ry0 + perm[rz1]]], fx - 1, fy, fz - 1);
    const n011 = grad(perm[rx0 + perm[ry1 + perm[rz1]]], fx, fy - 1, fz - 1);
    const n111 = grad(
      perm[rx1 + perm[ry1 + perm[rz1]]],
      fx - 1,
      fy - 1,
      fz - 1,
    );
    const nx00 = lerp(n000, n100, u),
      nx10 = lerp(n010, n110, u);
    const nx01 = lerp(n001, n101, u),
      nx11 = lerp(n011, n111, u);
    return lerp(lerp(nx00, nx10, v), lerp(nx01, nx11, v), w);
  };
}

// Worley
function createPeriodic3DWorley(seed = 1) {
  function hash3(x: number, y: number, z: number) {
    let h =
      Math.sin(x * 127.1 + y * 311.7 + z * 74.7 + seed * 19.19) * 43758.5453;
    const rx = h - Math.floor(h);
    h = Math.sin(x * 269.5 + y * 183.3 + z * 246.1 + seed * 19.19) * 43758.5453;
    const ry = h - Math.floor(h);
    h = Math.sin(x * 419.2 + y * 371.9 + z * 118.5 + seed * 19.19) * 43758.5453;
    const rz = h - Math.floor(h);
    return [rx, ry, rz];
  }
  return function (u: number, v: number, w: number, frequency: number) {
    const px = u * frequency,
      py = v * frequency,
      pz = w * frequency;
    const ix = Math.floor(px),
      iy = Math.floor(py),
      iz = Math.floor(pz);
    const fx = px - ix,
      fy = py - iy,
      fz = pz - iz;
    let minDist = 1.0;
    for (let oz = -1; oz <= 1; oz++) {
      for (let oy = -1; oy <= 1; oy++) {
        for (let ox = -1; ox <= 1; ox++) {
          const cx = ix + ox,
            cy = iy + oy,
            cz = iz + oz;
          const wcx = ((cx % frequency) + frequency) % frequency;
          const wcy = ((cy % frequency) + frequency) % frequency;
          const wcz = ((cz % frequency) + frequency) % frequency;
          const pt = hash3(wcx, wcy, wcz);
          const dx = ox + pt[0] - fx,
            dy = oy + pt[1] - fy,
            dz = oz + pt[2] - fz;
          const d = Math.sqrt(dx * dx + dy * dy + dz * dz);
          if (d < minDist) minDist = d;
        }
      }
    }
    return 1.0 - minDist;
  };
}

// Seamless 2D noise (for weather map)
function seamless2D(
  perlin: Function,
  u: number,
  v: number,
  freq = 4.0,
  seedOff = 0.0,
) {
  const au = u * Math.PI * 2,
    av = v * Math.PI * 2;
  const r = freq / (Math.PI * 2);
  const nx = Math.cos(au) * r + seedOff,
    ny = Math.sin(au) * r + seedOff,
    nz = Math.cos(av) * r + seedOff * 2;
  let val = perlin(nx, ny, nz, 16) * 0.5 + 0.5;
  val += (perlin(nx * 2 + 10, ny * 2 + 10, nz * 2 + 10, 16) * 0.5 + 0.5) * 0.25;
  return Math.min(1, Math.max(0, val * 0.8));
}

// Generators
function genBase(size = 128): Uint8Array {
  const data = new Uint8Array(size * size * size * 4);
  const perlin = createPeriodic3DNoise(13);
  const w1 = createPeriodic3DWorley(29),
    w2 = createPeriodic3DWorley(53),
    w3 = createPeriodic3DWorley(97);
  let idx = 0;
  for (let z = 0; z < size; z++)
    for (let y = 0; y < size; y++)
      for (let x = 0; x < size; x++) {
        const u = x / size,
          v = y / size,
          w = z / size;
        let pFBM = perlin(u * 4, v * 4, w * 4, 4) * 0.5 + 0.5;
        pFBM += (perlin(u * 8, v * 8, w * 8, 8) * 0.5 + 0.5) * 0.25;
        const r1 = w1(u, v, w, 4),
          r2 = w2(u, v, w, 8),
          r3 = w3(u, v, w, 16);
        const wFBM = r1 * 0.625 + r2 * 0.25 + r3 * 0.125;
        let pw = Math.max(0, Math.min(1, pFBM * wFBM * 1.4));
        data[idx] = (pw * 255) | 0;
        data[idx + 1] = (r1 * 255) | 0;
        data[idx + 2] = (r2 * 255) | 0;
        data[idx + 3] = (r3 * 255) | 0;
        idx += 4;
      }
  return data;
}

function genDetail(size = 64): Uint8Array {
  const data = new Uint8Array(size * size * size * 4);
  const w1 = createPeriodic3DWorley(101),
    w2 = createPeriodic3DWorley(203);
  const w3 = createPeriodic3DWorley(307),
    w4 = createPeriodic3DWorley(409);
  let idx = 0;
  for (let z = 0; z < size; z++)
    for (let y = 0; y < size; y++)
      for (let x = 0; x < size; x++) {
        const u = x / size,
          v = y / size,
          w = z / size;
        data[idx] = (w1(u, v, w, 6) * 255) | 0;
        data[idx + 1] = (w2(u, v, w, 12) * 255) | 0;
        data[idx + 2] = (w3(u, v, w, 24) * 255) | 0;
        data[idx + 3] = (w4(u, v, w, 48) * 255) | 0;
        idx += 4;
      }
  return data;
}

function genWeather(w = 256, h = 256): Uint8Array {
  const data = new Uint8Array(w * h * 4);
  const perlin = createPeriodic3DNoise(77);
  const mix = (a: number, b: number, t: number) => a + t * (b - a);
  let idx = 0;
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const u = x / w,
        v = y / h;
      let cov = mix(
        seamless2D(perlin, u, v, 4, 0),
        seamless2D(perlin, u, v, 8, 25),
        0.35,
      );
      cov = Math.min(1, Math.max(0.15, cov));
      const type = seamless2D(perlin, u, v, 4, 50);
      const dens = seamless2D(perlin, u, v, 6, 90);
      data[idx] = (cov * 255) | 0;
      data[idx + 1] = (type * 255) | 0;
      data[idx + 2] = (dens * 255) | 0;
      data[idx + 3] = 255;
      idx += 4;
    }
  return data;
}

// Message handler
self.onmessage = () => {
  const base = genBase(128);
  const detail = genDetail(64);
  const weather = genWeather(256, 256);

  // Transfer ownership — zero-copy handoff to main thread
  (self as unknown as Worker).postMessage(
    { base: base.buffer, detail: detail.buffer, weather: weather.buffer },
    { transfer: [base.buffer, detail.buffer, weather.buffer] },
  );
};
