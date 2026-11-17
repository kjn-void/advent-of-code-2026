// Example 1 (AoC 2023 day 1) — structs shared between Example01.swift and Example01.metal.
#ifndef EXAMPLE01_TYPES_H
#define EXAMPLE01_TYPES_H

#include <simd/simd.h>

/// Constants for the solve kernels.
typedef struct Example01Params {
    uint32_t byteCount;
    uint32_t lineCount;
    uint32_t spelledDigits;  ///< 0 = part 1 (digits only), 1 = part 2 ("one"..."nine" too).
} Example01Params;

/// Constants for the visualisation kernel (one frame of the per-line animation).
typedef struct Example01VizParams {
    uint32_t byteCount;
    uint32_t lineCount;
    uint32_t spelledDigits;
    uint32_t line;           ///< Line being animated.
    float progress;          ///< 0..1 through that line's animation phases.
    uint32_t maxLineLength;  ///< Glyph slots reserved per line.
    uint32_t queuedLines;    ///< Upcoming lines drawn dimmed behind the current one.
    uint32_t totalBefore;    ///< Running total before this line.
    uint32_t totalAfter;     ///< Running total including this line.
} Example01VizParams;

/// Glyph slots per voxel-text glyph (5 x 7 bitmap font).
#define EXAMPLE01_GLYPH_PIXELS 35
/// Digits reserved for the running total display.
#define EXAMPLE01_TOTAL_DIGITS 8

#endif  // EXAMPLE01_TYPES_H
