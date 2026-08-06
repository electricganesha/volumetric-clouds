precision highp sampler3D;

in vec2 vUv;
layout(location = 0) out vec4 fragColor;

// --- Uniforms ---
uniform sampler3D uBaseNoise;
uniform sampler3D uDetailNoise;
uniform sampler2D uWeatherMap;
uniform sampler2D uBlueNoise;
uniform sampler2D uDepthTexture;

uniform int uFrameCount;
uniform vec3 uCameraPos;
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uZenithColor;
uniform vec3 uHorizonColor;

uniform mat4 uProjectionInverse;
uniform mat4 uViewInverse;
uniform vec2 uResolution;
uniform float uTime;
uniform vec2 uJitter;

// Cloud Appearance & Shape Uniforms
uniform float uCloudCoverage;
uniform float uCloudScale;
uniform float uDetailScale;
uniform float uDensityMultiplier;
uniform float uAnisotropy;
uniform float uWarpStrength;

// AAA Lighting Uniforms
uniform float uForwardGlow;
uniform float uShadowIntensity;
uniform float uPowderIntensity;
uniform vec3 uGroundBounceColor;

// Shadow Control Uniforms
uniform float uShadowAbsorption;
uniform float uShadowSoftness;
uniform float uLightStepLength;

// Dynamics Uniforms
uniform vec3 uWindVector;
uniform float uWindShear;
uniform float uMorphSpeed;

uniform vec3 uBoxMin;
uniform vec3 uBoxMax;

// --- Planetary Atmospheric Constants ---
const float PI = 3.14159265359;
const float EARTH_RADIUS = 6371000.0;

float remap(float value, float originalMin, float originalMax, float newMin, float newMax) {
    return newMin + ((value - originalMin) / (originalMax - originalMin)) * (newMax - newMin);
}

// Universal Ray-Spherical Atmosphere Shell Intersection
vec2 raySphericalShellIntersection(vec3 ro, vec3 rd, float innerAlt, float outerAlt) {
    float rInner = EARTH_RADIUS + innerAlt;
    float rOuter = EARTH_RADIUS + outerAlt;

    vec3 pos = vec3(ro.x, ro.y + EARTH_RADIUS, ro.z);

    float b = dot(pos, rd);
    float cInner = dot(pos, pos) - rInner * rInner;
    float cOuter = dot(pos, pos) - rOuter * rOuter;

    float detInner = b * b - cInner;
    float detOuter = b * b - cOuter;

    if (detOuter < 0.0) return vec2(-1.0);

    float tOuter1 = -b - sqrt(detOuter);
    float tOuter2 = -b + sqrt(detOuter);

    if (tOuter2 < 0.0) return vec2(-1.0);

    float tNear = max(tOuter1, 0.0);
    float tFar = tOuter2;

    if (detInner > 0.0) {
        float tInner1 = -b - sqrt(detInner);
        float tInner2 = -b + sqrt(detInner);

        if (tInner1 > 0.0) {
            tFar = min(tFar, tInner1);
        } else if (tInner2 > 0.0) {
            tNear = max(tNear, tInner2);
        }
    }

    return vec2(tNear, tFar);
}

// Spatiotemporal Blue Noise Dithering with Golden Ratio Temporal Accumulation
float blueNoiseDither(vec2 coord, int frame) {
    vec2 blueUv = coord / vec2(64.0);
    float blue = texture(uBlueNoise, blueUv).r;
    float goldenOffset = float(frame % 64) * 0.61803398875;
    return fract(blue + goldenOffset);
}

// Jorge Jimenez Interleaved Gradient Noise (IGN) — Fallback dither
float interleavedGradientNoise(vec2 position) {
    vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
    return fract(magic.z * fract(dot(position, magic.xy)));
}

layout(location = 1) out vec4 fragDistance;

// ACES Filmic Tone Mapping Curve
vec3 toneMapACES(vec3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// Henyey-Greenstein Phase Function
float henyeyGreenstein(float g, float cosTheta) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5));
}

// Dual-Lobe Henyey-Greenstein Phase Function
float dualLobeHG(float g1, float g2, float k, float cosTheta) {
    return mix(henyeyGreenstein(g2, cosTheta), henyeyGreenstein(g1, cosTheta), k);
}

