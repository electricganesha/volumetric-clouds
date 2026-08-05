import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import GUI from "lil-gui";
import { VolumetricCloudMaterial } from "./materials/VolumetricCloudMaterial";
import { Water } from "./scene/Water";
import { createSkyMesh } from "./scene/Sky";
import compositeVertexShader from "./shaders/compositeVertex.glsl?raw";
import compositeFragmentShader from "./shaders/compositeFragment.glsl?raw";
import taaVertexShader from "./shaders/taaVertex.glsl?raw";
import taaFragmentShader from "./shaders/taaFragment.glsl?raw";

// Setup WebGL Renderer
const container = document.getElementById("root") || document.body;
const renderer = new THREE.WebGLRenderer({
  antialias: true,
  powerPreference: "high-performance",
});
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 1.25));
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 0.92;
container.appendChild(renderer.domElement);

// Opaque Scene & Camera
const scene = new THREE.Scene();

const camera = new THREE.PerspectiveCamera(
  60,
  window.innerWidth / window.innerHeight,
  1.0,
  300000,
);
camera.position.set(0, 80, 450);

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.dampingFactor = 0.05;
controls.enableZoom = false;
controls.enablePan = false;
controls.maxPolarAngle = Math.PI / 2 - 0.01;
controls.minDistance = 10;
controls.maxDistance = 200000;
controls.target.set(0, 1400, -1000);
controls.update();

// Sky Mesh
const { skyMesh, skyMaterial } = createSkyMesh();
skyMesh.frustumCulled = false; // Prevent mirror camera clipping
scene.add(skyMesh);

// PMREM Dynamic Environment Map Generator
const pmremGenerator = new THREE.PMREMGenerator(renderer);
pmremGenerator.compileEquirectangularShader();

const skySceneForEnv = new THREE.Scene();
const skyEnvMesh = skyMesh.clone();
skySceneForEnv.add(skyEnvMesh);

let currentEnvMap: THREE.WebGLRenderTarget | null = null;

const updateEnvironmentMap = () => {
  if (currentEnvMap) currentEnvMap.dispose();
  currentEnvMap = pmremGenerator.fromScene(skySceneForEnv);
  scene.environment = currentEnvMap.texture;
};

// Exponential distance fog — fades ocean to horizon, hides the water plane edge
scene.fog = new THREE.FogExp2(0x8db8d8, 0.000018);

// Three.js Water Object — plane must exceed camera far (300k) on all sides
const waterGeo = new THREE.PlaneGeometry(800000, 800000);

const water = new Water(waterGeo, {
  textureWidth: 512,
  textureHeight: 512,
  waterNormals: new THREE.TextureLoader().load(
    "/waternormals.jpg",
    function (texture) {
      texture.wrapS = texture.wrapT = THREE.RepeatWrapping;
    },
  ),
  sunDirection: new THREE.Vector3(-6000, 4500, -8000).normalize(),
  sunColor: 0xffffff,
  waterColor: 0x003a6e,
  distortionScale: 3.5,
  size: 1.0,
  fog: scene.fog !== undefined,
});
water.position.y = 8.0;
water.rotation.x = -Math.PI / 2;

scene.add(water);

// Hook moved later

// Lights
const ambientLight = new THREE.AmbientLight(0xebf4ff, 1.2);
scene.add(ambientLight);

const sunLight = new THREE.DirectionalLight(0xfff5ea, 3.2);
sunLight.position.set(-6000, 4500, -8000);
scene.add(sunLight);
scene.add(sunLight.target);

// Fullscreen Quad Geometry for Raymarching & Compositing
const quadGeo = new THREE.PlaneGeometry(2, 2);
const postCamera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);

// Render Target Setup
let pr = renderer.getPixelRatio();
let fullWidth = Math.floor(window.innerWidth * pr);
let fullHeight = Math.floor(window.innerHeight * pr);

const sceneRenderTarget = new THREE.WebGLRenderTarget(fullWidth, fullHeight, {
  minFilter: THREE.LinearFilter,
  magFilter: THREE.LinearFilter,
  format: THREE.RGBAFormat,
  depthTexture: new THREE.DepthTexture(
    fullWidth,
    fullHeight,
    THREE.UnsignedIntType,
  ),
});

