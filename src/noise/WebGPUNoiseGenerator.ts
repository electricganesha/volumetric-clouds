import * as THREE from 'three';
import baseNoiseWgsl from '../shaders/baseNoise.wgsl?raw';
import detailNoiseWgsl from '../shaders/detailNoise.wgsl?raw';

let cachedDevice: GPUDevice | null = null;
let webGpuAttempted = false;

export async function getWebGPUDevice(): Promise<GPUDevice | null> {
  if (webGpuAttempted) return cachedDevice;
  webGpuAttempted = true;

  if (typeof navigator === 'undefined' || !('gpu' in navigator) || !navigator.gpu) {
    console.log('[WebGPU] navigator.gpu not supported on this browser/platform.');
    return null;
  }

  try {
    const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
    if (!adapter) {
      console.warn('[WebGPU] Failed to get GPUAdapter.');
      return null;
    }
    cachedDevice = await adapter.requestDevice();
    console.log('[WebGPU] GPU Device successfully initialized for Compute Shader Noise Generation.');
    return cachedDevice;
  } catch (err) {
    console.warn('[WebGPU] Error requesting GPUDevice:', err);
    return null;
  }
}

export async function generateBaseNoiseTextureWebGPU(device: GPUDevice, size = 128): Promise<THREE.Data3DTexture> {
  const startTime = performance.now();
  const totalVoxels = size * size * size;
  const bufferSize = totalVoxels * 4;

  const outputBuffer = device.createBuffer({
    size: bufferSize,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
  });

  const readBuffer = device.createBuffer({
    size: bufferSize,
    usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST,
  });

  const uniformBuffer = device.createBuffer({
    size: 4,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });
  device.queue.writeBuffer(uniformBuffer, 0, new Uint32Array([size]));

  const module = device.createShaderModule({ code: baseNoiseWgsl });
  const pipeline = device.createComputePipeline({
    layout: 'auto',
    compute: { module, entryPoint: 'main' },
  });

  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: outputBuffer } },
      { binding: 1, resource: { buffer: uniformBuffer } },
    ],
  });

  const commandEncoder = device.createCommandEncoder();
  const pass = commandEncoder.beginComputePass();
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, bindGroup);
  const workgroups = Math.ceil(size / 4);
  pass.dispatchWorkgroups(workgroups, workgroups, workgroups);
  pass.end();

  commandEncoder.copyBufferToBuffer(outputBuffer, 0, readBuffer, 0, bufferSize);
  device.queue.submit([commandEncoder.finish()]);

  await readBuffer.mapAsync(GPUMapMode.READ);
  const arrayBuffer = readBuffer.getMappedRange();
  const uint8Data = new Uint8Array(arrayBuffer.slice(0));
  readBuffer.unmap();

  const texture = new THREE.Data3DTexture(uint8Data, size, size, size);
  texture.format = THREE.RGBAFormat;
  texture.type = THREE.UnsignedByteType;
  texture.minFilter = THREE.LinearFilter;
  texture.magFilter = THREE.LinearFilter;
  texture.wrapS = THREE.RepeatWrapping;
  texture.wrapT = THREE.RepeatWrapping;
  texture.wrapR = THREE.RepeatWrapping;
  texture.needsUpdate = true;

  console.log(`[WebGPU] 128^3 Base Noise Compute Shader generated in ${(performance.now() - startTime).toFixed(1)}ms!`);
  return texture;
}

export async function generateDetailNoiseTextureWebGPU(device: GPUDevice, size = 64): Promise<THREE.Data3DTexture> {
  const startTime = performance.now();
  const totalVoxels = size * size * size;
  const bufferSize = totalVoxels * 4;

  const outputBuffer = device.createBuffer({
    size: bufferSize,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
  });

  const readBuffer = device.createBuffer({
    size: bufferSize,
    usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST,
  });

  const uniformBuffer = device.createBuffer({
    size: 4,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });
  device.queue.writeBuffer(uniformBuffer, 0, new Uint32Array([size]));

  const module = device.createShaderModule({ code: detailNoiseWgsl });
  const pipeline = device.createComputePipeline({
    layout: 'auto',
    compute: { module, entryPoint: 'main' },
  });

  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: outputBuffer } },
      { binding: 1, resource: { buffer: uniformBuffer } },
    ],
  });

  const commandEncoder = device.createCommandEncoder();
  const pass = commandEncoder.beginComputePass();
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, bindGroup);
  const workgroups = Math.ceil(size / 4);
  pass.dispatchWorkgroups(workgroups, workgroups, workgroups);
  pass.end();

  commandEncoder.copyBufferToBuffer(outputBuffer, 0, readBuffer, 0, bufferSize);
  device.queue.submit([commandEncoder.finish()]);

  await readBuffer.mapAsync(GPUMapMode.READ);
  const arrayBuffer = readBuffer.getMappedRange();
  const uint8Data = new Uint8Array(arrayBuffer.slice(0));
  readBuffer.unmap();

  const texture = new THREE.Data3DTexture(uint8Data, size, size, size);
  texture.format = THREE.RGBAFormat;
  texture.type = THREE.UnsignedByteType;
  texture.minFilter = THREE.LinearFilter;
  texture.magFilter = THREE.LinearFilter;
  texture.wrapS = THREE.RepeatWrapping;
  texture.wrapT = THREE.RepeatWrapping;
  texture.wrapR = THREE.RepeatWrapping;
  texture.needsUpdate = true;

  console.log(`[WebGPU] 64^3 Detail Noise Compute Shader generated in ${(performance.now() - startTime).toFixed(1)}ms!`);
  return texture;
}
