struct Uniforms {
    cameraPos: vec3<f32>,
    time: f32,
    
    sunDirection: vec3<f32>,
    cloudCoverage: f32,
    
    sunColor: vec3<f32>,
    cloudScale: f32,
    
    zenithColor: vec3<f32>,
    detailScale: f32,
    
    horizonColor: vec3<f32>,
    densityMultiplier: f32,
    
    groundBounceColor: vec3<f32>,
    anisotropy: f32,
    
    windVector: vec3<f32>,
    warpStrength: f32,
    
    boxMin: vec3<f32>,
    forwardGlow: f32,
    
    boxMax: vec3<f32>,
    shadowIntensity: f32,
    
    resolution: vec2<f32>,
    jitter: vec2<f32>,
    
    powderIntensity: f32,
    shadowAbsorption: f32,
    shadowSoftness: f32,
    lightStepLength: f32,
    
    windShear: f32,
    morphSpeed: f32,
    pad1: f32,
    pad2: f32,
    
    viewInverse: mat4x4<f32>,
    projInverse: mat4x4<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var outColorTexture: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(2) var outDistanceTexture: texture_storage_2d<rgba16float, write>;
@group(0) @binding(3) var uBaseNoise: texture_3d<f32>;
@group(0) @binding(4) var uDetailNoise: texture_3d<f32>;
@group(0) @binding(5) var uWeatherMap: texture_2d<f32>;
@group(0) @binding(6) var smp: sampler;

const PI = 3.14159265359;
const EARTH_RADIUS = 6371000.0;

fn remap(value: f32, originalMin: f32, originalMax: f32, newMin: f32, newMax: f32) -> f32 {
    return newMin + ((value - originalMin) / (originalMax - originalMin)) * (newMax - newMin);
}

fn raySphericalShellIntersection(ro: vec3<f32>, rd: vec3<f32>, innerAlt: f32, outerAlt: f32) -> vec2<f32> {
    let rInner = EARTH_RADIUS + innerAlt;
    let rOuter = EARTH_RADIUS + outerAlt;

    let pos = vec3<f32>(ro.x, ro.y + EARTH_RADIUS, ro.z);

    let b = dot(pos, rd);
    let cInner = dot(pos, pos) - rInner * rInner;
    let cOuter = dot(pos, pos) - rOuter * rOuter;

    let detInner = b * b - cInner;
    let detOuter = b * b - cOuter;

    if (detOuter < 0.0) { return vec2<f32>(-1.0, -1.0); }

    let tOuter1 = -b - sqrt(detOuter);
    let tOuter2 = -b + sqrt(detOuter);

    if (tOuter2 < 0.0) { return vec2<f32>(-1.0, -1.0); }

    var tNear = max(tOuter1, 0.0);
    var tFar = tOuter2;

    if (detInner > 0.0) {
        let tInner1 = -b - sqrt(detInner);
        let tInner2 = -b + sqrt(detInner);

        if (tInner1 > 0.0) {
            tFar = min(tFar, tInner1);
        } else if (tInner2 > 0.0) {
            tNear = max(tNear, tInner2);
        }
    }

    return vec2<f32>(tNear, tFar);
}

fn spatiotemporalDither(position: vec2<f32>, time: f32) -> f32 {
    let magic = vec3<f32>(0.06711056, 0.00583715, 52.9829189);
    let base = fract(magic.z * fract(dot(position, magic.xy)));
    let goldenTemporal = fract(time * 0.61803398875);
    return fract(base + goldenTemporal);
}

fn interleavedGradientNoise(position: vec2<f32>) -> f32 {
    let magic = vec3<f32>(0.06711056, 0.00583715, 52.9829189);
    return fract(magic.z * fract(dot(position, magic.xy)));
}

fn toneMapACES(x: vec3<f32>) -> vec3<f32> {
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3<f32>(0.0), vec3<f32>(1.0));
}

fn henyeyGreenstein(g: f32, cosTheta: f32) -> f32 {
    let g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5));
}