// Volumetric Clouds Material — created immediately, textures load async in worker
const cloudMaterial = VolumetricCloudMaterial.createAsync();

cloudMaterial.setDepthTexture(sceneRenderTarget.depthTexture);

const cloudQuadMesh = new THREE.Mesh(quadGeo, cloudMaterial);
const cloudScene = new THREE.Scene();
cloudScene.add(cloudQuadMesh);

// Cloud Render Target — THREE.HalfFloatType for HDR precision & bandwidth optimization
let renderScale = 0.5;
let cloudTargetW = Math.max(Math.floor(fullWidth * renderScale), 1);
let cloudTargetH = Math.max(Math.floor(fullHeight * renderScale), 1);

const cloudRenderTarget = new THREE.WebGLRenderTarget(
  cloudTargetW,
  cloudTargetH,
  {
    count: 2,
    minFilter: THREE.LinearFilter,
    magFilter: THREE.LinearFilter,
    format: THREE.RGBAFormat,
    type: THREE.HalfFloatType,
  }
);
cloudRenderTarget.textures[0].name = "color";
cloudRenderTarget.textures[1].name = "distance";

const createTAATarget = () => new THREE.WebGLRenderTarget(fullWidth, fullHeight, {
  minFilter: THREE.LinearFilter,
  magFilter: THREE.LinearFilter,
  format: THREE.RGBAFormat,
  type: THREE.HalfFloatType,
});
let taaHistoryA = createTAATarget();
let taaHistoryB = createTAATarget();
let taaReadTarget = taaHistoryA;
let taaWriteTarget = taaHistoryB;

let frameCount = 0;
// Halton Sequence (2, 3) for 16 samples
const halton23 = [
    [0.5, 0.33333333], [0.25, 0.66666667], [0.75, 0.11111111], [0.125, 0.44444444],
    [0.625, 0.77777778], [0.375, 0.22222222], [0.875, 0.55555556], [0.0625, 0.88888889],
    [0.5625, 0.03703704], [0.3125, 0.37037037], [0.8125, 0.7037037], [0.1875, 0.14814815],
    [0.6875, 0.48148148], [0.4375, 0.81481481], [0.9375, 0.25925926], [0.03125, 0.59259259]
];

// Tracking matrices for reprojection
const previousViewProjectionMatrix = new THREE.Matrix4();

const taaMaterial = new THREE.ShaderMaterial({
  depthWrite: false,
  depthTest: false,
  uniforms: {
    uCurrentCloud: { value: cloudRenderTarget.textures[0] },
    uCurrentDistance: { value: cloudRenderTarget.textures[1] },
    uHistoryCloud: { value: taaReadTarget.texture },
    uPreviousViewProjectionMatrix: { value: new THREE.Matrix4() },
    uViewProjectionMatrixInverse: { value: new THREE.Matrix4() },
    uCameraPos: { value: new THREE.Vector3() },
  },
  vertexShader: taaVertexShader,
  fragmentShader: taaFragmentShader,
  glslVersion: THREE.GLSL3,
});

const taaMesh = new THREE.Mesh(quadGeo, taaMaterial);
const taaScene = new THREE.Scene();
taaScene.add(taaMesh);

// Composite Pass — Edge-Aware Bilateral Upsampling Composite Shader
const compositeMaterial = new THREE.ShaderMaterial({
  depthWrite: false,
  depthTest: false,
  uniforms: {
    uSceneTexture: { value: sceneRenderTarget.texture },
    uCloudTexture: { value: taaReadTarget.texture },
    uDepthTexture: { value: sceneRenderTarget.depthTexture },
    uTexelSize: {
      value: new THREE.Vector2(1.0 / fullWidth, 1.0 / fullHeight),
    },
    uProjectionInverse: { value: new THREE.Matrix4() },
    uViewInverse: { value: new THREE.Matrix4() },
    uCameraPos: { value: new THREE.Vector3() },
    uHorizonUvY: { value: 0.5 },
    uTime: { value: 0.0 },
    uEnableChromaticAberration: { value: true },
    uAberrationOffset: { value: 0.0012 },
    uEnableColorGrading: { value: true },
    uContrast: { value: 0.95 },
    uSaturation: { value: 1.18 },
    uSplitToningShadow: { value: 0.5 },
    uSplitToningHighlight: { value: 0.4 },
    uEnableVignette: { value: true },
    uVignetteDarkness: { value: 0.55 },
    uVignetteFalloff: { value: 0.85 },
    uEnableFilmGrain: { value: true },
    uFilmGrainAmount: { value: 0.018 },
  },
  vertexShader: compositeVertexShader,
  fragmentShader: compositeFragmentShader,
});

