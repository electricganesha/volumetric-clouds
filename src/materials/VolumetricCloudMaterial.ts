import * as THREE from "three";
import cloudVertexShader from "../shaders/cloudVertex.glsl?raw";
import cloudFragmentShader from "../shaders/cloudFragment.glsl?raw";

import { generateBlueNoiseTexture } from "../noise/blueNoise";

export interface VolumetricCloudMaterialOptions {
  baseNoise?: THREE.Data3DTexture;
  detailNoise?: THREE.Data3DTexture;
  weatherMap?: THREE.DataTexture;
  blueNoise?: THREE.DataTexture;
}

// Tiny placeholder 3D texture (1×1×1, all white)
// Used immediately so the material is renderable while the worker finishes.
function makePlaceholder3D(): THREE.Data3DTexture {
  const d = new Uint8Array([255, 255, 255, 255]);
  const t = new THREE.Data3DTexture(d, 1, 1, 1);
  t.format = THREE.RGBAFormat;
  t.type = THREE.UnsignedByteType;
  t.needsUpdate = true;
  return t;
}

function makePlaceholder2D(): THREE.DataTexture {
  const d = new Uint8Array([255, 255, 255, 255]);
  const t = new THREE.DataTexture(d, 1, 1, THREE.RGBAFormat);
  t.needsUpdate = true;
  return t;
}

// Promote a raw buffer into the corresponding Three.js texture type
function buildBase3D(buf: ArrayBuffer, size = 128): THREE.Data3DTexture {
  const t = new THREE.Data3DTexture(new Uint8Array(buf), size, size, size);
  t.format = THREE.RGBAFormat;
  t.type = THREE.UnsignedByteType;
  t.minFilter = THREE.LinearFilter;
  t.magFilter = THREE.LinearFilter;
  t.wrapS = t.wrapT = t.wrapR = THREE.RepeatWrapping;
  t.needsUpdate = true;
  return t;
}

function buildDetail3D(buf: ArrayBuffer, size = 64): THREE.Data3DTexture {
  const t = new THREE.Data3DTexture(new Uint8Array(buf), size, size, size);
  t.format = THREE.RGBAFormat;
  t.type = THREE.UnsignedByteType;
  t.minFilter = THREE.LinearFilter;
  t.magFilter = THREE.LinearFilter;
  t.wrapS = t.wrapT = t.wrapR = THREE.RepeatWrapping;
  t.needsUpdate = true;
  return t;
}

function buildWeather2D(buf: ArrayBuffer, w = 256, h = 256): THREE.DataTexture {
  const t = new THREE.DataTexture(new Uint8Array(buf), w, h, THREE.RGBAFormat);
  t.minFilter = THREE.LinearFilter;
  t.magFilter = THREE.LinearFilter;
  t.wrapS = t.wrapT = THREE.RepeatWrapping;
  t.needsUpdate = true;
  return t;
}

export class VolumetricCloudMaterial extends THREE.ShaderMaterial {
  declare uniforms: Record<string, THREE.IUniform>;

  /**
   * Creates the material immediately with 1×1 placeholder textures, then
   * spawns a Web Worker to generate the real noise off the main thread.
   * Textures are hot-swapped when the worker finishes — no freeze, no wait.
   */
  static createAsync(
    _options: VolumetricCloudMaterialOptions = {},
    onLoaded?: (base: ArrayBuffer, detail: ArrayBuffer, weather: ArrayBuffer) => void
  ): VolumetricCloudMaterial {
    const mat = new VolumetricCloudMaterial();

    const hideOverlay = () => {
      const overlay = document.getElementById("loading-overlay");
      if (overlay) overlay.style.opacity = "0";
      setTimeout(() => overlay?.remove(), 600);
    };

    // Off-thread Web Worker Noise Generation — Zero main thread latency
    const worker = new Worker(
      new URL("../noise/noiseWorker.ts", import.meta.url),
      { type: "module" }
    );
    worker.onmessage = (e) => {
      const { base, detail, weather } = e.data;
      mat.uniforms.uBaseNoise.value = buildBase3D(base, 128);
      mat.uniforms.uDetailNoise.value = buildDetail3D(detail, 64);
      mat.uniforms.uWeatherMap.value = buildWeather2D(weather, 256, 256);
      mat.needsUpdate = true;
      if (onLoaded) onLoaded(base, detail, weather);
      hideOverlay();
      worker.terminate();
    };
    worker.postMessage(null);

    return mat;
  }

