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

// ---------------------------------------------------------------------------------------------
// Voxel text
// ---------------------------------------------------------------------------------------------

// 5x7 font, rows top to bottom, bit 4 = leftmost column. Index: '0'-'9' -> 0-9, 'a'-'z' -> 10-35.
constant uchar kFont5x7[36][7] = {
    {0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110},  // 0
    {0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110},  // 1
    {0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111},  // 2
    {0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110},  // 3
    {0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010},  // 4
    {0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110},  // 5
    {0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110},  // 6
    {0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000},  // 7
    {0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110},  // 8
    {0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100},  // 9
    {0b00000, 0b00000, 0b01110, 0b00001, 0b01111, 0b10001, 0b01111},  // a
    {0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b11110},  // b
    {0b00000, 0b00000, 0b01110, 0b10000, 0b10000, 0b10001, 0b01110},  // c
    {0b00001, 0b00001, 0b01101, 0b10011, 0b10001, 0b10001, 0b01111},  // d
    {0b00000, 0b00000, 0b01110, 0b10001, 0b11111, 0b10000, 0b01110},  // e
    {0b00110, 0b01001, 0b01000, 0b11100, 0b01000, 0b01000, 0b01000},  // f
    {0b00000, 0b01111, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110},  // g
    {0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001},  // h
    {0b00100, 0b00000, 0b01100, 0b00100, 0b00100, 0b00100, 0b01110},  // i
    {0b00010, 0b00000, 0b00110, 0b00010, 0b00010, 0b10010, 0b01100},  // j
    {0b10000, 0b10000, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010},  // k
    {0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110},  // l
    {0b00000, 0b00000, 0b11010, 0b10101, 0b10101, 0b10001, 0b10001},  // m
    {0b00000, 0b00000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001},  // n
    {0b00000, 0b00000, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110},  // o
    {0b00000, 0b00000, 0b11110, 0b10001, 0b11110, 0b10000, 0b10000},  // p
    {0b00000, 0b00000, 0b01101, 0b10011, 0b01111, 0b00001, 0b00001},  // q
    {0b00000, 0b00000, 0b10110, 0b11001, 0b10000, 0b10000, 0b10000},  // r
    {0b00000, 0b00000, 0b01110, 0b10000, 0b01110, 0b00001, 0b11110},  // s
    {0b01000, 0b01000, 0b11100, 0b01000, 0b01000, 0b01001, 0b00110},  // t
    {0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b10011, 0b01101},  // u
    {0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100},  // v
    {0b00000, 0b00000, 0b10001, 0b10001, 0b10101, 0b10101, 0b01010},  // w
    {0b00000, 0b00000, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001},  // x
    {0b00000, 0b00000, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110},  // y
    {0b00000, 0b00000, 0b11111, 0b00010, 0b00100, 0b01000, 0b11111},  // z
};

/// Whether pixel (`col` 0-4 from the left, `row` 0-6 from the top) of glyph `c` is set.
/// Covers '0'-'9' and 'a'-'z'; anything else is blank.
inline bool glyphPixel(uchar c, uint col, uint row) {
    int index = -1;
    if (c >= '0' && c <= '9') {
        index = int(c - '0');
    } else if (c >= 'a' && c <= 'z') {
        index = int(c - 'a') + 10;
    }
    return index >= 0 && ((kFont5x7[index][row] >> (4 - col)) & 1u) != 0;
}

// ---------------------------------------------------------------------------------------------
// Animation easing (t is usually a step's progress in [0, 1))
// ---------------------------------------------------------------------------------------------

/// Linear fraction of the way through [from, to], clamped to [0, 1].
inline float linear(float t, float from, float to) {
    return metal::saturate((t - from) / (to - from));
}

/// Smoothstep-eased fraction of the way through [from, to].
inline float phase(float t, float from, float to) {
    return metal::smoothstep(0.0f, 1.0f, linear(t, from, to));
}

/// Overshoots ~10 % past 1 before settling: the "pop" in.
inline float easeOutBack(float x) {
    const float c1 = 1.70158f;
    const float c3 = c1 + 1.0f;
    const float y = x - 1.0f;
    return 1.0f + c3 * y * y * y + c1 * y * y;
}

/// Damped spring from 1 to 0 over x in [0, 1]: crosses zero at 0.2, squashes to about -0.14
/// at 0.4, rebounds slightly, and is exactly 0 at x = 1. The "boing" back to rest.
inline float springBack(float x) {
    x = metal::saturate(x);
    return x >= 1.0f ? 0.0f : metal::exp(-5.0f * x) * metal::cos(2.5f * M_PI_F * x);
}

inline float easeOutCubic(float x) {
    const float y = 1.0f - x;
    return 1.0f - y * y * y;
}

}  // namespace aoc

#endif  // __METAL_VERSION__

#endif  // AOC_KERNELS_H