const compositeMesh = new THREE.Mesh(quadGeo, compositeMaterial);
const compositeScene = new THREE.Scene();
compositeScene.add(compositeMesh);

// Hook to render clouds and sky into the water's reflection target
(water as any).onAfterRenderScene = (
  renderer: THREE.WebGLRenderer,
  mirrorCamera: THREE.PerspectiveCamera,
  renderTarget: THREE.WebGLRenderTarget,
) => {
  // Save states
  const oldProj = cloudMaterial.uniforms.uProjectionInverse.value.clone();
  const oldView = cloudMaterial.uniforms.uViewInverse.value.clone();
  const oldCamPos = cloudMaterial.uniforms.uCameraPos.value.clone();
  const oldDepth = cloudMaterial.uniforms.uDepthTexture.value;
  const oldJitter = cloudMaterial.uniforms.uJitter.value.clone();

  // Set cloud uniforms to match the mirror camera perspective
  cloudMaterial.uniforms.uProjectionInverse.value.copy(
    camera.projectionMatrixInverse,
  );
  cloudMaterial.uniforms.uViewInverse.value.copy(mirrorCamera.matrixWorld);
  cloudMaterial.uniforms.uCameraPos.value.copy(mirrorCamera.position);
  cloudMaterial.uniforms.uDepthTexture.value = null; // Disable depth clipping for the sky/reflection pass
  cloudMaterial.uniforms.uJitter.value.set(0, 0);

  // Configure blending so clouds render cleanly over the sky reflection
  cloudMaterial.transparent = true;
  cloudMaterial.blending = THREE.CustomBlending;
  cloudMaterial.blendEquation = THREE.AddEquation;
  cloudMaterial.blendSrc = THREE.SrcAlphaFactor;
  cloudMaterial.blendDst = THREE.OneMinusSrcAlphaFactor;
  cloudMaterial.depthWrite = false;
  cloudMaterial.depthTest = false;

  const oldAutoClear = renderer.autoClear;
  renderer.autoClear = false;

  // Render the volumetric clouds directly into the water's renderTarget buffer
  renderer.setRenderTarget(renderTarget);
  renderer.render(cloudScene, postCamera);

  renderer.autoClear = oldAutoClear;

  // Restore main camera uniforms and material states
  cloudMaterial.depthTest = true;
  cloudMaterial.blending = THREE.NormalBlending;
  cloudMaterial.uniforms.uProjectionInverse.value.copy(oldProj);
  cloudMaterial.uniforms.uViewInverse.value.copy(oldView);
  cloudMaterial.uniforms.uCameraPos.value.copy(oldCamPos);
  cloudMaterial.uniforms.uDepthTexture.value = oldDepth;
  cloudMaterial.uniforms.uJitter.value.copy(oldJitter);
};

// GUI Controls
const gui = new GUI({ title: "Volumetric Cloud Controls" });

const params = {
  timeOfDay: 13.3,
  autoCycle: false,
  autoCycleSpeed: 0.5,

  resScale: "0.5x (Smooth 60 FPS)",
  coverage: 0.7,
  density: 1.8,
  cloudScale: 1.5,
  detailScale: 0.4,
  anisotropy: 2.45,
  warpStrength: 0.6,

  forwardGlow: 0.8,
  shadowIntensity: 1.8,
  powderIntensity: 1.2,
  groundBounceColor: "#b3e5ff",

  shadowAbsorption: 0.7,
  shadowSoftness: 1.0,
  lightStepLength: 300,

  timeScale: 2.2,
  windSpeed: 68,
  windDirection: 125,
  windShear: 0.0,
  morphSpeed: 0.6,

  cloudMinY: 1050,
  cloudMaxY: 11200,

  enableVignette: true,
  vignetteDarkness: 0.55,
  vignetteFalloff: 0.85,

  enableChromaticAberration: true,
  aberrationOffset: 0.0012,

  enableColorGrading: true,
  contrast: 0.95,
  saturation: 1.18,
  splitToningShadow: 0.5,
  splitToningHighlight: 0.4,

  enableFilmGrain: true,
  filmGrainAmount: 0.018,
};