  constructor(options: VolumetricCloudMaterialOptions = {}) {
    const dummyDepth = new THREE.DataTexture(
      new Uint8Array([0, 0, 0, 255]),
      1,
      1,
    );
    dummyDepth.needsUpdate = true;

    super({
      glslVersion: THREE.GLSL3,
      vertexShader: cloudVertexShader,
      fragmentShader: cloudFragmentShader,
      transparent: true,
      depthWrite: false,
      side: THREE.DoubleSide,
      uniforms: {
        uBaseNoise: { value: options.baseNoise ?? makePlaceholder3D() },
        uDetailNoise: { value: options.detailNoise ?? makePlaceholder3D() },
        uWeatherMap: { value: options.weatherMap ?? makePlaceholder2D() },
        uBlueNoise: { value: options.blueNoise ?? generateBlueNoiseTexture() },
        uDepthTexture: { value: dummyDepth },
        uFrameCount: { value: 0 },

        uCameraPos: { value: new THREE.Vector3() },
        uSunDirection: {
          value: new THREE.Vector3(0.6, 0.45, -0.65).normalize(),
        },
        uSunColor: { value: new THREE.Color(1.0, 0.97, 0.92) },
        uZenithColor: { value: new THREE.Color(0.12, 0.28, 0.65) },
        uHorizonColor: { value: new THREE.Color(0.68, 0.78, 0.92) },

        uProjectionInverse: { value: new THREE.Matrix4() },
        uViewInverse: { value: new THREE.Matrix4() },
        uResolution: {
          value: new THREE.Vector2(window.innerWidth, window.innerHeight),
        },
        uTime: { value: 0 },
        uJitter: { value: new THREE.Vector2(0, 0) },
        uIsReflectionPass: { value: false },

        uCloudCoverage: { value: 0.65 },
        uCloudScale: { value: 0.85 },
        uDetailScale: { value: 4.5 },
        uDensityMultiplier: { value: 1.5 },
        uAnisotropy: { value: 1.0 },
        uWarpStrength: { value: 0.25 },

        uForwardGlow: { value: 1.0 },
        uShadowIntensity: { value: 1.0 },
        uPowderIntensity: { value: 1.0 },
        uGroundBounceColor: { value: new THREE.Color(0.72, 0.64, 0.55) },

        uShadowAbsorption: { value: 3.5 },
        uShadowSoftness: { value: 1.0 },
        uLightStepLength: { value: 180.0 },

        uWindVector: { value: new THREE.Vector3(25.0, 0.0, 15.0) },
        uWindShear: { value: 0.0 },
        uMorphSpeed: { value: 0.8 },

        uBoxMin: { value: new THREE.Vector3(-250000, 1000, -250000) },
        uBoxMax: { value: new THREE.Vector3(250000, 4500, 250000) },
      },
    });
  }

  updateCamera(camera: THREE.PerspectiveCamera): void {
    this.uniforms.uCameraPos.value.copy(camera.position);
    this.uniforms.uProjectionInverse.value.copy(camera.projectionMatrixInverse);
    this.uniforms.uViewInverse.value.copy(camera.matrixWorld);
  }

  updateResolution(width: number, height: number): void {
    this.uniforms.uResolution.value.set(width, height);
  }

  setDepthTexture(tex: THREE.Texture | null): void {
    if (tex) this.uniforms.uDepthTexture.value = tex;
  }

  updateTime(delta: number): void {
    this.uniforms.uTime.value += delta;
  }
}
