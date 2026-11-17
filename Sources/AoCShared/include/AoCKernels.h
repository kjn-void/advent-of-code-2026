// Metal-only helpers for compute kernels. Include with `#include "AoCKernels.h"`.
// The whole file is guarded so the Swift/C module import sees nothing.
#ifndef AOC_KERNELS_H
#define AOC_KERNELS_H

#ifdef __METAL_VERSION__

#include <metal_stdlib>

#include "AoCShared.h"

namespace aoc {

// ---------------------------------------------------------------------------------------------
// Grid helpers
// ---------------------------------------------------------------------------------------------

/// 4-neighbourhood offsets: right, down, left, up.
constant int2 kDirs4[4] = {int2(1, 0), int2(0, 1), int2(-1, 0), int2(0, -1)};

/// 8-neighbourhood offsets, clockwise starting at right.
constant int2 kDirs8[8] = {int2(1, 0),  int2(1, 1),   int2(0, 1),  int2(-1, 1),
                           int2(-1, 0), int2(-1, -1), int2(0, -1), int2(1, -1)};

inline bool inBounds(int2 p, AoCGridSize size) {
    return p.x >= 0 && p.y >= 0 && uint(p.x) < size.width && uint(p.y) < size.height;
}

inline uint index(uint2 p, AoCGridSize size) {
    return p.y * size.width + p.x;
}

inline uint index(int2 p, AoCGridSize size) {
    return uint(p.y) * size.width + uint(p.x);
}

// ---------------------------------------------------------------------------------------------
// Reductions
//
// AoC answers routinely overflow 32 bits, but Apple GPUs only support 32-bit atomic add.
// `atomicAdd64` emulates a 64-bit add with a {lo, hi} pair of atomic_uint (exact: the carry is
// derived from the value returned by the atomic itself). Read the result on the CPU as UInt64.
// ---------------------------------------------------------------------------------------------

inline void atomicAdd64(device metal::atomic_uint* pair, ulong value) {
    const uint lo = uint(value);
    const uint hi = uint(value >> 32);
    const uint old = metal::atomic_fetch_add_explicit(&pair[0], lo, metal::memory_order_relaxed);
    const uint carry = (old + lo < old) ? 1u : 0u;
    if (hi + carry != 0u) {
        metal::atomic_fetch_add_explicit(&pair[1], hi + carry, metal::memory_order_relaxed);
    }
}

/// Sums `value` across the SIMD-group and adds it to `counter` once per SIMD-group.
/// Safe with non-uniform dispatches: only active lanes participate.
inline void reduceAdd(uint value, device metal::atomic_uint* counter) {
    const uint total = metal::simd_sum(value);
    if (metal::simd_is_first()) {
        metal::atomic_fetch_add_explicit(counter, total, metal::memory_order_relaxed);
    }
}

/// 64-bit variant of `reduceAdd`; `pair` has the layout described for `atomicAdd64`.
/// Each lane must contribute < 2^32 / simd-width to keep the SIMD-sum in 32 bits;
/// otherwise call `atomicAdd64` per lane.
inline void reduceAdd64(uint value, device metal::atomic_uint* pair) {
    const uint total = metal::simd_sum(value);
    if (metal::simd_is_first()) {
        atomicAdd64(pair, ulong(total));
    }
}

/// Sets `flag` to 1 if any lane `changed`; used by iterate-until-stable kernels.
inline void markChanged(bool changed, device metal::atomic_uint* flag) {
    if (metal::simd_any(changed) && metal::simd_is_first()) {
        metal::atomic_store_explicit(flag, 1u, metal::memory_order_relaxed);
    }
}

// ---------------------------------------------------------------------------------------------
// Visualisation helpers
// ---------------------------------------------------------------------------------------------

/// Cheap integer hash (lowbias32).
inline uint hash(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

/// Stable, reasonably distinct colour for an id.
inline float3 idColor(uint id) {
    const uint h = hash(id);
    const float hue = float(h & 0xffffu) / 65535.0f;
    const float3 k = float3(1.0f, 2.0f / 3.0f, 1.0f / 3.0f);
    const float3 p = metal::abs(metal::fract(float3(hue) + k) * 6.0f - 3.0f);
    return metal::mix(float3(1.0f), metal::saturate(p - 1.0f), 0.65f) * 0.9f;
}

/// Maps t in [0, 1] onto a blue -> teal -> yellow ramp.
inline float3 heatColor(float t) {
    t = metal::saturate(t);
    const float3 a = float3(0.10f, 0.16f, 0.45f);
    const float3 b = float3(0.10f, 0.65f, 0.60f);
    const float3 c = float3(0.98f, 0.85f, 0.25f);
    return t < 0.5f ? metal::mix(a, b, t * 2.0f) : metal::mix(b, c, (t - 0.5f) * 2.0f);
}

}  // namespace aoc

#endif  // __METAL_VERSION__

#endif  // AOC_KERNELS_H