fn dualLobeHG(g1: f32, g2: f32, k: f32, cosTheta: f32) -> f32 {
    return mix(henyeyGreenstein(g2, cosTheta), henyeyGreenstein(g1, cosTheta), k);
}

fn calculateMultiScattering(lightOpticalDepth: f32, cosTheta: f32, forwardGlow: f32) -> f32 {
    var totalScattering = 0.0;
    var energyAttenuation = 1.0;
    var depthAttenuation = 1.0;

    for (var k = 0; k < 3; k++) {
        let g1 = clamp(0.93 * forwardGlow * depthAttenuation, 0.1, 0.98);
        let g2 = -0.30 * depthAttenuation;
        let phase = dualLobeHG(g1, g2, 0.65, cosTheta);

        let octaveOpticalDepth = lightOpticalDepth * depthAttenuation * 0.003 * uniforms.shadowAbsorption;
        let octaveTransmittance = exp(-octaveOpticalDepth);

        totalScattering += energyAttenuation * phase * octaveTransmittance;

        energyAttenuation *= 0.5;
        depthAttenuation *= 0.35;
    }

    return totalScattering;
}

fn getSmoothHeightProfile(heightFrac: f32, cloudType: f32) -> f32 {
    let stratusBase = smoothstep(0.0, 0.03, heightFrac);
    let stratusTop  = 1.0 - smoothstep(0.12, 0.25, heightFrac);
    let stratusProfile = stratusBase * stratusTop;

    let cumulusBase = smoothstep(0.0, 0.04, heightFrac);
    let cumulusTop  = 1.0 - smoothstep(0.45, 0.70, heightFrac);
    let cumulusNorm = clamp(heightFrac / 0.70, 0.0, 1.0);
    let cumulusProfile = cumulusBase * cumulusTop * (0.35 + 0.65 * sin(cumulusNorm * PI));

    let cbTowerBase = smoothstep(0.0, 0.04, heightFrac);
    let cbTowerTop  = 1.0 - smoothstep(0.92, 0.98, heightFrac);
    let cbTower     = cbTowerBase * cbTowerTop * 0.75;
    let anvil = smoothstep(0.62, 0.82, heightFrac) * (1.0 - smoothstep(0.94, 0.98, heightFrac)) * 0.85;
    let cbProfile = max(cbTower, anvil);

    let lowToMid = smoothstep(0.0, 0.5, cloudType);
    let midToHigh = smoothstep(0.5, 1.0, cloudType);

    let blendedMid = mix(stratusProfile, cumulusProfile, lowToMid);
    return mix(blendedMid, cbProfile, midToHigh);
}

fn sampleFastCoverage(p: vec3<f32>) -> f32 {
    let earthCenterPos = vec3<f32>(p.x, p.y + EARTH_RADIUS, p.z);
    let altitude = length(earthCenterPos) - EARTH_RADIUS;

    let heightFrac = clamp((altitude - uniforms.boxMin.y) / (uniforms.boxMax.y - uniforms.boxMin.y), 0.0, 1.0);
    if (heightFrac <= 0.0 || heightFrac >= 1.0) { return 0.0; }

    let weatherUv = p.xz * 0.000005 + uniforms.windVector.xz * uniforms.time * 0.000003;
    let weatherSample = textureSampleLevel(uWeatherMap, smp, weatherUv, 0.0);

    let coverage = clamp(weatherSample.r * uniforms.cloudCoverage, 0.0, 1.0);
    if (coverage <= 0.005) { return 0.0; }

    let heightProfile = getSmoothHeightProfile(heightFrac, weatherSample.g);
    return coverage * heightProfile;
}