// Sébastien Hillaire's Multi-Octave Multiple Scattering Approximation (Sharpened for Silver Lining)
float calculateMultiScattering(float lightOpticalDepth, float cosTheta, float forwardGlow) {
    float totalScattering = 0.0;
    float energyAttenuation = 1.0;
    float depthAttenuation = 1.0;

    for (int k = 0; k < 3; k++) {
        // Boosted g1 from 0.80 to 0.93 for an intense, crisp forward-scattering rim light
        float g1 = clamp(0.93 * forwardGlow * depthAttenuation, 0.1, 0.98);
        float g2 = -0.30 * depthAttenuation;
        float phase = dualLobeHG(g1, g2, 0.65, cosTheta);

        float octaveOpticalDepth = lightOpticalDepth * depthAttenuation * 0.003 * uShadowAbsorption;
        float octaveTransmittance = exp(-octaveOpticalDepth);

        totalScattering += energyAttenuation * phase * octaveTransmittance;

        energyAttenuation *= 0.5;
        depthAttenuation *= 0.35;
    }

    return totalScattering;
}

// Nubis Dynamic Multi-Type Height Profiling
float getSmoothHeightProfile(float heightFrac, float cloudType) {
    float stratusBase = smoothstep(0.0, 0.03, heightFrac);
    float stratusTop  = 1.0 - smoothstep(0.12, 0.25, heightFrac);
    float stratusProfile = stratusBase * stratusTop;

    float cumulusBase = smoothstep(0.0, 0.04, heightFrac);
    float cumulusTop  = 1.0 - smoothstep(0.45, 0.70, heightFrac);
    float cumulusNorm = clamp(heightFrac / 0.70, 0.0, 1.0);
    float cumulusProfile = cumulusBase * cumulusTop * (0.35 + 0.65 * sin(cumulusNorm * PI));

    float cbTowerBase = smoothstep(0.0, 0.04, heightFrac);
    float cbTowerTop  = 1.0 - smoothstep(0.92, 0.98, heightFrac);
    float cbTower     = cbTowerBase * cbTowerTop * 0.75;
    float anvil = smoothstep(0.62, 0.82, heightFrac) * (1.0 - smoothstep(0.94, 0.98, heightFrac)) * 0.85;
    float cbProfile = max(cbTower, anvil);

    float lowToMid = smoothstep(0.0, 0.5, cloudType);
    float midToHigh = smoothstep(0.5, 1.0, cloudType);

    float blendedMid = mix(stratusProfile, cumulusProfile, lowToMid);
    return mix(blendedMid, cbProfile, midToHigh);
}

// Hierarchical Empty Space Skipping: Fast 2D Weather Coverage & Height Pre-Check
float sampleFastCoverage(vec3 p) {
    vec3 earthCenterPos = vec3(p.x, p.y + EARTH_RADIUS, p.z);
    float altitude = length(earthCenterPos) - EARTH_RADIUS;

    float heightFrac = clamp((altitude - uBoxMin.y) / (uBoxMax.y - uBoxMin.y), 0.0, 1.0);
    if (heightFrac <= 0.0 || heightFrac >= 1.0) return 0.0;

    vec2 weatherUv = p.xz * 0.000005 + uWindVector.xz * uTime * 0.000003;
    vec4 weatherSample = texture(uWeatherMap, weatherUv);
    float coverage = clamp(weatherSample.r * uCloudCoverage, 0.0, 1.0);
    if (coverage <= 0.005) return 0.0;

    float heightProfile = getSmoothHeightProfile(heightFrac, weatherSample.g);
    return coverage * heightProfile;
}