// Dynamic Time-of-Day Engine
const updateTimeOfDay = () => {
  const t = params.timeOfDay;

  const sunElevation = Math.sin(((t - 6.0) / 12.0) * Math.PI) * 75.0;
  const sunAzimuth = (t / 24.0) * 360.0 + 90.0;

  const phi = THREE.MathUtils.degToRad(90 - sunElevation);
  const theta = THREE.MathUtils.degToRad(sunAzimuth);

  const sunDistance = 15000;
  sunLight.position.x = sunDistance * Math.sin(phi) * Math.cos(theta);
  sunLight.position.y = sunDistance * Math.cos(phi);
  sunLight.position.z = sunDistance * Math.sin(phi) * Math.sin(theta);
  sunLight.target.position.set(0, 0, 0);

  const dir = new THREE.Vector3().copy(sunLight.position).normalize();
  (cloudMaterial.uniforms.uSunDirection.value as THREE.Vector3).copy(dir);
  (skyMaterial.uniforms.uSunDirection.value as THREE.Vector3).copy(dir);
  if ((water.material as THREE.ShaderMaterial).uniforms["sunDirection"]) {
    (
      (water.material as THREE.ShaderMaterial).uniforms["sunDirection"]
        .value as THREE.Vector3
    ).copy(dir);
  }

  const elevNorm = Math.max(-0.2, Math.min(1.0, sunElevation / 75.0));

  const sunColor = new THREE.Color();
  const zenithColor = new THREE.Color();
  const horizonColor = new THREE.Color();
  const groundBounceColor = new THREE.Color();
  const sunGlowColor = new THREE.Color();

  if (elevNorm > 0.15) {
    const dayFactor = Math.min(1.0, (elevNorm - 0.15) / 0.85);
    sunColor.lerpColors(
      new THREE.Color("#ffb366"),
      new THREE.Color("#fff5ea"),
      dayFactor,
    );
    zenithColor.lerpColors(
      new THREE.Color("#1c4fa8"),
      new THREE.Color("#122c65"),
      1.0 - dayFactor,
    );
    horizonColor.lerpColors(
      new THREE.Color("#ffaa77"),
      new THREE.Color("#accdfc"),
      dayFactor,
    );
    groundBounceColor.lerpColors(
      new THREE.Color("#8c593b"),
      new THREE.Color("#b8a38c"),
      dayFactor,
    );
    sunGlowColor.set("#ffeaad");
    sunLight.intensity = 3.2 * dayFactor + 0.8;
  } else if (elevNorm > -0.05) {
    const sunsetFactor = (elevNorm + 0.05) / 0.2;
    sunColor.lerpColors(
      new THREE.Color("#ff3d00"),
      new THREE.Color("#ffb366"),
      sunsetFactor,
    );
    zenithColor.lerpColors(
      new THREE.Color("#0d1c44"),
      new THREE.Color("#1c4fa8"),
      sunsetFactor,
    );
    horizonColor.lerpColors(
      new THREE.Color("#ff5522"),
      new THREE.Color("#ffaa77"),
      sunsetFactor,
    );
    groundBounceColor.lerpColors(
      new THREE.Color("#40180a"),
      new THREE.Color("#8c593b"),
      sunsetFactor,
    );
    sunGlowColor.set("#ff6622");
    sunLight.intensity = 1.2 * sunsetFactor + 0.2;
  } else {
    const nightFactor = Math.min(1.0, Math.abs(elevNorm + 0.05) / 0.15);
    sunColor.lerpColors(
      new THREE.Color("#ff3d00"),
      new THREE.Color("#8ab4f8"),
      nightFactor,
    );
    zenithColor.lerpColors(
      new THREE.Color("#0d1c44"),
      new THREE.Color("#050b1e"),
      nightFactor,
    );
    horizonColor.lerpColors(
      new THREE.Color("#ff5522"),
      new THREE.Color("#152445"),
      nightFactor,
    );
    groundBounceColor.lerpColors(
      new THREE.Color("#40180a"),
      new THREE.Color("#101828"),
      nightFactor,
    );
    sunGlowColor.set("#5588cc");
    sunLight.intensity = 0.45;
  }

  (cloudMaterial.uniforms.uSunColor.value as THREE.Color).copy(sunColor);
  (cloudMaterial.uniforms.uZenithColor.value as THREE.Color).copy(zenithColor);
  (cloudMaterial.uniforms.uHorizonColor.value as THREE.Color).copy(
    horizonColor,
  );

  (skyMaterial.uniforms.uSunColor.value as THREE.Color).copy(sunColor);
  (skyMaterial.uniforms.uZenithColor.value as THREE.Color).copy(zenithColor);
  (skyMaterial.uniforms.uHorizonColor.value as THREE.Color).copy(horizonColor);
  (skyMaterial.uniforms.uSunGlowColor.value as THREE.Color).copy(sunGlowColor);

  if ((water.material as THREE.ShaderMaterial).uniforms["sunColor"]) {
    (
      (water.material as THREE.ShaderMaterial).uniforms["sunColor"]
        .value as THREE.Color
    ).copy(sunColor);
  }

  if (params.groundBounceColor) {
    (cloudMaterial.uniforms.uGroundBounceColor.value as THREE.Color).copy(
      groundBounceColor,
    );
    params.groundBounceColor = "#" + groundBounceColor.getHexString();
  }

  updateEnvironmentMap();
};

