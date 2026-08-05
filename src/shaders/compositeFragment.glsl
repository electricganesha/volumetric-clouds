precision highp float;
varying vec2 vUv;

uniform sampler2D uSceneTexture;
uniform sampler2D uCloudTexture;
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

  // 3x3 Cross-Bilateral Sampling around low-res cloud texel
  vec4 cloudSum = vec4(0.0);
  float weightSum = 0.0;

  for (int x = -1; x <= 1; x++) {
    for (int y = -1; y <= 1; y++) {
      vec2 offset = vec2(float(x), float(y)) * uTexelSize;
      vec2 sampleUv = vUv + offset;

      vec4 cloudSample = texture2D(uCloudTexture, sampleUv);
      float sampleDepth = getLinearDepth(texture2D(uDepthTexture, sampleUv).r);

      float depthDiff = abs(centerDepth - sampleDepth);
      float spatialWeight = exp(-float(x * x + y * y) * 0.5);
      float depthWeight = exp(-depthDiff * 0.02);

      float w = spatialWeight * depthWeight;
      cloudSum += cloudSample * w;
      weightSum += w;
    }
  }

  vec4 cloud = (weightSum > 0.0001) ? (cloudSum / weightSum) : texture2D(uCloudTexture, vUv);

  vec3 color = scene.rgb * (1.0 - cloud.a) + cloud.rgb;

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
