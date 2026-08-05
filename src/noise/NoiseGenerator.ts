import * as THREE from 'three';

// Linear Interpolation Helper for JS/TS
function mix(a: number, b: number, t: number): number {
  return a + t * (b - a);
}

// 100% Periodic 3D Perlin Noise Generator (Seamless Tiling in X, Y, Z)
function createPeriodic3DNoise(seed = 1) {
  const p = new Uint8Array(256);
  for (let i = 0; i < 256; i++) p[i] = Math.floor(Math.sin(i * 99.1 + seed * 17.3) * 128 + 128) & 255;
  const perm = new Uint8Array(512);
  for (let i = 0; i < 512; i++) perm[i] = p[i & 255];

  const grad3 = [
    [1, 1, 0], [-1, 1, 0], [1, -1, 0], [-1, -1, 0],
    [1, 0, 1], [-1, 0, 1], [1, 0, -1], [-1, 0, -1],
    [0, 1, 1], [0, -1, 1], [0, 1, -1], [0, -1, -1]
  ];

  function fade(t: number) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }
  function lerp(a: number, b: number, t: number) { return a + t * (b - a); }
  function grad(hash: number, x: number, y: number, z: number) {
    const g = grad3[hash % 12];
    return g[0] * x + g[1] * y + g[2] * z;
  }

  return function periodicPerlin3D(x: number, y: number, z: number, rep: number) {
    const X0 = Math.floor(x), Y0 = Math.floor(y), Z0 = Math.floor(z);
    const fx = x - X0, fy = y - Y0, fz = z - Z0;

    const rx0 = ((X0 % rep) + rep) % rep;
    const ry0 = ((Y0 % rep) + rep) % rep;
    const rz0 = ((Z0 % rep) + rep) % rep;

    const rx1 = (rx0 + 1) % rep;
    const ry1 = (ry0 + 1) % rep;
    const rz1 = (rz0 + 1) % rep;

    const u = fade(fx), v = fade(fy), w = fade(fz);

    const n000 = grad(perm[rx0 + perm[ry0 + perm[rz0]]], fx, fy, fz);
    const n100 = grad(perm[rx1 + perm[ry0 + perm[rz0]]], fx - 1.0, fy, fz);
    const n010 = grad(perm[rx0 + perm[ry1 + perm[rz0]]], fx, fy - 1.0, fz);
    const n110 = grad(perm[rx1 + perm[ry1 + perm[rz0]]], fx - 1.0, fy - 1.0, fz);
    const n001 = grad(perm[rx0 + perm[ry0 + perm[rz1]]], fx, fy, fz - 1.0);
    const n101 = grad(perm[rx1 + perm[ry0 + perm[rz1]]], fx - 1.0, fy, fz - 1.0);
    const n011 = grad(perm[rx0 + perm[ry1 + perm[rz1]]], fx, fy - 1.0, fz - 1.0);
    const n111 = grad(perm[rx1 + perm[ry1 + perm[rz1]]], fx - 1.0, fy - 1.0, fz - 1.0);

    const nx00 = lerp(n000, n100, u);
    const nx10 = lerp(n010, n110, u);
    const nx01 = lerp(n001, n101, u);
    const nx11 = lerp(n011, n111, u);

    const nxy0 = lerp(nx00, nx10, v);
    const nxy1 = lerp(nx01, nx11, v);

    return lerp(nxy0, nxy1, w);
  };
}