// Non-Repeating Organic Cloud Density Sampling
float sampleCloudDensity(vec3 p, float distFromCam) {
    vec3 earthCenterPos = vec3(p.x, p.y + EARTH_RADIUS, p.z);
    float altitude = length(earthCenterPos) - EARTH_RADIUS;

    float heightFrac = clamp((altitude - uBoxMin.y) / (uBoxMax.y - uBoxMin.y), 0.0, 1.0);
    if (heightFrac <= 0.0 || heightFrac >= 1.0) return 0.0;

    vec2 weatherUv = p.xz * 0.000005 + uWindVector.xz * uTime * 0.000003;
    vec4 weatherSample = texture(uWeatherMap, weatherUv);

    float coverage = clamp(weatherSample.r * uCloudCoverage, 0.0, 1.0);
    if (coverage <= 0.01) return 0.0;

    float cloudType = weatherSample.g;
    float weatherDensityMultiplier = weatherSample.b * 0.4 + 0.8;

    float heightProfile = getSmoothHeightProfile(heightFrac, cloudType);
    if (heightProfile <= 0.001) return 0.0;

    vec3 windShearVec = uWindVector * (1.0 + heightFrac * uWindShear);

    vec3 boilingDrift = vec3(
        sin(p.z * 0.0002 + uTime * 0.06 * uMorphSpeed),
        uTime * 0.08 * uMorphSpeed,
        cos(p.x * 0.0002 + uTime * 0.06 * uMorphSpeed)
    ) * 350.0;

    vec3 warpVector = vec3(
        sin(p.z * 0.000035),
        0.0,
        cos(p.x * 0.000035)
    ) * (uWarpStrength * 3000.0);

    vec3 samplePosWarped = p + windShearVec * uTime * 0.25 + boilingDrift + warpVector;

    vec3 aspectScale = vec3(1.0, uAnisotropy, 1.0);
    vec3 baseSamplePos1 = (samplePosWarped * aspectScale) * (uCloudScale * 0.00008);
    vec3 baseSamplePos2 = ((samplePosWarped + vec3(173.1, 421.7, 89.3)) * aspectScale) * (uCloudScale * 0.000029);

    vec4 baseNoise1 = texture(uBaseNoise, baseSamplePos1);
    vec4 baseNoise2 = texture(uBaseNoise, baseSamplePos2);

    float worleyFBM1 = baseNoise1.g * 0.625 + baseNoise1.b * 0.25 + baseNoise1.a * 0.125;
    float fluffyBase1 = remap(baseNoise1.r, -(1.0 - worleyFBM1), 1.0, 0.0, 1.0);

    float worleyFBM2 = baseNoise2.g * 0.625 + baseNoise2.b * 0.25 + baseNoise2.a * 0.125;
    float fluffyBase2 = remap(baseNoise2.r, -(1.0 - worleyFBM2), 1.0, 0.0, 1.0);

    float baseCloudShape = mix(fluffyBase1, fluffyBase2, 0.5) * heightProfile;

    float density = remap(baseCloudShape, 1.0 - coverage, 1.0, 0.0, 1.0);
    if (density <= 0.01) return 0.0;

    // LOD Optimization: Skip 3D detail noise for distant clouds (>40km)
    if (distFromCam < 40000.0) {
        vec3 detailBoiling = vec3(
            cos(p.y * 0.0005 + uTime * 0.12 * uMorphSpeed),
            uTime * 0.18 * uMorphSpeed,
            sin(p.y * 0.0005 + uTime * 0.12 * uMorphSpeed)
        ) * 200.0;

        vec3 detailPos = (p + windShearVec * uTime * 0.5 + detailBoiling + warpVector * 0.2) * (uDetailScale * 0.00145);
        vec4 detailNoise = texture(uDetailNoise, detailPos);
        
        float highFreqFBM = detailNoise.r * 0.625 + detailNoise.g * 0.25 + detailNoise.b * 0.125;

        float erosionModifier = mix(1.0 - highFreqFBM, highFreqFBM, clamp(heightFrac * 3.0, 0.0, 1.0));
        density = remap(density, erosionModifier * 0.35, 1.0, 0.0, 1.0);
    }
    
    return clamp(density, 0.0, 1.0) * uDensityMultiplier * weatherDensityMultiplier;
}

