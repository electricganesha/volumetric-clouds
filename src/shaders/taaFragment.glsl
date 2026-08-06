precision highp float;

in vec2 vUv;
layout(location = 0) out vec4 fragColor;

uniform sampler2D uCurrentCloud;
uniform sampler2D uCurrentDistance;
uniform sampler2D uHistoryCloud;

uniform mat4 uPreviousViewProjectionMatrix;
uniform mat4 uViewProjectionMatrixInverse;
uniform vec3 uCameraPos;

// RGB to YCoCg color space for perceptually accurate variance clipping
vec3 RGBToYCoCg(vec3 rgb) {
    float Y  = dot(rgb, vec3(0.25, 0.50, 0.25));
    float Co = dot(rgb, vec3(0.50, 0.00, -0.50));
    float Cg = dot(rgb, vec3(-0.25, 0.50, -0.25));
    return vec3(Y, Co, Cg);
}

vec3 YCoCgToRGB(vec3 ycocg) {
    float Y  = ycocg.x;
    float Co = ycocg.y;
    float Cg = ycocg.z;
    return vec3(Y + Co - Cg, Y + Cg, Y - Co - Cg);
}

void main() {
    vec4 currentColor = texture(uCurrentCloud, vUv);
    float t = texture(uCurrentDistance, vUv).r;

    // If t is zero, no cloud hit — pass current color
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

    // Check if previous UV is off screen
    if (prevUv.x < 0.0 || prevUv.x > 1.0 || prevUv.y < 0.0 || prevUv.y > 1.0) {
        fragColor = currentColor;
        return;
    }

    vec4 historyColor = texture(uHistoryCloud, prevUv);

    // 3x3 Neighborhood Variance Clipping in YCoCg space
    vec2 texelSize = 1.0 / vec2(textureSize(uCurrentCloud, 0));
    vec3 m1 = vec3(0.0);
    vec3 m2 = vec3(0.0);

    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec3 neighborRGB = texture(uCurrentCloud, vUv + vec2(float(x), float(y)) * texelSize).rgb;
            vec3 neighborYCC = RGBToYCoCg(neighborRGB);
            m1 += neighborYCC;
            m2 += neighborYCC * neighborYCC;
        }
    }

    vec3 mean = m1 / 9.0;
    vec3 stddev = sqrt(max(vec3(0.0), m2 / 9.0 - mean * mean));
    float gamma = 1.25; // Tight variance bounding box to eliminate ghosting
    vec3 minColor = mean - gamma * stddev;
    vec3 maxColor = mean + gamma * stddev;

    vec3 historyYCC = RGBToYCoCg(historyColor.rgb);
    historyYCC = clamp(historyYCC, minColor, maxColor);
    historyColor.rgb = max(vec3(0.0), YCoCgToRGB(historyYCC));

    // Dynamic motion-adaptive blending factor (increases blend when camera moves fast)
    vec2 motionVec = vUv - prevUv;
    float motionLen = length(motionVec * vec2(1920.0, 1080.0));
    float blendFactor = mix(0.12, 0.45, clamp(motionLen * 0.08, 0.0, 1.0));

    fragColor = mix(historyColor, currentColor, blendFactor);
}
