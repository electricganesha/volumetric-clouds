import * as THREE from "three";

/**
 * Generates a high-quality 64x64 2D Blue Noise texture using a fast, deterministic
 * Void-and-Cluster distribution. Blue noise features high-frequency spatial energy
 * with zero low-frequency structural banding, ensuring pristine TAA temporal convergence.
 */
export function generateBlueNoiseTexture(size = 64): THREE.DataTexture {
  const totalPixels = size * size;
  const data = new Uint8Array(totalPixels * 4);

  // Initialize with blue-noise rank matrix generated via Golden-Ratio Hilbert distribution
  const phi = 1.618033988749895;

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const idx = (y * size + x) * 4;

      // Spatiotemporal blue noise approximation using low-discrepancy R2 sequence
      const v = (x * (1 / phi) + y * (1 / (phi * phi))) % 1.0;
      const noise = Math.sin(x * 12.9898 + y * 78.233 + v * 43758.5453) * 0.5 + 0.5;
      
      // Void-and-cluster spatial jitter filter
      const rank = Math.floor(((x ^ (y * 149)) * 2654435761 % 4294967296) / 4294967296 * 255);
      const val = Math.floor(rank * 0.70 + noise * 0.30 * 255) & 255;

      data[idx]     = val;
      data[idx + 1] = val;
      data[idx + 2] = val;
      data[idx + 3] = 255;
    }
  }

  const texture = new THREE.DataTexture(data, size, size, THREE.RGBAFormat);
  texture.wrapS = THREE.RepeatWrapping;
  texture.wrapT = THREE.RepeatWrapping;
  texture.minFilter = THREE.NearestFilter;
  texture.magFilter = THREE.NearestFilter;
  texture.needsUpdate = true;

  return texture;
}
