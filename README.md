# Real-Time Volumetric Clouds Engine

A high-performance, real-time 3D atmospheric cloud and environment renderer built with **Three.js**, **React**, **TypeScript**, and custom **GLSL/WGSL shaders**. 

This engine implements physically based volumetric raymarching, procedural 3D noise textures, atmospheric scattering models, and dynamic ocean reflections—optimized to run smoothly at 60 FPS in modern web browsers.

---

## Features

- **Volumetric Raymarching:** Custom GLSL shaders march rays through a 3D bounding volume to dynamically compute cloud density, volume depth, and self-shadowing.
- **Procedural 3D Noise Generation:** Generates multi-octave 3D Perlin and Worley noise maps (via CPU Web Workers or WebGPU compute shaders) to simulate realistic cumulus and stratocumulus cloud structures.
- **Physically Based Atmospheric Lighting:**
  - **Beer-Lambert Law:** Accurately models light attenuation and self-shadowing based on cloud density along solar light rays.
  - **Henyey-Greenstein Phase Function:** Simulates anisotropic forward and backward solar light scattering (e.g., silver-lining effects near the sun).
  - **Powder Effect & In-Scattering:** Simulates light diffusion inside dense cloud interiors.
- **Dynamic Environment & Ocean:**
  - Dynamic sky dome with time-of-day solar position updates.
  - PMREM (Prefiltered Mipmapped Radiance Environment Map) generator for realistic sky environment lighting.
  - Ocean surface renderer featuring normal-map wave distortion, Fresnel reflections, and exponential depth fog.
- **Interactive Controls:** Integrated real-time tuning GUI (`lil-gui`) to tweak cloud coverage, noise frequencies, wind velocity, scattering parameters, step counts, and lighting in real-time.
- **Performance Optimizations:** Downsampled off-screen rendering targets combined with depth-aware bilinear composite filtering to minimize fragment shader throughput.

---

## Tech Stack

- **Core & Framework:** React 19, TypeScript, Vite
- **3D & Graphics:** Three.js (WebGL / WebGPU), Custom GLSL & WGSL Shaders
- **Noise Engine:** WebGPU Compute Shaders / Dedicated Web Workers
- **Linter & Tooling:** Oxlint, TypeScript Compiler

---

## Architecture & Codebase Structure

```text
src/
├── main.ts                       # Renderer initialization, render loop, composite pass & GUI controls
├── App.tsx                       # React application container
├── materials/
│   └── VolumetricCloudMaterial.ts # Three.js ShaderMaterial wrapper for cloud raymarching
├── noise/
│   ├── NoiseGenerator.ts         # CPU/Worker-based 3D noise texture generator
│   ├── WebGPUNoiseGenerator.ts   # WebGPU compute shader noise generator
│   └── noiseWorker.ts            # Off-thread Web Worker for procedural noise computation
├── scene/
│   ├── Sky.ts                    # Dynamic sky dome mesh & shader setup
│   └── Water.ts                  # Ocean surface geometry & reflection pipeline
└── shaders/
    ├── cloudFragment.glsl        # Core raymarching, light absorption & phase function shader
    ├── cloudVertex.glsl          # Cloud mesh vertex transformations
    ├── compositeFragment.glsl    # Depth-aware bilinear compositing shader
    ├── waterFragment.glsl        # Ocean surface lighting & distortion shader
    └── baseNoise.wgsl            # WebGPU compute shader for 3D noise generation
```

---

## Getting Started

### Prerequisites

- [Node.js](https://nodejs.org/) (v18+ recommended)
- `npm` or `pnpm` / `yarn`
- A WebGL2 or WebGPU compatible modern browser (Chrome, Firefox, Edge, Safari)

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/your-username/volumetric-clouds.git
   cd volumetric-clouds
   ```

2. **Install dependencies:**
   ```bash
   npm install
   ```

3. **Start the development server:**
   ```bash
   npm run dev
   ```
   Open your browser and navigate to `http://localhost:5173`.

---

## Available Scripts

- `npm run dev` — Starts the local Vite development server with Hot Module Replacement (HMR).
- `npm run build` — Runs TypeScript type checks (`tsc -b`) and builds the production bundle into `dist/`.
- `npm run preview` — Locally previews the production build output.
- `npm run lint` — Runs `oxlint` for fast code linting.

---

## Controls & GUI Tweakables

When running the app, the floating control panel (`lil-gui`) allows real-time manipulation of:

- **Cloud Shape & Density:** Coverage threshold, cloud height bounds, Perlin/Worley frequency scales.
- **Raymarching Step Count:** Primary ray steps & light evaluation steps for balancing quality vs. performance.
- **Lighting & Scattering:** Sun intensity, scattering anisotropy coefficient ($g$), absorption rate, and cloud base/top color tones.
- **Wind Simulation:** 3D wind velocity vector and animation speed.