const updateResolutionTargets = () => {
  pr = renderer.getPixelRatio();
  fullWidth = Math.floor(window.innerWidth * pr);
  fullHeight = Math.floor(window.innerHeight * pr);

  sceneRenderTarget.setSize(fullWidth, fullHeight);

  const scaleVal = parseFloat(params.resScale);
  renderScale = isNaN(scaleVal) ? 0.5 : scaleVal;

  cloudTargetW = Math.max(Math.floor(fullWidth * renderScale), 1);
  cloudTargetH = Math.max(Math.floor(fullHeight * renderScale), 1);

  cloudRenderTarget.setSize(cloudTargetW, cloudTargetH);

  cloudMaterial.updateResolution(cloudTargetW, cloudTargetH);
  cloudMaterial.setDepthTexture(sceneRenderTarget.depthTexture);
  (compositeMaterial.uniforms.uTexelSize.value as THREE.Vector2).set(
    1.0 / cloudTargetW,
    1.0 / cloudTargetH,
  );
};

const updateWindVector = () => {
  const rad = THREE.MathUtils.degToRad(params.windDirection);
  const speed = params.windSpeed;
  (cloudMaterial.uniforms.uWindVector.value as THREE.Vector3).set(
    Math.sin(rad) * speed,
    0.0,
    Math.cos(rad) * speed,
  );
};

const updateVolumeBounds = () => {
  (cloudMaterial.uniforms.uBoxMin.value as THREE.Vector3).y = params.cloudMinY;
  (cloudMaterial.uniforms.uBoxMax.value as THREE.Vector3).y = params.cloudMaxY;
};

// Initial sync
updateTimeOfDay();
updateWindVector();
updateVolumeBounds();
updateResolutionTargets();

// Push all params → uniforms at startup so new defaults take effect immediately
cloudMaterial.uniforms.uCloudCoverage.value = params.coverage;
cloudMaterial.uniforms.uDensityMultiplier.value = params.density;
cloudMaterial.uniforms.uCloudScale.value = params.cloudScale;
cloudMaterial.uniforms.uDetailScale.value = params.detailScale;
cloudMaterial.uniforms.uAnisotropy.value = params.anisotropy;
cloudMaterial.uniforms.uWarpStrength.value = params.warpStrength;
cloudMaterial.uniforms.uForwardGlow.value = params.forwardGlow;
cloudMaterial.uniforms.uShadowIntensity.value = params.shadowIntensity;
cloudMaterial.uniforms.uPowderIntensity.value = params.powderIntensity;
cloudMaterial.uniforms.uShadowAbsorption.value = params.shadowAbsorption;
cloudMaterial.uniforms.uShadowSoftness.value = params.shadowSoftness;
cloudMaterial.uniforms.uLightStepLength.value = params.lightStepLength;
cloudMaterial.uniforms.uMorphSpeed.value = params.morphSpeed;
cloudMaterial.uniforms.uWindShear.value = params.windShear;
(cloudMaterial.uniforms.uGroundBounceColor.value as THREE.Color).set(
  params.groundBounceColor,
);

