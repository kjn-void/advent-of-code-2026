// Example 3 (AoC 2022 day 17) — structs shared between Example03.swift and Example03.metal.
#ifndef EXAMPLE03_TYPES_H
#define EXAMPLE03_TYPES_H

#include <simd/simd.h>

#include "AoCShared.h"

/// Chamber width in columns.
#define EXAMPLE03_WIDTH 7
/// Visible vertical window of chamber rows drawn around the tower top.
#define EXAMPLE03_WINDOW_ROWS 42
/// Active falling rock occupies at most 5 cells (+ and J have 5 cells).
#define EXAMPLE03_ROCK_CELLS 5
/// Wall structure boxes: floor + lava strip + 3 translucent walls + 4 corner rails + 1 jet nozzle.
#define EXAMPLE03_FRAME_SLOTS 10
/// Animated hot-gas jet streaks shooting across the chamber.
#define EXAMPLE03_JET_STREAKS 12
/// Impact embers / warp-jump streaks.
#define EXAMPLE03_PARTICLES 24
/// Up to 13 digits for the Part 2 height counter (1_514_285_714_288).
#define EXAMPLE03_SCORE_DIGITS 13
/// Pixels per 5 x 7 voxel glyph.
#define EXAMPLE03_GLYPH_PIXELS 35
/// Sentinel for an empty chamber cell.
#define EXAMPLE03_NONE 0xffffffffu

/// Total instance slots rendered each frame:
///   chamber cells + active rock + frame/walls + jet streaks + particles + height readout.
#define EXAMPLE03_INSTANCE_COUNT                                                                                      \
    (EXAMPLE03_WINDOW_ROWS * EXAMPLE03_WIDTH + EXAMPLE03_ROCK_CELLS + EXAMPLE03_FRAME_SLOTS + EXAMPLE03_JET_STREAKS + \
     EXAMPLE03_PARTICLES + EXAMPLE03_SCORE_DIGITS * EXAMPLE03_GLYPH_PIXELS)

/// One settled cell in the chamber: which rock placed it and its shape (0..4).
typedef struct Example03Cell {
    uint32_t rockIndex;  ///< 0-based rock index, or EXAMPLE03_NONE if empty.
    uint32_t shape;      ///< 0..4 rock shape.
} Example03Cell;

/// Recorded fall path step for a rock (one jet push + optional drop).
typedef struct Example03FallStep {
    int32_t xAfterJet;    ///< Rock left column after jet push (0..6).
    int32_t yBeforeDrop;  ///< Rock bottom row before dropping.
    int32_t jetDir;       ///< -1 for '<', +1 for '>'.
    uint32_t blocked;     ///< 1 if the jet push hit a wall or settled rock.
} Example03FallStep;

/// Metadata for one simulated rock.
typedef struct Example03RockInfo {
    uint32_t shape;        ///< 0..4 shape index.
    uint32_t finalX;       ///< Settled left column.
    uint32_t finalY;       ///< Settled bottom row.
    uint32_t towerHeight;  ///< Tower height after this rock settles.
    uint32_t fallOffset;   ///< Start index in the flat fall-steps buffer.
    uint32_t fallCount;    ///< Number of jet+drop iterations until landing.
} Example03RockInfo;

/// Per-frame parameters for `example03_instances`.
typedef struct Example03VizParams {
    uint32_t part;          ///< 1 or 2.
    uint32_t totalRows;     ///< Total rows stored in the GPU chamber buffer.
    uint32_t windowBottom;  ///< Lowest chamber row currently shown.
    uint32_t settledCount;  ///< Number of simulated rocks visible as settled in the tower.

    uint32_t activeRock;  ///< Index into rocks buffer for the currently falling rock, or EXAMPLE03_NONE.
    float progress;       ///< Timeline step progress in [0, 1).
    float cameraY;        ///< World Y of the camera focus.
    float time;           ///< Elapsed seconds for subtle lava shimmer.

    uint32_t cycleStart;   ///< Part 2: first rock of cycle 1.
    uint32_t cycleLength;  ///< Part 2: rocks per cycle.
    uint32_t isHyperJump;  ///< 1 during the Part 2 warp-jump step.
    uint32_t padding;

    uint64_t displayHeight;   ///< Exact tower height shown in the floating voxel counter.
    uint64_t previousHeight;  ///< Height before the latest increment (for digit hop).
    float impactAge;          ///< 0..1 right after landing or during jump pulse.
    float popAmount;          ///< 0..1 milestone/jump pop scale driver.
} Example03VizParams;

#endif  // EXAMPLE03_TYPES_H
