import * as THREE from "three";
import skyVertexShader from "../shaders/skyVertex.glsl?raw";
import skyFragmentShader from "../shaders/skyFragment.glsl?raw";

export interface SkyResult {
  skyMesh: THREE.Mesh;
  skyMaterial: THREE.ShaderMaterial;
}

export function createSkyMesh(): SkyResult {
  const geometry = new THREE.SphereGeometry(280000, 32, 16);

  const material = new THREE.ShaderMaterial({
    vertexShader: skyVertexShader,
    fragmentShader: skyFragmentShader,
    side: THREE.BackSide,
    depthWrite: false,
    uniforms: {
      uSunDirection: { value: new THREE.Vector3(0.5, 0.8, 0.3).normalize() },
      uSunColor: { value: new THREE.Color(1.0, 0.94, 0.85) },
      uZenithColor: { value: new THREE.Color(0.12, 0.28, 0.65) },
      uHorizonColor: { value: new THREE.Color(0.68, 0.78, 0.92) },
      uSunGlowColor: { value: new THREE.Color(1.0, 0.88, 0.72) },
    },
  });

  const skyMesh = new THREE.Mesh(geometry, material);
  return { skyMesh, skyMaterial: material };
}