// 100% Periodic 3D Worley Noise Generator
function createPeriodic3DWorley(seed = 1) {
  function hash3(x: number, y: number, z: number) {
    let h = Math.sin(x * 127.1 + y * 311.7 + z * 74.7 + seed * 19.19) * 43758.5453;
    let rx = h - Math.floor(h);
    h = Math.sin(x * 269.5 + y * 183.3 + z * 246.1 + seed * 19.19) * 43758.5453;
    let ry = h - Math.floor(h);
    h = Math.sin(x * 419.2 + y * 371.9 + z * 118.5 + seed * 19.19) * 43758.5453;
    let rz = h - Math.floor(h);
    return [rx, ry, rz];
  }

  return function periodicWorley3D(u: number, v: number, w: number, frequency: number) {
    const px = u * frequency;
    const py = v * frequency;
    const pz = w * frequency;

    const ix = Math.floor(px);
    const iy = Math.floor(py);
    const iz = Math.floor(pz);

    const fx = px - ix;
    const fy = py - iy;
    const fz = pz - iz;

    let minDist = 1.0;

    for (let offsetZ = -1; offsetZ <= 1; offsetZ++) {
      for (let offsetY = -1; offsetY <= 1; offsetY++) {
        for (let offsetX = -1; offsetX <= 1; offsetX++) {
          const cx = ix + offsetX;
          const cy = iy + offsetY;
          const cz = iz + offsetZ;

          const wcx = ((cx % frequency) + frequency) % frequency;
          const wcy = ((cy % frequency) + frequency) % frequency;
          const wcz = ((cz % frequency) + frequency) % frequency;

          const point = hash3(wcx, wcy, wcz);

          const dx = offsetX + point[0] - fx;
          const dy = offsetY + point[1] - fy;
          const dz = offsetZ + point[2] - fz;

          const dist = Math.sqrt(dx * dx + dy * dy + dz * dz);
          if (dist < minDist) {
            minDist = dist;
          }
        }
      }
    }

    return 1.0 - minDist;
  };
}

// Generate 128x128x128 3D Base Noise Texture
export function generateBaseNoiseTexture(size = 128): THREE.Data3DTexture {
  const data = new Uint8Array(size * size * size * 4);
  const perlin = createPeriodic3DNoise(13);
  const worley1 = createPeriodic3DWorley(29);
  const worley2 = createPeriodic3DWorley(53);
  const worley3 = createPeriodic3DWorley(97);

  let idx = 0;
  for (let z = 0; z < size; z++) {
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        const u = x / size;
        const v = y / size;
        const w = z / size;

        let pFBM = perlin(u * 4, v * 4, w * 4, 4) * 0.5 + 0.5;
        pFBM += (perlin(u * 8, v * 8, w * 8, 8) * 0.5 + 0.5) * 0.25;

        const w1 = worley1(u, v, w, 4);
        const w2 = worley2(u, v, w, 8);
        const w3 = worley3(u, v, w, 16);

        const wFBM = w1 * 0.625 + w2 * 0.25 + w3 * 0.125;

        let perlinWorley = pFBM * wFBM;
        perlinWorley = Math.max(0.0, Math.min(1.0, perlinWorley * 1.4));

        data[idx]     = Math.floor(perlinWorley * 255);
        data[idx + 1] = Math.floor(w1 * 255);
        data[idx + 2] = Math.floor(w2 * 255);
        data[idx + 3] = Math.floor(w3 * 255);

        idx += 4;
      }
    }
  }

  const texture = new THREE.Data3DTexture(data, size, size, size);
  texture.format = THREE.RGBAFormat;
  texture.type = THREE.UnsignedByteType;
  texture.minFilter = THREE.LinearFilter;
  texture.magFilter = THREE.LinearFilter;
  texture.wrapS = THREE.RepeatWrapping;
  texture.wrapT = THREE.RepeatWrapping;
  texture.wrapR = THREE.RepeatWrapping;
  texture.needsUpdate = true;

  return texture;
}

