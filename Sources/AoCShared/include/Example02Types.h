// Example 2 (AoC 2024 day 6) — structs shared between Example02.swift and Example02.metal.
#ifndef EXAMPLE02_TYPES_H
#define EXAMPLE02_TYPES_H

#include <simd/simd.h>

#include "AoCShared.h"

/// A guard state packs `cell * 4 + direction` (direction indexes aoc::kDirs4: right, down, left,
/// up). This value means "walked off the map".
#define EXAMPLE02_EXIT 0xffffffffu
/// Set in a jump-table entry whose straight run leaves the map after the stop cell.
#define EXAMPLE02_EXIT_BIT 0x80000000u
/// "No such tick / candidate / segment".
#define EXAMPLE02_NONE 0xffffffffu

/// Route segments drawn for one hypothetical obstruction. A route turns at most
/// 4 * (obstacles + 1) times before it must repeat, so this covers 130 x 130 maps with ~1000
/// obstacles; longer routes are cut off (drawing only).
#define EXAMPLE02_MAX_SEGMENTS 4096
/// Digits of the score display.
#define EXAMPLE02_SCORE_DIGITS 6
/// Simultaneous ripples (recent revisits in part 1, the loop burst in part 2).
#define EXAMPLE02_RIPPLES 8
/// Cubes per ripple ring.
#define EXAMPLE02_RIPPLE_CUBES 20
/// Boxes for the guard and the ghost guard (body, head, visor each).
#define EXAMPLE02_ACTOR_SLOTS 6
/// Pixels per 5 x 7 voxel glyph.
#define EXAMPLE02_GLYPH_PIXELS 35

/// Instance slots for a map of `cells` cells, in kernel order: floor or obstacle per cell, a
/// horizontal and a vertical trail bar per cell, route segments, actors, ripples, score.
#define EXAMPLE02_INSTANCE_COUNT(cells)                                                                           \
    (3u * (cells) + EXAMPLE02_MAX_SEGMENTS + EXAMPLE02_ACTOR_SLOTS + EXAMPLE02_RIPPLES * EXAMPLE02_RIPPLE_CUBES + \
     EXAMPLE02_SCORE_DIGITS * EXAMPLE02_GLYPH_PIXELS)

/// Constants for the loop-search kernel.
typedef struct Example02Params {
    AoCGridSize size;
    uint32_t candidateCount;
} Example02Params;

/// One straight run of the guard: `length` cells from `from` heading `direction`.
/// `start` is the distance walked before it (prefix sum), for animating the walk.
typedef struct Example02Segment {
    uint32_t from;
    uint32_t direction;
    uint32_t length;
    uint32_t start;
} Example02Segment;

/// Summary of the route written by `example02_route`.
typedef struct Example02Route {
    uint32_t count;      ///< Segments written.
    uint32_t loopStart;  ///< First segment of the loop, or EXAMPLE02_NONE if the guard leaves.
    uint32_t total;      ///< Cells walked until the route leaves or closes its loop.
    uint32_t padding;
} Example02Route;

/// Constants for `example02_route`: walk from `startState` with an extra obstruction at `extra`.
typedef struct Example02RouteParams {
    AoCGridSize size;
    uint32_t startState;
    uint32_t extra;
    uint32_t stamp;  ///< Fresh per frame, so the `seen` table never needs clearing.
} Example02RouteParams;

/// Everything the instance kernel needs for one frame. Times are in ticks of the guard's
/// original walk (one tick = one move or one turn), so every effect is scrubbable.
typedef struct Example02VizParams {
    AoCGridSize size;
    uint32_t part;
    float time;  ///< Guard position on its original walk, in ticks (fraction = between ticks).

    simd_float3 guardPosition;  ///< World position of the guard (computed on the CPU).
    simd_float3 scoreAnchor;    ///< World position the score is centred on.

    float scoreVoxel;  ///< Edge length of one score voxel.
    uint32_t guardDirection;
    uint32_t bumpCell;  ///< Obstacle the guard is turning at right now, or EXAMPLE02_NONE.
    float bumpAge;      ///< Ticks since that bump.

    uint32_t score;
    float sinceIncrement;  ///< Ticks since the score last went up.
    float sinceRevisit;    ///< Ticks since the guard last stepped on an already visited tile.
    float sinceMilestone;  ///< Ticks since the score crossed a multiple of 100 (part 2: a loop).

    uint32_t rippleCell[EXAMPLE02_RIPPLES];  ///< EXAMPLE02_NONE for an unused ripple.
    float rippleAge[EXAMPLE02_RIPPLES];      ///< In ticks; a ripple lives for kRippleLife ticks.

    // Part 2: the candidate obstruction being tested.
    uint32_t candidate;  ///< Index into the candidates (in the order the guard reaches them).
    uint32_t candidateCell;
    uint32_t candidateLoops;  ///< 1 if this obstruction traps the guard.
    float progress;           ///< Progress through this candidate's step.
} Example02VizParams;

#endif  // EXAMPLE02_TYPES_H