// Fast Lightweight Density Evaluation for Shadow Pass
float sampleCloudDensityFast(vec3 p) {
    vec3 earthCenterPos = vec3(p.x, p.y + EARTH_RADIUS, p.z);
    float altitude = length(earthCenterPos) - EARTH_RADIUS;

    float heightFrac = clamp((altitude - uBoxMin.y) / (uBoxMax.y - uBoxMin.y), 0.0, 1.0);
    if (heightFrac <= 0.0 || heightFrac >= 1.0) return 0.0;

    float boxFalloff = 1.0;

    vec2 weatherUv = p.xz * 0.000005 + uWindVector.xz * uTime * 0.000003;
    vec4 weatherSample = texture(uWeatherMap, weatherUv);

    float coverage = clamp(weatherSample.r * uCloudCoverage, 0.0, 1.0);
    if (coverage <= 0.01) return 0.0;

    float cloudType = weatherSample.g;
    float weatherDensityMultiplier = weatherSample.b * 0.4 + 0.8;

    float heightProfile = getSmoothHeightProfile(heightFrac, cloudType);
    if (heightProfile <= 0.001) return 0.0;

    vec3 windShearVec = uWindVector * (1.0 + heightFrac * uWindShear);
    vec3 samplePosWarped = p + windShearVec * uTime * 0.25;

    vec3 aspectScale = vec3(1.0, uAnisotropy, 1.0);
    vec3 baseSamplePos1 = (samplePosWarped * aspectScale) * (uCloudScale * 0.00008);

    vec4 baseNoise1 = texture(uBaseNoise, baseSamplePos1);
    
    float worleyFBM1 = baseNoise1.g * 0.625 + baseNoise1.b * 0.25 + baseNoise1.a * 0.125;
    float fluffyBase = remap(baseNoise1.r, -(1.0 - worleyFBM1), 1.0, 0.0, 1.0);

    float baseCloudShape = fluffyBase * heightProfile;

    float density = remap(baseCloudShape, 1.0 - coverage, 1.0, 0.0, 1.0);
    if (density <= 0.01) return 0.0;

    return clamp(density, 0.0, 1.0) * boxFalloff * uDensityMultiplier * weatherDensityMultiplier;
}

// Volumetric Shadow Caching & Analytical Transmittance Model
float calculateLightOpticalDepth(vec3 pos, float dither, float distFromCam) {
    vec3 lightDir = normalize(uSunDirection);
    
    float sunElevationSin = max(abs(lightDir.y), 0.15);
    float shadowStepSize = (uLightStepLength / sunElevationSin) * uShadowSoftness;

    // 1. Calculate top-down column optical depth cache along sun ray
    vec3 earthCenterPos = vec3(pos.x, pos.y + EARTH_RADIUS, pos.z);
    float altitude = length(earthCenterPos) - EARTH_RADIUS;
    float remainingHeight = max(0.0, uBoxMax.y - altitude);
    float remainingDist = remainingHeight / sunElevationSin;

    // Sample 2D weather coverage along sun ray offset
    vec3 sunOffsetPos = pos + lightDir * (shadowStepSize * 2.0);
    float fastSunCoverage = sampleFastCoverage(sunOffsetPos);

    // Cached column optical depth from current altitude up to top of cloud layer
    float cachedOpticalDepth = fastSunCoverage * remainingDist * 0.00035 * uDensityMultiplier;

    // 2. High-frequency local contact shadow sample (1 single micro-step)
    vec3 contactPos = pos + lightDir * (shadowStepSize * dither);
    float localContactDensity = sampleCloudDensityFast(contactPos);
    float localOpticalDepth = localContactDensity * shadowStepSize;

    return cachedOpticalDepth + localOpticalDepth;
}

