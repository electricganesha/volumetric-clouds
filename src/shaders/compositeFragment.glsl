precision highp float;
varying vec2 vUv;

uniform sampler2D uSceneTexture;
uniform sampler2D uCloudTexture;
uniform sampler2D uCloudDistance;
uniform sampler2D uDepthTexture;
uniform vec2 uTexelSize;
uniform mat4 uProjectionInverse;
uniform mat4 uViewInverse;
uniform vec3 uCameraPos;
uniform float uHorizonUvY;
uniform float uTime;

// Post-Processing Toggle & Granular Controls
uniform bool uEnableChromaticAberration;
uniform float uAberrationOffset;

// Sun Position & Atmospheric Light Shafts
uniform vec2 uSunScreenPos;
uniform vec3 uSunColor;
uniform vec3 uSunDirection;
uniform float uSunVisibility;
uniform float uAspectRatio;

// Horizon Fog & Atmospheric Melding
uniform bool uEnableHorizonFog;
uniform float uHorizonFogDensity;
uniform float uHorizonFogHeight;
uniform vec3 uHorizonColor;

uniform bool uEnableGodRays;
uniform float uGodRayIntensity;
uniform float uGodRayDecay;
uniform float uGodRayDensity;
uniform float uGodRayWeight;

uniform bool uEnableSunBloom;
uniform float uBloomIntensity;
uniform float uBloomRadius;

uniform bool uEnableColorGrading;
uniform float uContrast;
uniform float uSaturation;
uniform float uSplitToningShadow;
uniform float uSplitToningHighlight;

uniform bool uEnableVignette;
uniform float uVignetteDarkness;
uniform float uVignetteFalloff;

uniform bool uEnableFilmGrain;
uniform float uFilmGrainAmount;

float getLinearDepth(float rawDepth) {
  vec4 viewPos = uProjectionInverse * vec4(vUv * 2.0 - 1.0, rawDepth * 2.0 - 1.0, 1.0);
  return abs(viewPos.z / viewPos.w);
}

// --- Interleaved gradient noise for film grain ---
float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// --- Contrast curve ---
vec3 contrastCurve(vec3 c, float contrast) {
  return c / (c + 0.15) * contrast;
}

