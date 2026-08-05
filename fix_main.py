import re

with open('src/shaders/cloudFragment.glsl', 'r') as f:
    content = f.read()

# We want to replace everything from 'void main() {' to the end of the file.
pattern = r"void main\(\) \{.*"
replacement = """void main() {
    vec2 ndc = vUv * 2.0 - 1.0;

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

    float ignDither = interleavedGradientNoise(gl_FragCoord.xy);
    
    float currentStepSize = EMPTY_STEP;
    float t = tNear + ignDither * currentStepSize;

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
        float density = sampleCloudDensity(currentPos, distFromCam);

        if (density > 0.001) {
            if (!inCloud) {
                inCloud = true;
                t -= currentStepSize;
                currentStepSize = FINE_STEP;
                t += currentStepSize;
                continue; 
            }

            vec3 earthCenterPos = vec3(currentPos.x, currentPos.y + EARTH_RADIUS, currentPos.z);
            float altitude = length(earthCenterPos) - EARTH_RADIUS;
            float heightFrac = clamp((altitude - uBoxMin.y) / (uBoxMax.y - uBoxMin.y), 0.0, 1.0);

            // Light Optical Depth Transmittance
            float lightOpticalDepth = calculateLightOpticalDepth(currentPos, ignDither, distFromCam);
            float primaryAttenuation = exp(-lightOpticalDepth * 0.0025 * uShadowAbsorption);

            // FIX: Corrected Powder Term Blend Logic
            float powderTerm = 1.0 - exp(-density * currentStepSize * 0.15 * uPowderIntensity);
            float powderMix = clamp(-cosTheta * 0.5 + 0.5, 0.0, 1.0);
            float shadowLightAttenuation = primaryAttenuation * mix(1.0, powderTerm * 2.0, powderMix);

            // Sébastien Hillaire's Multi-Scattering Phase
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
    vec3 ditheredColor = toneMappedColor + (ignDither - 0.5) / 255.0;

    fragColor = vec4(max(vec3(0.0), ditheredColor), alpha);
}
"""
new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

with open('src/shaders/cloudFragment.glsl', 'w') as f:
    f.write(new_content)