// GUI Folders

const timeFolder = gui.addFolder("Time & Atmosphere Cycle");
timeFolder
  .add(params, "timeOfDay", 0.0, 24.0, 0.1)
  .name("Time of Day (Hours)")
  .listen()
  .onChange(updateTimeOfDay);
timeFolder.add(params, "autoCycle").name("Auto Day/Night Cycle");
timeFolder.add(params, "autoCycleSpeed", 0.1, 5.0, 0.1).name("Cycle Speed (x)");

const qualityFolder = gui.addFolder("Performance & Quality");
qualityFolder
  .add(params, "resScale", [
    "0.25x (Ultra Fast)",
    "0.5x (Smooth 60 FPS)",
    "0.75x (High Quality)",
    "1.0x (Native Resolution)",
  ])
  .name("Cloud Resolution")
  .onChange(updateResolutionTargets);

const shapeFolder = gui.addFolder("Cloud Formation & Density");
shapeFolder
  .add(params, "coverage", 0.0, 1.0, 0.01)
  .name("Atmospheric Coverage")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uCloudCoverage.value = v;
  });
shapeFolder
  .add(params, "density", 0.1, 5.0, 0.1)
  .name("Cloud Mass Density")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uDensityMultiplier.value = v;
  });
shapeFolder
  .add(params, "cloudScale", 0.2, 3.0, 0.05)
  .name("Macro Billow Scale")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uCloudScale.value = v;
  });
shapeFolder
  .add(params, "detailScale", 0.2, 8.0, 0.05)
  .name("Micro Erosion Detail")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uDetailScale.value = v;
  });
shapeFolder
  .add(params, "anisotropy", 0.2, 3.0, 0.05)
  .name("Vertical Anisotropy")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uAnisotropy.value = v;
  });
shapeFolder
  .add(params, "warpStrength", 0.0, 1.0, 0.02)
  .name("Turbulent Domain Warping")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uWarpStrength.value = v;
  });

const lightingFolder = gui.addFolder("AAA Cloud Lighting & Shadows");
lightingFolder
  .add(params, "forwardGlow", 0.2, 2.0, 0.05)
  .name("Silver Lining (Rim Glow)")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uForwardGlow.value = v;
  });
lightingFolder
  .add(params, "shadowIntensity", 0.2, 2.5, 0.05)
  .name("Underbelly Shadow Depth")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uShadowIntensity.value = v;
  });
lightingFolder
  .add(params, "shadowAbsorption", 0.5, 10.0, 0.1)
  .name("Shadow Light Absorption")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uShadowAbsorption.value = v;
  });
lightingFolder
  .add(params, "shadowSoftness", 0.2, 3.0, 0.1)
  .name("Shadow Softness / Blur")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uShadowSoftness.value = v;
  });
lightingFolder
  .add(params, "lightStepLength", 50, 400, 10)
  .name("Sun Ray Step Length (m)")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uLightStepLength.value = v;
  });
lightingFolder
  .add(params, "powderIntensity", 0.0, 2.0, 0.05)
  .name("Powdered Sugar Effect")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uPowderIntensity.value = v;
  });
lightingFolder
  .addColor(params, "groundBounceColor")
  .listen()
  .name("Ground Bounce Light Color")
  .onChange((c: string) => {
    (cloudMaterial.uniforms.uGroundBounceColor.value as THREE.Color).set(c);
  });

const windFolder = gui.addFolder("Wind & Motion Controls");
windFolder
  .add(params, "timeScale", 0.0, 10.0, 0.1)
  .name("Time Speed Multiplier (x)");
windFolder
  .add(params, "windSpeed", 0, 300, 1)
  .name("Wind Speed (m/s)")
  .onChange(updateWindVector);
windFolder
  .add(params, "windDirection", 0, 360, 1)
  .name("Wind Angle (deg)")
  .onChange(updateWindVector);
windFolder
  .add(params, "windShear", 0.0, 1.5, 0.05)
  .name("Altitude Wind Shear")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uWindShear.value = v;
  });
