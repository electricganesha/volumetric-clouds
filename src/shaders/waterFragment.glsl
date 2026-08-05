uniform sampler2D mirrorSampler;
uniform float alpha;
uniform float time;
uniform float size;
uniform float distortionScale;
uniform sampler2D normalSampler;
uniform vec3 sunColor;
uniform vec3 sunDirection;
uniform vec3 eye;
uniform vec3 waterColor;

varying vec4 mirrorCoord;
varying vec4 worldPosition;

vec4 getNoise( vec2 uv ) {
    vec2 uv0 = ( uv / 103.0 ) + vec2(time / 17.0, time / 29.0);
    vec2 uv1 = uv / 107.0-vec2( time / -19.0, time / 31.0 );
    vec2 uv2 = uv / vec2( 8907.0, 9803.0 ) + vec2( time / 101.0, time / 97.0 );
    vec2 uv3 = uv / vec2( 1091.0, 1027.0 ) - vec2( time / 109.0, time / -113.0 );
    vec4 noise = texture2D( normalSampler, uv0 ) +
        texture2D( normalSampler, uv1 ) +
        texture2D( normalSampler, uv2 ) +
        texture2D( normalSampler, uv3 );
    return noise * 0.5 - 1.0;
}

void sunLight( const vec3 surfaceNormal, const vec3 eyeDirection, float shiny, float spec, float diffuse, inout vec3 diffuseColor, inout vec3 specularColor ) {
    float sunVisibility = smoothstep(0.0, 0.05, sunDirection.y);
    if (sunVisibility <= 0.001) return;

    vec3 halfVector = normalize( sunDirection + eyeDirection );
    float NdotH = max( 0.0, dot( surfaceNormal, halfVector ) );
    
    // Anisotropic wave trail stretch — creates long golden sun paths at low sun angles
    float sunElev = clamp(sunDirection.y, 0.0, 1.0);
    float specPow = mix(25.0, 240.0, clamp(sunElev * 2.0, 0.0, 1.0));
    float specTerm = pow( NdotH, specPow );
    
    // Glint intensity boost when looking towards low sun
    float glintBoost = mix(2.5, 1.0, clamp(sunElev * 3.0, 0.0, 1.0));
    
    specularColor += specTerm * sunColor * spec * glintBoost * sunVisibility;
    diffuseColor += max( dot( sunDirection, surfaceNormal ), 0.0 ) * sunColor * diffuse * sunVisibility;
}

#include <common>
#include <packing>
#include <bsdfs>
#include <fog_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <lights_pars_begin>
#include <shadowmap_pars_fragment>
#include <shadowmask_pars_fragment>

void main() {

    #include <logdepthbuf_fragment>
    vec4 noise = getNoise( worldPosition.xz * size );
    // Gentle ripple surface: enough wave normal to distort reflections visibly
    // but not so much that it looks like choppy ocean
    vec3 surfaceNormal = normalize( mix(vec3(0.0, 1.0, 0.0), noise.xzy * vec3( 1.5, 1.0, 1.5 ), 0.45) );

    vec3 diffuseLight = vec3(0.0);
    vec3 specularLight = vec3(0.0);

    vec3 worldToEye = eye - worldPosition.xyz;
    vec3 eyeDirection = normalize( worldToEye );
    sunLight( surfaceNormal, eyeDirection, 100.0, 2.0, 0.5, diffuseLight, specularLight );

    // --- Stable mirror UV with wave distortion ---
    // Use standard projective mirror coord, distorted by the XZ surface normal.
    // Multiplier 0.018 gives visible ripple stretching like real water.
    vec2 baseUv = mirrorCoord.xy / mirrorCoord.w;
    vec2 distortion = surfaceNormal.xz * distortionScale * 0.018;
    vec2 sampleUv = clamp(baseUv + distortion, 0.001, 0.999);
    vec3 reflectionSample = texture2D( mirrorSampler, sampleUv ).rgb;

    // --- Schlick Fresnel with boosted R0 for glassy water ---
    float theta = max( dot( eyeDirection, surfaceNormal ), 0.0 );
    float rf0 = 0.18;
    float reflectance = rf0 + ( 1.0 - rf0 ) * pow( ( 1.0 - theta ), 4.0 );
    // Clamp minimum so water never looks fully opaque/dark
    reflectance = max(reflectance, 0.35);

    // --- Sky-tinted depth colour (replaces dark waterColor scatter) ---
    // Water looks deep blue in reality, not dark swamp green.
    // Use a sky-matching tint so dark areas are blue, not black.
    vec3 depthColor = waterColor * 0.6 + vec3(0.05, 0.12, 0.22);
    vec3 scatter = depthColor * max(0.0, dot(surfaceNormal, eyeDirection));

    // --- Compose: reflection dominates, specular on top ---
    vec3 albedo = mix(
        (sunColor * diffuseLight * 0.1 + scatter) * getShadowMask(),
        reflectionSample * 1.5 + specularLight,
        reflectance
    );
    vec3 outgoingLight = albedo;
    gl_FragColor = vec4( outgoingLight, alpha );

    #include <tonemapping_fragment>
    #include <colorspace_fragment>
    #include <fog_fragment>
}
