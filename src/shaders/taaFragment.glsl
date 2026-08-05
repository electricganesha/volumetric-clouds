precision highp float;

in vec2 vUv;
layout(location = 0) out vec4 fragColor;

uniform sampler2D uCurrentCloud;
uniform sampler2D uCurrentDistance;
uniform sampler2D uHistoryCloud;

uniform mat4 uPreviousViewProjectionMatrix;
uniform mat4 uViewProjectionMatrixInverse;
uniform vec3 uCameraPos;

void main() {
    vec4 currentColor = texture(uCurrentCloud, vUv);
    float t = texture(uCurrentDistance, vUv).r;

    // If t is very small or zero, it might mean no intersection, just pass current color
    if (t <= 0.0) {
        fragColor = currentColor;
        return;
    }

    // Reconstruct current world position
    vec2 ndc = vUv * 2.0 - 1.0;
    vec4 viewDir = uViewProjectionMatrixInverse * vec4(ndc, -1.0, 1.0);
    vec3 rayDirWorld = normalize(viewDir.xyz / viewDir.w - uCameraPos);
    vec3 worldPos = uCameraPos + rayDirWorld * t;

    // Reproject to previous frame
    vec4 prevClip = uPreviousViewProjectionMatrix * vec4(worldPos, 1.0);
    vec2 prevNdc = prevClip.xy / prevClip.w;
    vec2 prevUv = prevNdc * 0.5 + 0.5;

    // Check if previous UV is on screen
    if (prevUv.x < 0.0 || prevUv.x > 1.0 || prevUv.y < 0.0 || prevUv.y > 1.0) {
        fragColor = currentColor;
        return;
    }

    vec4 historyColor = texture(uHistoryCloud, prevUv);

    // Neighborhood clamping to reduce ghosting
    vec2 texelSize = 1.0 / vec2(textureSize(uCurrentCloud, 0));
    vec4 colorMin = currentColor;
    vec4 colorMax = currentColor;
    
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            if (x == 0 && y == 0) continue;
            vec4 neighbor = texture(uCurrentCloud, vUv + vec2(float(x), float(y)) * texelSize);
            colorMin = min(colorMin, neighbor);
            colorMax = max(colorMax, neighbor);
        }
    }
    historyColor = clamp(historyColor, colorMin, colorMax);

    // Blend (5% current, 95% history)
    float blendFactor = 0.05;
    fragColor = mix(historyColor, currentColor, blendFactor);
}
