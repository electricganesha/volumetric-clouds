precision highp float;
varying vec3 vWorldDirection;

uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uZenithColor;
uniform vec3 uHorizonColor;
uniform vec3 uSunGlowColor;

void main() {
  vec3 rayDir = normalize(vWorldDirection);
  vec3 lightDir = normalize(uSunDirection);

  float height = clamp(rayDir.y, 0.0, 1.0);
  vec3 sky = mix(uHorizonColor, uZenithColor, pow(height, 0.5));

  float cosTheta = max(dot(rayDir, lightDir), 0.0);
  float sunGlow = pow(cosTheta, 32.0) * 0.7 + pow(cosTheta, 512.0) * 3.0;

  vec3 finalSky = sky + uSunGlowColor * sunGlow;

  if (rayDir.y < 0.0) {
    vec3 groundHaze = mix(uHorizonColor, vec3(0.1, 0.1, 0.15), 0.5);
    finalSky = mix(uHorizonColor, groundHaze, clamp(-rayDir.y * 4.0, 0.0, 1.0));
  }

  gl_FragColor = vec4(finalSky, 1.0);
}
