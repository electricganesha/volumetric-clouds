struct OutputBuffer {
    data: array<u32>,
};

@group(0) @binding(0) var<storage, read_write> outputBuffer: OutputBuffer;
@group(0) @binding(1) var<uniform> size: u32;

fn hash3(p: vec3<f32>, seed: f32) -> vec3<f32> {
    let h = vec3<f32>(
        dot(p, vec3<f32>(127.1, 311.7, 74.7)),
        dot(p, vec3<f32>(269.5, 183.3, 246.1)),
        dot(p, vec3<f32>(419.2, 371.9, 118.5))
    );
    return fract(sin(h + seed) * 43758.5453);
}

fn periodicWorley3D(p: vec3<f32>, frequency: f32, seed: f32) -> f32 {
    let st = p * frequency;
    let i = floor(st);
    let f = fract(st);
    var minDist = 1.0;

    for (var z: i32 = -1; z <= 1; z++) {
        for (var y: i32 = -1; y <= 1; y++) {
            for (var x: i32 = -1; x <= 1; x++) {
                let neighbor = vec3<f32>(f32(x), f32(y), f32(z));
                let cell = (i + neighbor + vec3<f32>(frequency)) % vec3<f32>(frequency);
                let point = hash3(cell, seed);
                let diff = neighbor + point - f;
                let dist = length(diff);
                minDist = min(minDist, dist);
            }
        }
    }
    return clamp(1.0 - minDist, 0.0, 1.0);
}

@compute @workgroup_size(4, 4, 4)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    if (id.x >= size || id.y >= size || id.z >= size) {
        return;
    }

    let u = f32(id.x) / f32(size);
    let v = f32(id.y) / f32(size);
    let w = f32(id.z) / f32(size);
    let uvw = vec3<f32>(u, v, w);

    let w1 = periodicWorley3D(uvw, 6.0, 101.0);
    let w2 = periodicWorley3D(uvw, 12.0, 203.0);
    let w3 = periodicWorley3D(uvw, 24.0, 307.0);
    let w4 = periodicWorley3D(uvw, 48.0, 409.0);

    let r = u32(clamp(w1 * 255.0, 0.0, 255.0));
    let g = u32(clamp(w2 * 255.0, 0.0, 255.0));
    let b = u32(clamp(w3 * 255.0, 0.0, 255.0));
    let a = u32(clamp(w4 * 255.0, 0.0, 255.0));

    let pixelValue = r | (g << 8u) | (b << 16u) | (a << 24u);
    let index = id.x + id.y * size + id.z * size * size;
    outputBuffer.data[index] = pixelValue;
}
