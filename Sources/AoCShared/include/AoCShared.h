// Types shared bit-for-bit between Swift (imported as the `AoCShared` C module) and Metal.
//
// Rules for anything added here:
//   * Only plain C structs/enums built from fixed-size scalars and simd types.
//   * simd_float3 is 16 bytes (same as Metal's float3 and Swift's SIMD3<Float>), so prefer
//     explicit simd_float4 / packed scalars when the layout matters for big buffers.
//   * Per-day types go in their own header (e.g. Day01Types.h) next to this file.
#ifndef AOC_SHARED_H
#define AOC_SHARED_H

#include <simd/simd.h>

/// One box drawn by the visualizer. Scenes (or their compute kernels) write arrays of these.
typedef struct AoCInstance {
    simd_float3 position;  ///< Box center in world units.
    simd_float3 scale;     ///< Full box extents along x/y/z.
    simd_float4 color;     ///< Linear RGBA. Emission strength in `w` is ignored; alpha < 1 blends.
} AoCInstance;

/// Per-frame uniforms for the instanced box renderer.
typedef struct AoCFrameUniforms {
    simd_float4x4 viewProjection;
    simd_float3 cameraPosition;
    simd_float3 lightDirection;  ///< Normalized, pointing *towards* the light.
    float time;
    float fogDensity;
} AoCFrameUniforms;

/// Dimensions of a row-major 2D grid passed to kernels as a constant.
typedef struct AoCGridSize {
    uint32_t width;
    uint32_t height;
} AoCGridSize;

#endif  // AOC_SHARED_H