fn sampleCloudDensity(p: vec3<f32>, distFromCam: f32) -> f32 {
    let earthCenterPos = vec3<f32>(p.x, p.y + EARTH_RADIUS, p.z);
    let altitude = length(earthCenterPos) - EARTH_RADIUS;

    let heightFrac = clamp((altitude - uniforms.boxMin.y) / (uniforms.boxMax.y - uniforms.boxMin.y), 0.0, 1.0);
    if (heightFrac <= 0.0 || heightFrac >= 1.0) { return 0.0; }

    let weatherUv = p.xz * 0.000005 + uniforms.windVector.xz * uniforms.time * 0.000003;
    let weatherSample = textureSampleLevel(uWeatherMap, smp, weatherUv, 0.0);

    let coverage = clamp(weatherSample.r * uniforms.cloudCoverage, 0.0, 1.0);
    if (coverage <= 0.01) { return 0.0; }

    let cloudType = weatherSample.g;
    let weatherDensityMultiplier = weatherSample.b * 0.4 + 0.8;

    let heightProfile = getSmoothHeightProfile(heightFrac, cloudType);
    if (heightProfile <= 0.001) { return 0.0; }

    let windShearVec = uniforms.windVector * (1.0 + heightFrac * uniforms.windShear);

    let boilingDrift = vec3<f32>(
        sin(p.z * 0.0002 + uniforms.time * 0.06 * uniforms.morphSpeed),
        uniforms.time * 0.08 * uniforms.morphSpeed,
        cos(p.x * 0.0002 + uniforms.time * 0.06 * uniforms.morphSpeed)
    ) * 350.0;

    let warpVector = vec3<f32>(
        sin(p.z * 0.000035),
        0.0,
        cos(p.x * 0.000035)
    ) * (uniforms.warpStrength * 3000.0);

    let samplePosWarped = p + windShearVec * uniforms.time * 0.25 + boilingDrift + warpVector;

    let aspectScale = vec3<f32>(1.0, uniforms.anisotropy, 1.0);
    let baseSamplePos1 = (samplePosWarped * aspectScale) * (uniforms.cloudScale * 0.00008);
    let baseSamplePos2 = ((samplePosWarped + vec3<f32>(173.1, 421.7, 89.3)) * aspectScale) * (uniforms.cloudScale * 0.000029);

    let baseNoise1 = textureSampleLevel(uBaseNoise, smp, baseSamplePos1, 0.0);
    let baseNoise2 = textureSampleLevel(uBaseNoise, smp, baseSamplePos2, 0.0);

    let worleyFBM1 = baseNoise1.g * 0.625 + baseNoise1.b * 0.25 + baseNoise1.a * 0.125;
    let fluffyBase1 = remap(baseNoise1.r, -(1.0 - worleyFBM1), 1.0, 0.0, 1.0);

    let worleyFBM2 = baseNoise2.g * 0.625 + baseNoise2.b * 0.25 + baseNoise2.a * 0.125;
    let fluffyBase2 = remap(baseNoise2.r, -(1.0 - worleyFBM2), 1.0, 0.0, 1.0);

    let baseCloudShape = mix(fluffyBase1, fluffyBase2, 0.5) * heightProfile;

    var density = remap(baseCloudShape, 1.0 - coverage, 1.0, 0.0, 1.0);
    if (density <= 0.01) { return 0.0; }

    if (distFromCam < 40000.0) {
        let detailBoiling = vec3<f32>(
            cos(p.y * 0.0005 + uniforms.time * 0.12 * uniforms.morphSpeed),
            uniforms.time * 0.18 * uniforms.morphSpeed,
            sin(p.y * 0.0005 + uniforms.time * 0.12 * uniforms.morphSpeed)
        ) * 200.0;

        let detailPos = (p + windShearVec * uniforms.time * 0.5 + detailBoiling + warpVector * 0.2) * (uniforms.detailScale * 0.00145);
        let detailNoise = textureSampleLevel(uDetailNoise, smp, detailPos, 0.0);
        
        let highFreqFBM = detailNoise.r * 0.625 + detailNoise.g * 0.25 + detailNoise.b * 0.125;

        let erosionModifier = mix(1.0 - highFreqFBM, highFreqFBM, clamp(heightFrac * 3.0, 0.0, 1.0));
        density = remap(density, erosionModifier * 0.35, 1.0, 0.0, 1.0);
    }
    
    return clamp(density, 0.0, 1.0) * uniforms.densityMultiplier * weatherDensityMultiplier;
}