void main() {
  vec2 center = vUv - 0.5;
  vec4 scene;

  if (uEnableChromaticAberration && uAberrationOffset > 0.0) {
    // --- Chromatic aberration: sample R/B channels with screen-edge offset ---
    float aberration = uAberrationOffset * dot(center, center);
    vec2 rUv = vUv + center * aberration;
    vec2 bUv = vUv - center * aberration;

    scene.r = texture2D(uSceneTexture, rUv).r;
    scene.g = texture2D(uSceneTexture, vUv).g;
    scene.b = texture2D(uSceneTexture, bUv).b;
    scene.a = 1.0;
  } else {
    scene = texture2D(uSceneTexture, vUv);
  }

  float rawDepth = texture2D(uDepthTexture, vUv).r;
  float centerDepth = getLinearDepth(rawDepth);

  // --- Horizon Atmospheric Fog (Melds Sea & Sky Seamlessly) ---
  if (uEnableHorizonFog) {
    vec4 ndc = vec4(vUv * 2.0 - 1.0, 1.0, 1.0);
    vec4 viewDir = uProjectionInverse * ndc;
    vec3 rayDirWorld = normalize((uViewInverse * vec4(viewDir.xyz, 0.0)).xyz);

    float angle = rayDirWorld.y;
    // Sea surface (angle < 0) has a slightly broader maritime mist falloff
    float effectiveHeight = (angle < 0.0) ? (uHorizonFogHeight * 1.4) : uHorizonFogHeight;
    float fogBand = exp(-pow(abs(angle) / max(0.001, effectiveHeight), 1.8));

    // Sun forward-scattering glow in the horizon mist
    float sunScattering = max(dot(rayDirWorld, normalize(uSunDirection)), 0.0);
    vec3 mistSunGlow = uSunColor * pow(sunScattering, 6.0) * 0.45;
    vec3 mistColor = uHorizonColor + mistSunGlow;

    // Distant ocean and sky have large depth; close water has small depth
    float dist = (rawDepth >= 0.99999) ? 100000.0 : centerDepth;
    float depthMask = smoothstep(2000.0, 20000.0, dist);

    float totalFog = fogBand * uHorizonFogDensity * depthMask;
    scene.rgb = mix(scene.rgb, mistColor, clamp(totalFog, 0.0, 1.0));
  }

  vec4 cloud = texture2D(uCloudTexture, vUv);
  float cloudDistance = texture2D(uCloudDistance, vUv).r;

  // If cloud is behind the terrain, occlude it
  if (cloudDistance > centerDepth && centerDepth < 250000.0) {
      cloud.a = 0.0;
  }

  vec3 color = scene.rgb * (1.0 - cloud.a) + cloud.rgb;

  // --- Volumetric God Rays (Crepuscular Light Shafts) ---
  if (uEnableGodRays && uSunVisibility > 0.01) {
    vec2 deltaTexCoord = (vUv - uSunScreenPos);
    deltaTexCoord *= (1.0 / 24.0) * uGodRayDensity;
    vec2 sampleCoord = vUv;
    float illuminationDecay = 1.0;
    float godRayScattering = 0.0;

    // Spatial dither to break radial stepping rings
    sampleCoord -= deltaTexCoord * (hash(vUv * 200.0 + fract(uTime * 0.05)) * 0.75);

    for (int i = 0; i < 24; i++) {
      sampleCoord -= deltaTexCoord;
      if (sampleCoord.x >= 0.0 && sampleCoord.x <= 1.0 && sampleCoord.y >= 0.0 && sampleCoord.y <= 1.0) {
        vec4 cloudSample = texture2D(uCloudTexture, sampleCoord);
        // Cloud occlusion: gaps let light stream through, thick cloud blocks it
        float sampleOcc = clamp(1.0 - cloudSample.a * 1.25, 0.0, 1.0);
        
        float distToSun = length((sampleCoord - uSunScreenPos) * vec2(uAspectRatio, 1.0));
        float radialFalloff = 1.0 / (distToSun * 3.5 + 1.0);

        godRayScattering += sampleOcc * radialFalloff * illuminationDecay * uGodRayWeight;
        illuminationDecay *= uGodRayDecay;
      }
    }

    vec3 godRays = godRayScattering * uSunColor * uGodRayIntensity * uSunVisibility;
    color += godRays;
  }

  // --- Physical Sun Bloom & Silver Lining Radiance ---
  if (uEnableSunBloom && uSunVisibility > 0.01) {
    vec2 sunDiff = (vUv - uSunScreenPos) * vec2(uAspectRatio, 1.0);
    float sunDist = length(sunDiff);

    float coreBloom = exp(-sunDist * 16.0 * (1.0 / max(0.1, uBloomRadius))) * 1.4;
    float broadGlow = exp(-sunDist * 3.2 * (1.0 / max(0.1, uBloomRadius))) * 0.4;
    float totalBloom = (coreBloom + broadGlow) * uBloomIntensity;

    // Transmittance through clouds (bright light bleeds over cloud silhouettes)
    float bloomTransmittance = mix(1.0, 0.35, smoothstep(0.1, 0.85, cloud.a));

    // Silver lining radiance: high luminance cloud highlights bleed softly
    float cloudLuma = dot(cloud.rgb, vec3(0.299, 0.587, 0.114));
    float silverRadiance = smoothstep(0.65, 1.1, cloudLuma) * 0.25 * uBloomIntensity;

    color += (totalBloom * bloomTransmittance + silverRadiance) * uSunColor;
  }

  // --- Color grading ---
  if (uEnableColorGrading) {
    // 1. Contrast
    color = contrastCurve(color, uContrast);
    // 2. Saturation boost
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(vec3(luma), color, uSaturation);
    // 3. Split toning: warm shadows, cool highlights
    vec3 warmShadow = vec3(1.04, 1.01, 0.96);
    vec3 coolHighlight = vec3(0.97, 0.99, 1.03);
    float shadowMask = clamp(1.0 - luma * 2.0, 0.0, 1.0);
    float highlightMask = clamp(luma * 2.0 - 1.0, 0.0, 1.0);
    color *= mix(vec3(1.0), warmShadow, shadowMask * uSplitToningShadow);
    color *= mix(vec3(1.0), coolHighlight, highlightMask * uSplitToningHighlight);
  }

  // --- Vignette: smooth darkness at screen edges ---
  if (uEnableVignette && uVignetteDarkness > 0.0) {
    float vignDist = dot(center, center);
    float vignette = 1.0 - smoothstep(0.3, max(0.31, uVignetteFalloff), vignDist * 1.6);
    color *= mix(1.0, vignette, uVignetteDarkness);
  }

  // --- Animated film grain ---
  if (uEnableFilmGrain && uFilmGrainAmount > 0.0) {
    float grain = hash(vUv + fract(uTime * 0.017)) * 2.0 - 1.0;
    color += grain * uFilmGrainAmount;
  }

  gl_FragColor = vec4(max(color, vec3(0.0)), 1.0);
}