windFolder
  .add(params, "morphSpeed", 0.0, 5.0, 0.1)
  .name("Boiling Morph Rate")
  .onChange((v: number) => {
    cloudMaterial.uniforms.uMorphSpeed.value = v;
  });

const boundsFolder = gui.addFolder("Atmosphere Altitude");
boundsFolder
  .add(params, "cloudMinY", 500, 2000, 50)
  .name("Bottom Altitude (m)")
  .onChange(updateVolumeBounds);
boundsFolder
  .add(params, "cloudMaxY", 3000, 12000, 200)
  .name("Top Altitude (m)")
  .onChange(updateVolumeBounds);

const postProcessingFolder = gui.addFolder("Post-Processing Effects");

// --- Chromatic Aberration ---
const caFolder = postProcessingFolder.addFolder("Chromatic Aberration");
caFolder
  .add(params, "enableChromaticAberration")
  .name("Enable")
  .onChange((v: boolean) => {
    compositeMaterial.uniforms.uEnableChromaticAberration.value = v;
  });
caFolder
  .add(params, "aberrationOffset", 0.0, 0.005, 0.0001)
  .name("Offset Strength")
  .onChange((v: number) => {
    compositeMaterial.uniforms.uAberrationOffset.value = v;
  });

// --- Color Grading ---
const cgFolder = postProcessingFolder.addFolder("Color Grading");
cgFolder
  .add(params, "enableColorGrading")
  .name("Enable")
  .onChange((v: boolean) => {
    compositeMaterial.uniforms.uEnableColorGrading.value = v;
  });
cgFolder
  .add(params, "contrast", 0.5, 2.0, 0.01)
  .name("Contrast")
  .onChange((v: number) => {
    compositeMaterial.uniforms.uContrast.value = v;
  });
cgFolder
  .add(params, "saturation", 0.0, 2.0, 0.02)
  .name("Saturation")
  .onChange((v: number) => {
    compositeMaterial.uniforms.uSaturation.value = v;
  });
cgFolder
  .add(params, "splitToningShadow", 0.0, 1.0, 0.02)
  .name("Warm Shadow Tint")
  .onChange((v: number) => {
    compositeMaterial.uniforms.uSplitToningShadow.value = v;
  });
cgFolder
  .add(params, "splitToningHighlight", 0.0, 1.0, 0.02)
  .name("Cool Highlight Tint")
  .onChange((v: number) => {
    compositeMaterial.uniforms.uSplitToningHighlight.value = v;
  });

// --- Vignette ---
const vignFolder = postProcessingFolder.addFolder("Vignette");
vignFolder
  .add(params, "enableVignette")
  .name("Enable")
  .onChange((v: boolean) => {
    compositeMaterial.uniforms.uEnableVignette.value = v;
  });
vignFolder
  .add(params, "vignetteDarkness", 0.0, 1.0, 0.01)
  .name("Edge Darkness")
  .onChange((v: number) => {
    compositeMaterial.uniforms.uVignetteDarkness.value = v;
  });
vignFolder
  .add(params, "vignetteFalloff", 0.35, 1.5, 0.02)
  .name("Radius / Falloff")
  .onChange((v: number) => {
    compositeMaterial.uniforms.uVignetteFalloff.value = v;
  });

// --- Film Grain ---
const grainFolder = postProcessingFolder.addFolder("Film Grain");
grainFolder
  .add(params, "enableFilmGrain")
  .name("Enable")
  .onChange((v: boolean) => {
    compositeMaterial.uniforms.uEnableFilmGrain.value = v;
  });
grainFolder
  .add(params, "filmGrainAmount", 0.0, 0.08, 0.001)
  .name("Noise Intensity")
  .onChange((v: number) => {
    compositeMaterial.uniforms.uFilmGrainAmount.value = v;
  });

gui.close();

// Resize Listener
window.addEventListener("resize", () => {
  const w = window.innerWidth;
  const h = window.innerHeight;
  camera.aspect = w / h;
  camera.updateProjectionMatrix();

  renderer.setSize(w, h);
  updateResolutionTargets();
});

cloudMaterial.updateResolution(cloudTargetW, cloudTargetH);

// Animation Loop
const clock = new THREE.Clock();