fn sampleCloudDensityFast(p: vec3<f32>) -> f32 {
    let earthCenterPos = vec3<f32>(p.x, p.y + EARTH_RADIUS, p.z);
    let altitude = length(earthCenterPos) - EARTH_RADIUS;

    let heightFrac = clamp((altitude - uniforms.boxMin.y) / (uniforms.boxMax.y - uniforms.boxMin.y), 0.0, 1.0);
    if (heightFrac <= 0.0 || heightFrac >= 1.0) { return 0.0; }

    let weatherUv = p.xz * 0.000005 + uniforms.windVector.xz * uniforms.time * 0.000003;
    let weatherSample = textureSampleLevel(uWeatherMap, smp, weatherUv, 0.0);

    let coverage = clamp(weatherSample.r * uniforms.cloudCoverage, 0.0, 1.0);
    if (coverage <= 0.01) { return 0.0; }

    let cloudType = weatherSample.g;
    let weatherDensityMultiplier = weatherSample.b * 0.4 + 0.8;

    let heightProfile = getSmoothHeightProfile(heightFrac, cloudType);
    if (heightProfile <= 0.001) { return 0.0; }

    let windShearVec = uniforms.windVector * (1.0 + heightFrac * uniforms.windShear);
    let samplePosWarped = p + windShearVec * uniforms.time * 0.25;

    let aspectScale = vec3<f32>(1.0, uniforms.anisotropy, 1.0);
    let baseSamplePos1 = (samplePosWarped * aspectScale) * (uniforms.cloudScale * 0.00008);
    let baseNoise1 = textureSampleLevel(uBaseNoise, smp, baseSamplePos1, 0.0);

    let worleyFBM1 = baseNoise1.g * 0.625 + baseNoise1.b * 0.25 + baseNoise1.a * 0.125;
    let fluffyBase = remap(baseNoise1.r, -(1.0 - worleyFBM1), 1.0, 0.0, 1.0);

    let baseCloudShape = fluffyBase * heightProfile;

    let density = remap(baseCloudShape, 1.0 - coverage, 1.0, 0.0, 1.0);
    if (density <= 0.01) { return 0.0; }

    let boxFalloff = min(
        smoothstep(uniforms.boxMin.y, uniforms.boxMin.y + 300.0, altitude),
        1.0 - smoothstep(uniforms.boxMax.y - 500.0, uniforms.boxMax.y, altitude)
    );

    return clamp(density, 0.0, 1.0) * boxFalloff * uniforms.densityMultiplier * weatherDensityMultiplier;
}