// Generate 64x64x64 3D Detail Noise Texture
export function generateDetailNoiseTexture(size = 64): THREE.Data3DTexture {
  const data = new Uint8Array(size * size * size * 4);
  const worley1 = createPeriodic3DWorley(101);
  const worley2 = createPeriodic3DWorley(203);
  const worley3 = createPeriodic3DWorley(307);
  const worley4 = createPeriodic3DWorley(409);

  let idx = 0;
  for (let z = 0; z < size; z++) {
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        const u = x / size;
        const v = y / size;
        const w = z / size;

        const w1 = worley1(u, v, w, 6);
        const w2 = worley2(u, v, w, 12);
        const w3 = worley3(u, v, w, 24);
        const w4 = worley4(u, v, w, 48);

        data[idx]     = Math.floor(w1 * 255);
        data[idx + 1] = Math.floor(w2 * 255);
        data[idx + 2] = Math.floor(w3 * 255);
        data[idx + 3] = Math.floor(w4 * 255);

        idx += 4;
      }
    }
  }

  const texture = new THREE.Data3DTexture(data, size, size, size);
  texture.format = THREE.RGBAFormat;
  texture.type = THREE.UnsignedByteType;
  texture.minFilter = THREE.LinearFilter;
  texture.magFilter = THREE.LinearFilter;
  texture.wrapS = THREE.RepeatWrapping;
  texture.wrapT = THREE.RepeatWrapping;
  texture.wrapR = THREE.RepeatWrapping;
  texture.needsUpdate = true;

  return texture;
}

// Seamless Tileable 2D Toroidal Noise Generator
function seamlessTileableNoise2D(perlin: (x: number, y: number, z: number, rep: number) => number, u: number, v: number, frequency = 4.0, seedOffset = 0.0) {
  const angleU = u * Math.PI * 2.0;
  const angleV = v * Math.PI * 2.0;

  const r = frequency / (Math.PI * 2.0);
  const nx = Math.cos(angleU) * r + seedOffset;
  const ny = Math.sin(angleU) * r + seedOffset;
  const nz = Math.cos(angleV) * r + seedOffset * 2.0;

  let val = perlin(nx, ny, nz, 16) * 0.5 + 0.5;
  val += (perlin(nx * 2.0 + 10.0, ny * 2.0 + 10.0, nz * 2.0 + 10.0, 16) * 0.5 + 0.5) * 0.25;
  return Math.min(1.0, Math.max(0.0, val * 0.8));
}

// Generate 256x256 2D Multi-Channel Weather Map Texture
export function generateWeatherMapTexture(width = 256, height = 256): THREE.DataTexture {
  const data = new Uint8Array(width * height * 4);
  const perlin = createPeriodic3DNoise(77);

  let idx = 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const u = x / width;
      const v = y / height;

      let cov1 = seamlessTileableNoise2D(perlin, u, v, 4.0, 0.0);
      let cov2 = seamlessTileableNoise2D(perlin, u, v, 8.0, 25.0);

      let cov = mix(cov1, cov2, 0.35);
      cov = Math.min(1.0, Math.max(0.15, cov));

      let type = seamlessTileableNoise2D(perlin, u, v, 4.0, 50.0);
      let density = seamlessTileableNoise2D(perlin, u, v, 6.0, 90.0);

      data[idx]     = Math.floor(cov * 255);
      data[idx + 1] = Math.floor(type * 255);
      data[idx + 2] = Math.floor(density * 255);
      data[idx + 3] = 255;

      idx += 4;
    }
  }

  const texture = new THREE.DataTexture(data, width, height, THREE.RGBAFormat);
  texture.minFilter = THREE.LinearFilter;
  texture.magFilter = THREE.LinearFilter;
  texture.wrapS = THREE.RepeatWrapping;
  texture.wrapT = THREE.RepeatWrapping;
  texture.needsUpdate = true;

  return texture;
}

export async function getOrGenerateBaseNoiseTexture(size = 128): Promise<THREE.Data3DTexture> {
  return generateBaseNoiseTexture(size);
}

export async function getOrGenerateDetailNoiseTexture(size = 64): Promise<THREE.Data3DTexture> {
  return generateDetailNoiseTexture(size);
}

export async function getOrGenerateWeatherMapTexture(width = 256, height = 256): Promise<THREE.DataTexture> {
  return generateWeatherMapTexture(width, height);
}