void main() {
    vec2 ndc = vUv * 2.0 - 1.0 + uJitter;

    // 1. Reconstruct World Ray Direction
    vec4 viewDir = uProjectionInverse * vec4(ndc, -1.0, 1.0);
    vec3 rayDirWorld = (uViewInverse * vec4(viewDir.xyz, 0.0)).xyz;
    vec3 rayDir = normalize(rayDirWorld);

    // 2. Depth Capping
    float rawDepth = texture(uDepthTexture, vUv).r;
    float tMaxScene = 1e8;
    if (rawDepth < 0.99999) {
        vec4 viewPos = uProjectionInverse * vec4(ndc, rawDepth * 2.0 - 1.0, 1.0);
        viewPos /= viewPos.w;
        vec4 worldPosScene = uViewInverse * viewPos;
        // Only cap depth if scene geometry is inside or above the cloud volume (e.g. high mountains)
        if (worldPosScene.y >= uBoxMin.y) {
            float terrainDist = length(worldPosScene.xyz - uCameraPos);
            vec2 testAtmos = raySphericalShellIntersection(uCameraPos, rayDir, uBoxMin.y, uBoxMax.y);
            if (terrainDist > max(testAtmos.x, 0.0)) {
                tMaxScene = terrainDist;
            }
        }
    }

    // 3. Spherical Atmosphere Ray Intersection
    vec2 rayAtmosphere = raySphericalShellIntersection(uCameraPos, rayDir, uBoxMin.y, uBoxMax.y);
    float tNear = rayAtmosphere.x;
    float tFar = rayAtmosphere.y;

    if (tNear >= tFar || tFar <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    tNear = max(tNear, 0.0);
    tFar = min(tFar, tMaxScene);

    // 4. Raymarching Step Setup
    const int MAX_STEPS = 64;
    float slabDist  = tFar - tNear;
    float stepScale = clamp(slabDist / 20000.0, 1.0, 3.0);

    float FINE_STEP  = 45.0 * stepScale;   
    float EMPTY_STEP = FINE_STEP * 2.5;    
    float MACRO_STEP = EMPTY_STEP * 3.5;

    float ditherVal = blueNoiseDither(gl_FragCoord.xy, uFrameCount);
    
    float currentStepSize = EMPTY_STEP;
    float t = tNear + ditherVal * currentStepSize;

    vec3 lightDir = normalize(uSunDirection);
    float cosTheta = dot(rayDir, lightDir);
    float rimCosTheta = clamp(cosTheta, -0.9, 1.0);

    vec3 accumulatedColor = vec3(0.0);
    float transmittance = 1.0;
    bool inCloud = false;

    for (int i = 0; i < MAX_STEPS; i++) {
        if (t >= tFar || transmittance < 0.01) break;

        vec3 currentPos = uCameraPos + rayDir * t;
        float distFromCam = t;

        // Level 1 Hierarchical Empty Space Skipping: Fast 2D Weather & Height Envelope Pre-Check
        float fastCoverage = sampleFastCoverage(currentPos);
        if (fastCoverage <= 0.001) {
            if (inCloud) {
                inCloud = false;
                currentStepSize = EMPTY_STEP;
            }
            // Ray is in clear space — macro-skip ahead without sampling 3D noise textures
            t += MACRO_STEP;
            continue;
        }

        // Level 2: Density Evaluation & Micro-Stepping Boundary Transition
        float density = sampleCloudDensity(currentPos, distFromCam);

        if (density > 0.001) {
            if (!inCloud) {
                inCloud = true;
                // Backtrack 1 step to hit exact cloud boundary, then switch to fine steps
                t -= currentStepSize;
                currentStepSize = FINE_STEP;
                t += currentStepSize;
                continue; 
            }

            vec3 earthCenterPos = vec3(currentPos.x, currentPos.y + EARTH_RADIUS, currentPos.z);
            float altitude = length(earthCenterPos) - EARTH_RADIUS;
            float heightFrac = clamp((altitude - uBoxMin.y) / (uBoxMax.y - uBoxMin.y), 0.0, 1.0);

            // Light Optical Depth Transmittance
            float lightOpticalDepth = calculateLightOpticalDepth(currentPos, ditherVal, distFromCam);
            float primaryAttenuation = exp(-lightOpticalDepth * 0.0025 * uShadowAbsorption);

            // Powder Term Blend Logic
            float powderTerm = 1.0 - exp(-density * currentStepSize * 0.15 * uPowderIntensity);
            float powderMix = clamp(-cosTheta * 0.5 + 0.5, 0.0, 1.0);
            float shadowLightAttenuation = primaryAttenuation * mix(1.0, powderTerm * 2.0, powderMix);

            // Multi-Scattering Phase
            float multiScatteringPhase = calculateMultiScattering(lightOpticalDepth, rimCosTheta, uForwardGlow);

            // Direct Sunlight
            vec3 directLight = uSunColor * 5.0 * multiScatteringPhase * shadowLightAttenuation;

            // Ambient Occlusion and Bounced Light
            vec3 skyAmbient = mix(uHorizonColor, uZenithColor, heightFrac);
            vec3 groundAmbient = uGroundBounceColor * (1.0 - heightFrac);
            float cloudAmbientOcclusion = mix(0.3, 1.0, exp(-density * 1.5)); 
            
            vec3 ambientLight = (skyAmbient * 0.65 + groundAmbient * 0.35) * cloudAmbientOcclusion * uShadowIntensity;

            // Deep Base / Bright Top Dynamic Tinting
            vec3 cloudTopTint  = mix(vec3(0.95, 0.96, 1.0), uSunColor, 0.15);
            vec3 cloudBaseTint = vec3(0.55, 0.60, 0.68); 
            vec3 cloudBodyColor = mix(cloudBaseTint, cloudTopTint, heightFrac * 0.6 + shadowLightAttenuation * 0.4);

            vec3 stepLight = directLight * cloudBodyColor + ambientLight;

            // Volumetric Integration
            float sigmaExtDynamic = mix(0.04, 0.14, density); 
            float stepExtinction = density * currentStepSize * sigmaExtDynamic;
            float stepTransmittance = exp(-stepExtinction);

            vec3 integratedLight = stepLight * (1.0 - stepTransmittance);

            accumulatedColor += transmittance * integratedLight;
            transmittance *= stepTransmittance;

        } else {
            if (inCloud) {
                inCloud = false;
                currentStepSize = EMPTY_STEP;
            } else {
                currentStepSize = min(currentStepSize * 1.25, EMPTY_STEP * 1.5);
            }
        }
        
        t += currentStepSize;
    }

    // High-Altitude Cirrus Pass (2D Planar Layer)
    if (transmittance > 0.05 && rayDir.y > 0.02) {
        float cirrusAlt = 8500.0;
        float tCirrus = (cirrusAlt - uCameraPos.y) / rayDir.y;
        if (tCirrus > 0.0 && tCirrus < tMaxScene) {
            vec3 pCirrus = uCameraPos + rayDir * tCirrus;
            vec2 cirrusUv = pCirrus.xz * 0.000015 + uWindVector.xz * uTime * 0.000008;

            vec4 cirrusTex = texture(uWeatherMap, cirrusUv);
            float cirrusNoise1 = texture(uWeatherMap, cirrusUv * 2.5 + vec2(uTime * 0.005)).g;
            float cirrusNoise2 = texture(uWeatherMap, cirrusUv * 5.0 - vec2(uTime * 0.003)).r;

            float cirrusFBM = cirrusNoise1 * 0.6 + cirrusNoise2 * 0.4;
            float cirrusCoverage = smoothstep(0.35, 0.75, cirrusTex.r * cirrusFBM);
            float cirrusAlpha = cirrusCoverage * 0.40 * transmittance;

            if (cirrusAlpha > 0.005) {
                vec3 cirrusColor = mix(vec3(0.95, 0.97, 1.0), uSunColor * 1.2, max(0.0, dot(rayDir, lightDir)) * 0.5);
                accumulatedColor += transmittance * cirrusColor * cirrusAlpha;
                transmittance *= (1.0 - cirrusAlpha);
            }
        }
    }

    // Horizon Haze Aerial Perspective
    float horizonDist = tFar - tNear;
    float hazeFactor  = 1.0 - exp(-horizonDist * 0.000005);
    accumulatedColor = mix(accumulatedColor, uHorizonColor * 0.9, hazeFactor * 0.35);

    float alpha = clamp(1.0 - transmittance, 0.0, 1.0);

    // ACES Filmic Tone Mapping
    vec3 toneMappedColor = toneMapACES(accumulatedColor * 1.10);

    // Output Dithering
    vec3 ditheredColor = toneMappedColor + (ditherVal - 0.5) / 255.0;

    fragColor = vec4(max(vec3(0.0), ditheredColor), alpha);
    fragDistance = vec4(t, 0.0, 0.0, 1.0);
}