fn calculateLightOpticalDepth(pos: vec3<f32>, dither: f32, distFromCam: f32) -> f32 {
    let lightDir = normalize(uniforms.sunDirection);
    
    let sunElevationSin = max(abs(lightDir.y), 0.15);
    let shadowStepSize = (uniforms.lightStepLength / sunElevationSin) * uniforms.shadowSoftness;

    // 1. Calculate top-down column optical depth cache along sun ray
    let earthCenterPos = vec3<f32>(pos.x, pos.y + EARTH_RADIUS, pos.z);
    let altitude = length(earthCenterPos) - EARTH_RADIUS;
    let remainingHeight = max(0.0, uniforms.boxMax.y - altitude);
    let remainingDist = remainingHeight / sunElevationSin;

    // Sample 2D weather coverage along sun ray offset
    let sunOffsetPos = pos + lightDir * (shadowStepSize * 2.0);
    let fastSunCoverage = sampleFastCoverage(sunOffsetPos);

    // Cached column optical depth from current altitude up to top of cloud layer
    let cachedOpticalDepth = fastSunCoverage * remainingDist * 0.00035 * uniforms.densityMultiplier;

    // 2. High-frequency local contact shadow sample (1 single micro-step)
    let contactPos = pos + lightDir * (shadowStepSize * dither);
    let localContactDensity = sampleCloudDensityFast(contactPos);
    let localOpticalDepth = localContactDensity * shadowStepSize;

    return cachedOpticalDepth + localOpticalDepth;
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let size = textureDimensions(outColorTexture);
    if (global_id.x >= size.x || global_id.y >= size.y) {
        return;
    }

    let uv = vec2<f32>(f32(global_id.x) / f32(size.x), f32(global_id.y) / f32(size.y));
    let ndc = uv * 2.0 - 1.0 + uniforms.jitter;

    let viewDir = uniforms.projInverse * vec4<f32>(ndc, -1.0, 1.0);
    let rayDirWorld = (uniforms.viewInverse * vec4<f32>(viewDir.xyz, 0.0)).xyz;
    let rayDir = normalize(rayDirWorld);

    let rayAtmosphere = raySphericalShellIntersection(uniforms.cameraPos, rayDir, uniforms.boxMin.y, uniforms.boxMax.y);
    var tNear = rayAtmosphere.x;
    var tFar = rayAtmosphere.y;

    if (tNear >= tFar || tFar <= 0.0) {
        textureStore(outColorTexture, global_id.xy, vec4<f32>(0.0));
        textureStore(outDistanceTexture, global_id.xy, vec4<f32>(0.0));
        return;
    }

    tNear = max(tNear, 0.0);

    let slabDist  = tFar - tNear;
    let stepScale = clamp(slabDist / 20000.0, 1.0, 3.0);

    let FINE_STEP  = 45.0 * stepScale;   
    let EMPTY_STEP = FINE_STEP * 2.5;    
    let MACRO_STEP = EMPTY_STEP * 3.5;

    let ignDither = spatiotemporalDither(vec2<f32>(f32(global_id.x), f32(global_id.y)), uniforms.time);
    
    var currentStepSize = EMPTY_STEP;
    var t = tNear + ignDither * currentStepSize;

    let lightDir = normalize(uniforms.sunDirection);
    let cosTheta = dot(rayDir, lightDir);
    let rimCosTheta = clamp(cosTheta, -0.9, 1.0);

    var accumulatedColor = vec3<f32>(0.0);
    var transmittance = 1.0;
    var inCloud = false;
    let MAX_STEPS = 64;

    for (var i = 0; i < MAX_STEPS; i++) {
        if (t >= tFar || transmittance < 0.01) { break; }

        let currentPos = uniforms.cameraPos + rayDir * t;
        let distFromCam = t;

        // Level 1 Hierarchical Empty Space Skipping: Fast 2D Weather Coverage Map & Height Pre-Check
        let fastCoverage = sampleFastCoverage(currentPos);
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
        let density = sampleCloudDensity(currentPos, distFromCam);

        if (density > 0.001) {
            if (!inCloud) {
                inCloud = true;
                // Backtrack 1 step to hit exact cloud boundary, then switch to fine steps
                t -= currentStepSize;
                currentStepSize = FINE_STEP;
                t += currentStepSize;
                continue; 
            }

            let earthCenterPos = vec3<f32>(currentPos.x, currentPos.y + EARTH_RADIUS, currentPos.z);
            let altitude = length(earthCenterPos) - EARTH_RADIUS;
            let heightFrac = clamp((altitude - uniforms.boxMin.y) / (uniforms.boxMax.y - uniforms.boxMin.y), 0.0, 1.0);

            let lightOpticalDepth = calculateLightOpticalDepth(currentPos, ignDither, distFromCam);
            let primaryAttenuation = exp(-lightOpticalDepth * 0.0025 * uniforms.shadowAbsorption);

            let powderTerm = 1.0 - exp(-density * currentStepSize * 0.15 * uniforms.powderIntensity);
            let powderMix = clamp(-cosTheta * 0.5 + 0.5, 0.0, 1.0);
            let shadowLightAttenuation = primaryAttenuation * mix(1.0, powderTerm * 2.0, powderMix);

            let multiScatteringPhase = calculateMultiScattering(lightOpticalDepth, rimCosTheta, uniforms.forwardGlow);

            let directLight = uniforms.sunColor * 5.0 * multiScatteringPhase * shadowLightAttenuation;

            let skyAmbient = mix(uniforms.horizonColor, uniforms.zenithColor, heightFrac);
            let groundAmbient = uniforms.groundBounceColor * (1.0 - heightFrac);
            let cloudAmbientOcclusion = mix(0.3, 1.0, exp(-density * 1.5)); 
            
            let ambientLight = (skyAmbient * 0.65 + groundAmbient * 0.35) * cloudAmbientOcclusion * uniforms.shadowIntensity;

            let cloudTopTint  = mix(vec3<f32>(0.95, 0.96, 1.0), uniforms.sunColor, 0.15);
            let cloudBaseTint = vec3<f32>(0.55, 0.60, 0.68); 
            let cloudBodyColor = mix(cloudBaseTint, cloudTopTint, heightFrac * 0.6 + shadowLightAttenuation * 0.4);

            let stepLight = directLight * cloudBodyColor + ambientLight;

            let sigmaExtDynamic = mix(0.04, 0.14, density); 
            let stepExtinction = density * currentStepSize * sigmaExtDynamic;
            let stepTransmittance = exp(-stepExtinction);

            let integratedLight = stepLight * (1.0 - stepTransmittance);

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

    if (transmittance > 0.05 && rayDir.y > 0.02) {
        let cirrusAlt = 8500.0;
        let tCirrus = (cirrusAlt - uniforms.cameraPos.y) / rayDir.y;
        if (tCirrus > 0.0) {
            let pCirrus = uniforms.cameraPos + rayDir * tCirrus;
            let cirrusUv = pCirrus.xz * 0.000015 + uniforms.windVector.xz * uniforms.time * 0.000008;

            let cirrusTex = textureSampleLevel(uWeatherMap, smp, cirrusUv, 0.0);
            let cirrusNoise1 = textureSampleLevel(uWeatherMap, smp, cirrusUv * 2.5 + vec2<f32>(uniforms.time * 0.005), 0.0).g;
            let cirrusNoise2 = textureSampleLevel(uWeatherMap, smp, cirrusUv * 5.0 - vec2<f32>(uniforms.time * 0.003), 0.0).r;

            let cirrusFBM = cirrusNoise1 * 0.6 + cirrusNoise2 * 0.4;
            let cirrusCoverage = smoothstep(0.35, 0.75, cirrusTex.r * cirrusFBM);
            let cirrusAlpha = cirrusCoverage * 0.40 * transmittance;

            if (cirrusAlpha > 0.005) {
                let cirrusColor = mix(vec3<f32>(0.95, 0.97, 1.0), uniforms.sunColor * 1.2, max(0.0, dot(rayDir, lightDir)) * 0.5);
                accumulatedColor += transmittance * cirrusColor * cirrusAlpha;
                transmittance *= (1.0 - cirrusAlpha);
            }
        }
    }

    let horizonDist = tFar - tNear;
    let hazeFactor  = 1.0 - exp(-horizonDist * 0.000005);
    accumulatedColor = mix(accumulatedColor, uniforms.horizonColor * 0.9, hazeFactor * 0.35);

    let alpha = clamp(1.0 - transmittance, 0.0, 1.0);
    let toneMappedColor = toneMapACES(accumulatedColor * 1.10);
    let ditheredColor = toneMappedColor + (ignDither - 0.5) / 255.0;

    let finalColor = vec4<f32>(max(vec3<f32>(0.0), ditheredColor), alpha);
    
    textureStore(outColorTexture, global_id.xy, finalColor);
    textureStore(outDistanceTexture, global_id.xy, vec4<f32>(t, 0.0, 0.0, 1.0));
}