function animate() {
  requestAnimationFrame(animate);

  const delta = clock.getDelta();

  if (params.autoCycle) {
    params.timeOfDay =
      (params.timeOfDay + delta * params.autoCycleSpeed) % 24.0;
    updateTimeOfDay();
  }

  const simDelta = delta * params.timeScale;
  controls.update();

  camera.updateMatrixWorld();

  // Update fog colour to match the current horizon colour
  if (scene.fog instanceof THREE.FogExp2) {
    (scene.fog as THREE.FogExp2).color.copy(
      cloudMaterial.uniforms.uHorizonColor.value as THREE.Color,
    );
  }

  // Dynamic Camera-Centered Sky Mesh
  skyMesh.position.copy(camera.position);

  // 2. Main scene pass (renders terrain, sky, and water including its mirror pass)
  (water.material as THREE.ShaderMaterial).uniforms["time"].value += simDelta;
  renderer.setRenderTarget(sceneRenderTarget);
  renderer.render(scene, camera);

  // 2. Render volumetric clouds into cloudRenderTarget
  const jitter = halton23[frameCount % 16];
  const jitterX = (jitter[0] * 2.0 - 1.0) / cloudTargetW;
  const jitterY = (jitter[1] * 2.0 - 1.0) / cloudTargetH;
  cloudMaterial.uniforms.uJitter.value.set(jitterX, jitterY);

  cloudMaterial.updateTime(simDelta);
  cloudMaterial.updateCamera(camera);

  renderer.setClearColor(0x000000, 0.0);
  renderer.setRenderTarget(cloudRenderTarget);
  renderer.clear();
  renderer.render(cloudScene, postCamera);

  // 3. TAA Reprojection Pass
  taaMaterial.uniforms.uCurrentCloud.value = cloudRenderTarget.textures[0];
  taaMaterial.uniforms.uCurrentDistance.value = cloudRenderTarget.textures[1];
  taaMaterial.uniforms.uHistoryCloud.value = taaReadTarget.texture;
  
  if (frameCount === 0) {
    taaMaterial.uniforms.uPreviousViewProjectionMatrix.value.multiplyMatrices(
      camera.projectionMatrix,
      camera.matrixWorldInverse
    );
  } else {
    taaMaterial.uniforms.uPreviousViewProjectionMatrix.value.copy(previousViewProjectionMatrix);
  }
  
  taaMaterial.uniforms.uViewProjectionMatrixInverse.value.multiplyMatrices(
    camera.projectionMatrix,
    camera.matrixWorldInverse
  ).invert();
  taaMaterial.uniforms.uCameraPos.value.copy(camera.position);

  renderer.setRenderTarget(taaWriteTarget);
  renderer.render(taaScene, postCamera);

  // Swap TAA buffers
  const temp = taaReadTarget;
  taaReadTarget = taaWriteTarget;
  taaWriteTarget = temp;
  compositeMaterial.uniforms.uCloudTexture.value = taaReadTarget.texture;

  // 4. Composite pass with mathematically exact pitch-invariant SSR reflection
  const horizonDir = new THREE.Vector3(0, 0, -1).applyQuaternion(
    camera.quaternion,
  );
  horizonDir.y = 0;
  horizonDir.normalize();
  const viewDir = horizonDir.transformDirection(camera.matrixWorldInverse);
  const horizonNDC =
    (camera.projectionMatrix.elements[5] * viewDir.y) / -viewDir.z;
  const horizonUvY = horizonNDC * 0.5 + 0.5;

  (compositeMaterial.uniforms.uProjectionInverse.value as THREE.Matrix4).copy(
    camera.projectionMatrixInverse,
  );
  (compositeMaterial.uniforms.uViewInverse.value as THREE.Matrix4).copy(
    camera.matrixWorld,
  );
  (compositeMaterial.uniforms.uCameraPos.value as THREE.Vector3).copy(
    camera.position,
  );
  compositeMaterial.uniforms.uHorizonUvY.value = horizonUvY;
  compositeMaterial.uniforms.uTime.value += simDelta;

  renderer.setRenderTarget(null);
  renderer.render(compositeScene, postCamera);

  // Update tracking state for next frame
  previousViewProjectionMatrix.multiplyMatrices(
    camera.projectionMatrix,
    camera.matrixWorldInverse
  );
  frameCount++;
}

animate();
