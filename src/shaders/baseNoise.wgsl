struct OutputBuffer {
    data: array<u32>,
};

@group(0) @binding(0) var<storage, read_write> outputBuffer: OutputBuffer;
@group(0) @binding(1) var<uniform> size: u32;

fn fade(t: f32) -> f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

fn lerp(a: f32, b: f32, t: f32) -> f32 {
    return a + t * (b - a);
}

fn grad3(hash: u32) -> vec3<f32> {
    let h = hash % 12u;
    switch h {
        case 0u: { return vec3<f32>(1.0, 1.0, 0.0); }
        case 1u: { return vec3<f32>(-1.0, 1.0, 0.0); }
        case 2u: { return vec3<f32>(1.0, -1.0, 0.0); }
        case 3u: { return vec3<f32>(-1.0, -1.0, 0.0); }
        case 4u: { return vec3<f32>(1.0, 0.0, 1.0); }
        case 5u: { return vec3<f32>(-1.0, 0.0, 1.0); }
        case 6u: { return vec3<f32>(1.0, 0.0, -1.0); }
        case 7u: { return vec3<f32>(-1.0, 0.0, -1.0); }
        case 8u: { return vec3<f32>(0.0, 1.0, 1.0); }
        case 9u: { return vec3<f32>(0.0, -1.0, 1.0); }
        case 10u: { return vec3<f32>(0.0, 1.0, -1.0); }
        default: { return vec3<f32>(0.0, -1.0, -1.0); }
    }
}

fn hashPerm(rx: f32, ry: f32, rz: f32, seed: f32) -> u32 {
    let ix = u32(abs(rx));
    let iy = u32(abs(ry));
    let iz = u32(abs(rz));
    let iseed = u32(abs(seed * 100.0));
    var h = ix * 1597334677u ^ iy * 3812015801u ^ iz * 3299498291u ^ iseed;
    h = (h ^ (h >> 16u)) * 0x45d9f3bu;
    h = (h ^ (h >> 16u)) * 0x45d9f3bu;
    h = h ^ (h >> 16u);
    return h;
}

fn periodicPerlin3D(p: vec3<f32>, rep: f32, seed: f32) -> f32 {
    let X0 = floor(p.x); let Y0 = floor(p.y); let Z0 = floor(p.z);
    let fx = p.x - X0; let fy = p.y - Y0; let fz = p.z - Z0;

    let rx0 = (X0 % rep + rep) % rep;
    let ry0 = (Y0 % rep + rep) % rep;
    let rz0 = (Z0 % rep + rep) % rep;
    let rx1 = (rx0 + 1.0) % rep;
    let ry1 = (ry0 + 1.0) % rep;
    let rz1 = (rz0 + 1.0) % rep;

    let u = fade(fx); let v = fade(fy); let w = fade(fz);

    let n000 = dot(grad3(hashPerm(rx0, ry0, rz0, seed)), vec3<f32>(fx, fy, fz));
    let n100 = dot(grad3(hashPerm(rx1, ry0, rz0, seed)), vec3<f32>(fx - 1.0, fy, fz));
    let n010 = dot(grad3(hashPerm(rx0, ry1, rz0, seed)), vec3<f32>(fx, fy - 1.0, fz));
    let n110 = dot(grad3(hashPerm(rx1, ry1, rz0, seed)), vec3<f32>(fx - 1.0, fy - 1.0, fz));
    let n001 = dot(grad3(hashPerm(rx0, ry0, rz1, seed)), vec3<f32>(fx, fy, fz - 1.0));
    let n101 = dot(grad3(hashPerm(rx1, ry0, rz1, seed)), vec3<f32>(fx - 1.0, fy, fz - 1.0));
    let n011 = dot(grad3(hashPerm(rx0, ry1, rz1, seed)), vec3<f32>(fx, fy - 1.0, fz - 1.0));
    let n111 = dot(grad3(hashPerm(rx1, ry1, rz1, seed)), vec3<f32>(fx - 1.0, fy - 1.0, fz - 1.0));

    let nx00 = lerp(n000, n100, u);
    let nx10 = lerp(n010, n110, u);
    let nx01 = lerp(n001, n101, u);
    let nx11 = lerp(n011, n111, u);

    let nxy0 = lerp(nx00, nx10, v);
    let nxy1 = lerp(nx01, nx11, v);

    return lerp(nxy0, nxy1, w);
}

fn hash3(p: vec3<f32>, seed: f32) -> vec3<f32> {
    let ix = u32(abs(p.x));
    let iy = u32(abs(p.y));
    let iz = u32(abs(p.z));
    let iseed = u32(abs(seed * 100.0));

    var h1 = ix * 1597334677u ^ iy * 3812015801u ^ iz * 3299498291u ^ iseed;
    h1 = (h1 ^ (h1 >> 16u)) * 0x45d9f3bu;
    h1 = (h1 ^ (h1 >> 16u)) * 0x45d9f3bu;
    h1 = h1 ^ (h1 >> 16u);

    var h2 = ix * 3812015801u ^ iy * 3299498291u ^ iz * 1597334677u ^ (iseed + 101u);
    h2 = (h2 ^ (h2 >> 16u)) * 0x45d9f3bu;
    h2 = (h2 ^ (h2 >> 16u)) * 0x45d9f3bu;
    h2 = h2 ^ (h2 >> 16u);

    var h3 = ix * 3299498291u ^ iy * 1597334677u ^ iz * 3812015801u ^ (iseed + 203u);
    h3 = (h3 ^ (h3 >> 16u)) * 0x45d9f3bu;
    h3 = (h3 ^ (h3 >> 16u)) * 0x45d9f3bu;
    h3 = h3 ^ (h3 >> 16u);

    return vec3<f32>(
        f32(h1 % 65536u) / 65536.0,
        f32(h2 % 65536u) / 65536.0,
        f32(h3 % 65536u) / 65536.0
    );
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

    var pFBM = periodicPerlin3D(uvw * 4.0, 4.0, 13.0) * 0.5 + 0.5;
    pFBM += (periodicPerlin3D(uvw * 8.0, 8.0, 13.0) * 0.5 + 0.5) * 0.25;

    let w1 = periodicWorley3D(uvw, 4.0, 29.0);
    let w2 = periodicWorley3D(uvw, 8.0, 53.0);
    let w3 = periodicWorley3D(uvw, 16.0, 97.0);

    let wFBM = w1 * 0.625 + w2 * 0.25 + w3 * 0.125;
    var perlinWorley = pFBM * wFBM;
    perlinWorley = clamp(perlinWorley * 1.4, 0.0, 1.0);

    let r = u32(clamp(perlinWorley * 255.0, 0.0, 255.0));
    let g = u32(clamp(w1 * 255.0, 0.0, 255.0));
    let b = u32(clamp(w2 * 255.0, 0.0, 255.0));
    let a = u32(clamp(w3 * 255.0, 0.0, 255.0));

    let pixelValue = r | (g << 8u) | (b << 16u) | (a << 24u);
    let index = id.x + id.y * size + id.z * size * size;
    outputBuffer.data[index] = pixelValue;
}
