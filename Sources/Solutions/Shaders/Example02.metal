// Example 2 — AoC 2024 day 6 "Guard Gallivant"
//
// Data layout (built in Example02.swift):
//   jumps[d * cells + c]  last free cell of a straight run from cell c heading d (aoc::kDirs4),
//                         | EXAMPLE02_EXIT_BIT if the run then leaves the map
//   state                 cell * 4 + direction; EXAMPLE02_EXIT once the guard has left
//
// Solve (part 2) = one dispatch, one thread per candidate obstruction: start where the guard first
// reaches the candidate, jump from turn to turn (each run cut short if it hits the candidate) and
// detect a loop with Brent's algorithm, which needs no memory per thread.
#include "AoCKernels.h"
#include "Example02Types.h"

using namespace metal;

namespace {

int2 cellPoint(uint cell, AoCGridSize size) {
    return int2(uint2(cell % size.width, cell / size.width));
}

/// Last free cell of a straight run from `state` with an extra obstruction at `extra`.
/// `exits` says whether the guard leaves the map after it instead of turning.
uint runEnd(uint state, uint extra, const device uint* jumps, AoCGridSize size, thread bool& exits) {
    const uint cells = size.width * size.height;
    const uint cell = state >> 2;
    const uint direction = state & 3;
    const uint jump = jumps[direction * cells + cell];
    uint stop = jump & ~EXAMPLE02_EXIT_BIT;
    exits = (jump & EXAMPLE02_EXIT_BIT) != 0;

    // Does the extra obstruction sit on this run, before where it would have stopped?
    const int2 from = cellPoint(cell, size);
    const int2 dir = aoc::kDirs4[direction];
    const int2 toExtra = cellPoint(extra, size) - from;
    const int2 toStop = cellPoint(stop, size) - from;
    const int reach = toStop.x * dir.x + toStop.y * dir.y;
    const int ahead = toExtra.x * dir.x + toExtra.y * dir.y;
    const bool inLine = dir.x != 0 ? toExtra.y == 0 : toExtra.x == 0;
    if (inLine && ahead >= 1 && ahead <= reach) {
        exits = false;
        stop = aoc::index(from + dir * (ahead - 1), size);
    }
    return stop;
}

/// The state after the next turn, or EXAMPLE02_EXIT.
uint advance(uint state, uint extra, const device uint* jumps, AoCGridSize size) {
    bool exits;
    const uint stop = runEnd(state, extra, jumps, size, exits);
    return exits ? EXAMPLE02_EXIT : (stop << 2) | (((state & 3) + 1) & 3);
}

/// Brent's cycle detection over turn states. Leaving the map is a fixed point, so the search
/// always ends; it is a loop unless it ended there.
bool loops(uint start, uint extra, const device uint* jumps, AoCGridSize size) {
    uint power = 1;
    uint length = 1;
    uint tortoise = start;
    uint hare = advance(start, extra, jumps, size);
    while (hare != tortoise) {
        if (hare == EXAMPLE02_EXIT) {
            return false;
        }
        if (power == length) {
            tortoise = hare;
            power <<= 1;
            length = 0;
        }
        hare = advance(hare, extra, jumps, size);
        ++length;
    }
    return hare != EXAMPLE02_EXIT;
}

}  // namespace

[[kernel]] void example02_search(const device uint* jumps [[buffer(0)]], const device uint* candidates [[buffer(1)]],
                                 const device uint* starts [[buffer(2)]], device uint* loopFlags [[buffer(3)]],
                                 device atomic_uint* total [[buffer(4)]], constant Example02Params& p [[buffer(5)]],
                                 uint i [[thread_position_in_grid]]) {
    uint found = 0;
    if (i < p.candidateCount) {
        found = loops(starts[i], candidates[i], jumps, p.size) ? 1u : 0u;
        loopFlags[i] = found;
    }
    aoc::reduceAdd(found, total);
}

/// Visualization helper, one thread: the route of the ghost guard for one candidate, as straight
/// segments, until it leaves the map or reaches a state it was in before (the loop start).
/// `seen[state]` = (stamp, segment index) remembers states per frame without clearing.
[[kernel]] void example02_route(const device uint* jumps [[buffer(0)]], device uint2* seen [[buffer(1)]],
                                device Example02Route* route [[buffer(2)]],
                                device Example02Segment* segments [[buffer(3)]],
                                constant Example02RouteParams& p [[buffer(4)]], uint tid [[thread_position_in_grid]]) {
    if (tid != 0) {
        return;
    }
    uint state = p.startState;
    uint count = 0;
    uint total = 0;
    uint loopStart = EXAMPLE02_NONE;
    while (count < EXAMPLE02_MAX_SEGMENTS) {
        const uint2 mark = seen[state];
        if (mark.x == p.stamp) {
            loopStart = mark.y;
            break;
        }
        seen[state] = uint2(p.stamp, count);

        bool exits;
        const uint stop = runEnd(state, p.extra, jumps, p.size, exits);
        const int2 delta = cellPoint(stop, p.size) - cellPoint(state >> 2, p.size);
        Example02Segment segment;
        segment.from = state >> 2;
        segment.direction = state & 3;
        segment.length = uint(abs(delta.x) + abs(delta.y)) + (exits ? 1u : 0u);  // + the step off the map
        segment.start = total;
        segments[count++] = segment;
        total += segment.length;
        if (exits) {
            break;
        }
        state = (stop << 2) | (((state & 3) + 1) & 3);
    }
    Example02Route result;
    result.count = count;
    result.loopStart = loopStart;
    result.total = total;
    result.padding = 0;
    *route = result;
}

// -------------------------------------------------------------------------------------------------
// Visualization. Part 1, one step per tick of the guard's walk (`time` in ticks):
//
//   trail      a tile lights as the guard crosses into it (half a tick before its tick), as a
//              horizontal or vertical bar, both at corners and crossings; it pops up hot yellow
//              and cools to teal over ~60 ticks
//   revisit    stepping onto a lit tile: the tile flashes white, a ring of cubes ripples out
//              (kRippleLife ticks), the score shakes and greys out
//   bump       the obstacle she turns at flashes orange
//   score      voxel digits floating above the guard (facing the camera at kPitch); changed
//              digits hop, every 100 tiles the whole score pops
//
// Part 2, one step per candidate obstruction (`progress` in [0, 1)):
//
//   0.00  the guard walks along her original path to just before the candidate
//   0.10  a crate drops onto the candidate cell ... 0.25 lands with a squash
//   0.25  the ghost guard (cyan) runs the altered route, drawing it ... 0.80 the route ends
//   0.80  verdict. Loop: the loop turns magenta, the ghost keeps circling it, the crate turns
//         magenta (and stays as a marker), magenta ripple, score pops. Escape: the route fades
//         and the crate sinks.
// -------------------------------------------------------------------------------------------------

namespace {

constant float kPitch = 1.05f;  // camera pitch (Example02Scene.pitch); the score faces it
constant float kRippleLife = 8.0f;
constant float kPi = 3.14159265f;

constant float3 kFloorA = float3(0.030f, 0.034f, 0.050f);
constant float3 kFloorB = float3(0.040f, 0.045f, 0.064f);
constant float3 kStone = float3(0.25f, 0.27f, 0.35f);
constant float3 kBumpOrange = float3(1.00f, 0.42f, 0.08f);
constant float3 kFlash = float3(0.85f, 0.97f, 1.00f);
constant float3 kGold = float3(1.00f, 0.78f, 0.22f);
constant float3 kSkin = float3(1.00f, 0.86f, 0.66f);
constant float3 kVisor = float3(0.95f, 0.16f, 0.10f);
constant float3 kCyan = float3(0.20f, 0.80f, 1.00f);
constant float3 kMagenta = float3(1.00f, 0.22f, 0.78f);
constant float3 kCrate = float3(0.88f, 0.52f, 0.18f);
constant float3 kGrey = float3(0.46f, 0.50f, 0.60f);
constant float3 kDimTrail = float3(0.07f, 0.10f, 0.17f);

struct Box {
    float3 position;
    float3 scale;
    float4 color;
};

Box hidden() {
    Box box;
    box.position = float3(0.0f);
    box.scale = float3(0.0f);
    box.color = float4(0.0f);
    return box;
}

Box box(float3 position, float3 scale, float3 color, float alpha = 1.0f) {
    Box b;
    b.position = position;
    b.scale = scale;
    b.color = float4(color, alpha);
    return b;
}

float3 world(uint cell, AoCGridSize size) {
    const int2 p = cellPoint(cell, size);
    return float3(float(p.x) - float(size.width) * 0.5f + 0.5f, 0.0f, float(p.y) - float(size.height) * 0.5f + 0.5f);
}

float3 dirVector(uint direction) {
    const int2 d = aoc::kDirs4[direction & 3];
    return float3(float(d.x), 0.0f, float(d.y));
}

/// 1 right after an event, fading to 0 over `life` ticks; 0 before the event.
float fade(float age, float life) {
    return age >= 0.0f && age < life ? 1.0f - age / life : 0.0f;
}

/// Strongest active ripple on `cell` (part 1 revisit flash), 0..1.
float rippleOn(uint cell, constant Example02VizParams& p) {
    float strongest = 0.0f;
    for (uint r = 0; r < EXAMPLE02_RIPPLES; ++r) {
        if (p.rippleCell[r] == cell) {
            strongest = max(strongest, fade(p.rippleAge[r], kRippleLife));
        }
    }
    return strongest;
}

/// Ghost guard's distance along the route at this frame (part 2).
float ghostDistance(constant Example02VizParams& p, const device Example02Route* route,
                    const device Example02Segment* segments) {
    const float total = float(route->total);
    const float run = total * aoc::phase(p.progress, 0.25f, 0.80f);
    if (p.progress < 0.80f || route->loopStart == EXAMPLE02_NONE || route->count == 0) {
        return run;
    }
    // Trapped: keep circling the loop during the verdict.
    const float loopFrom = float(segments[route->loopStart].start);
    const float loopLength = max(total - loopFrom, 1.0f);
    return loopFrom + fmod(total - loopFrom + (p.progress - 0.80f) * 2.5f * loopLength, loopLength);
}

/// Position and heading of the ghost guard at `distance` along the route.
float3 ghostAt(float distance, const device Example02Route* route, const device Example02Segment* segments,
               AoCGridSize size, thread uint& direction) {
    direction = 0;
    if (route->count == 0) {
        return float3(0.0f);
    }
    uint s = 0;
    while (s + 1 < route->count && float(segments[s + 1].start) <= distance) {
        ++s;
    }
    const Example02Segment segment = segments[s];
    direction = segment.direction;
    const float along = clamp(distance - float(segment.start), 0.0f, float(segment.length));
    return world(segment.from, size) + dirVector(segment.direction) * along;
}

/// Floor tile, obstacle, or (part 2) a crate on cell `cell`.
Box cellBox(uint cell, const device uchar* blocked, const device uint* candidateOf, const device uint* loopFlags,
            constant Example02VizParams& p) {
    const float3 at = world(cell, p.size);
    const uint h = aoc::hash(cell);
    if (blocked[cell] != 0) {
        const float shade = 0.85f + 0.3f * float(h & 0xffu) / 255.0f;
        const float flash = cell == p.bumpCell ? fade(p.bumpAge, 2.0f) : 0.0f;
        const float height = 1.1f + 0.25f * flash;
        const float width = 0.9f * (1.0f + 0.12f * flash);
        return box(at + float3(0.0f, height * 0.5f, 0.0f), float3(width, height, width),
                   mix(kStone * shade, kBumpOrange, flash * flash));
    }

    if (p.part == 2) {
        const uint candidate = candidateOf[cell];
        if (candidate != EXAMPLE02_NONE && candidate < p.candidate && loopFlags[candidate] != 0) {
            return box(at + float3(0.0f, 0.3f, 0.0f), float3(0.62f, 0.6f, 0.62f), kMagenta * 0.8f);
        }
        if (cell == p.candidateCell && p.progress >= 0.10f) {
            const float fall = aoc::linear(p.progress, 0.10f, 0.25f);
            const float squash = 0.35f * aoc::springBack(aoc::linear(p.progress, 0.25f, 0.45f));
            float3 scale =
                float3(0.78f * (1.0f + squash * 0.5f), 0.78f * (1.0f - squash), 0.78f * (1.0f + squash * 0.5f));
            float3 color = kCrate;
            if (p.progress >= 0.80f) {
                const float verdict = aoc::phase(p.progress, 0.80f, 0.88f);
                if (p.candidateLoops != 0) {
                    color = mix(kCrate, kMagenta, verdict);
                    scale *= 1.0f + 0.35f * aoc::springBack(aoc::linear(p.progress, 0.80f, 1.0f));
                } else {
                    scale *= 1.0f - aoc::phase(p.progress, 0.82f, 0.98f);
                }
            }
            const float y = scale.y * 0.5f + 9.0f * (1.0f - fall) * (1.0f - fall);
            return box(at + float3(0.0f, y, 0.0f), scale, color);
        }
    }

    const bool even = ((cell % p.size.width) + (cell / p.size.width)) % 2 == 0;
    return box(at + float3(0.0f, -0.05f, 0.0f), float3(0.96f, 0.1f, 0.96f), even ? kFloorA : kFloorB);
}

/// Trail bar along `horizontal` (x) or vertical (z) on `cell`, first crossed at tick `firstTick`.
Box trailBar(uint cell, uint firstTick, bool horizontal, constant Example02VizParams& p) {
    if (firstTick == EXAMPLE02_NONE) {
        return hidden();
    }
    const float age = p.time - (float(firstTick) - 0.5f);
    float3 color;
    float grow = 1.0f;
    float height = 0.14f;
    if (p.part == 2) {
        // The original path, lit where the guard has already walked.
        color = age >= 0.0f ? aoc::heatColor(0.34f) * 0.75f : kDimTrail;
    } else {
        if (age < 0.0f) {
            return hidden();
        }
        grow = aoc::easeOutBack(saturate(age / 1.5f));
        const float spike = saturate(1.0f - age / 3.0f);
        height += 0.5f * spike * spike;
        color = aoc::heatColor(0.30f + 0.70f * exp(-age / 60.0f));
        const float flash = rippleOn(cell, p);
        color = mix(color, kFlash, flash);
        height += 0.45f * flash;
    }
    if (!horizontal) {
        height += 0.01f;  // vertical bars sit a hair higher so crossings don't z-fight
    }
    const float across = 0.34f * grow;
    const float along = mix(0.34f, 1.0f, saturate(grow));
    const float3 scale = horizontal ? float3(along, height, across) : float3(across, height, along);
    return box(world(cell, p.size) + float3(0.0f, height * 0.5f, 0.0f), scale, color);
}

/// Segment `s` of the ghost's route, revealed as far as the ghost has run (part 2).
Box routeBar(uint s, constant Example02VizParams& p, const device Example02Route* route,
             const device Example02Segment* segments) {
    if (p.part != 2 || p.candidateCell == EXAMPLE02_NONE || s >= route->count || p.progress < 0.25f) {
        return hidden();
    }
    const Example02Segment segment = segments[s];
    const float run = float(route->total) * aoc::phase(p.progress, 0.25f, 0.80f);
    const float shown = clamp(run - float(segment.start), 0.0f, float(segment.length));
    if (shown <= 0.0f) {
        return hidden();
    }
    float thickness = 0.24f;
    float3 color = kCyan;
    if (p.progress >= 0.80f) {
        const float verdict = aoc::phase(p.progress, 0.80f, 0.86f);
        const bool inLoop = route->loopStart != EXAMPLE02_NONE && s >= route->loopStart;
        if (inLoop) {
            const float pulse = 0.5f + 0.5f * sin((p.progress - 0.80f) * 60.0f);
            color = mix(kCyan, kMagenta, verdict);
            thickness *= 1.0f + 0.6f * verdict * pulse;
        } else {
            thickness *= 1.0f - aoc::phase(p.progress, 0.82f, 0.97f);
        }
    }
    const float3 dir = dirVector(segment.direction);
    const float3 center = world(segment.from, p.size) + dir * (shown * 0.5f) + float3(0.0f, 0.42f, 0.0f);
    const float length = shown + thickness;
    const float3 scale =
        segment.direction % 2 == 0 ? float3(length, 0.16f, thickness) : float3(thickness, 0.16f, length);
    return box(center, scale, color);
}

/// Guard (slots 0-2) or ghost guard (3-5): body, head, visor facing `direction`.
Box actorPart(uint part, float3 base, uint direction, float3 bodyColor, float scale) {
    switch (part) {
        case 0:
            return box(base + float3(0.0f, 0.42f, 0.0f) * scale, float3(0.52f, 0.66f, 0.52f) * scale, bodyColor);
        case 1:
            return box(base + float3(0.0f, 0.98f, 0.0f) * scale, float3(0.42f, 0.42f, 0.42f) * scale, kSkin);
        default: {
            const float3 dir = dirVector(direction);
            const float3 extent = abs(dir) * 0.14f + (1.0f - abs(dir)) * float3(0.36f, 0.12f, 0.36f);
            return box(base + (float3(0.0f, 1.02f, 0.0f) + dir * 0.24f) * scale, extent * scale, kVisor);
        }
    }
}

/// One cube of ripple ring `r`.
Box rippleCube(uint r, uint k, constant Example02VizParams& p) {
    const uint cell = p.rippleCell[r];
    const float age = p.rippleAge[r];
    if (cell == EXAMPLE02_NONE || age < 0.0f || age >= kRippleLife) {
        return hidden();
    }
    const float life = age / kRippleLife;
    const float angle = 2.0f * kPi * (float(k) + 0.5f * float(r)) / float(EXAMPLE02_RIPPLE_CUBES);
    const float radius = 0.4f + 2.2f * aoc::easeOutCubic(life);
    const float3 offset = float3(cos(angle) * radius, 0.3f + 0.5f * sin(kPi * life), sin(angle) * radius);
    const float size = 0.34f * (1.0f - life * life);
    return box(world(cell, p.size) + offset, float3(size), p.part == 2 ? kMagenta : mix(kFlash, kCyan, life));
}

/// One voxel of the score.
Box scoreVoxel(uint digitSlot, uint pixel, constant Example02VizParams& p) {
    uint digits = 1;
    for (uint v = p.score; v >= 10; v /= 10) {
        ++digits;
    }
    if (digitSlot >= digits) {
        return hidden();
    }
    uint power = 1;
    for (uint i = digitSlot + 1; i < digits; ++i) {
        power *= 10;
    }
    const uint digit = (p.score / power) % 10;
    const uint col = pixel % 5;
    const uint row = pixel / 5;
    if (!aoc::glyphPixel(uchar('0' + digit), col, row)) {
        return hidden();
    }

    const float v = p.scoreVoxel;
    // Pop: zoom in with overshoot, then spring back (every 100 tiles; part 2: every loop).
    const float popAge = p.sinceMilestone;
    float pop = 0.0f;
    if (popAge >= 0.0f && popAge < 1.5f) {
        pop = aoc::easeOutBack(popAge / 1.5f);
    } else if (popAge >= 1.5f) {
        pop = aoc::springBack((popAge - 1.5f) / 5.0f);
    }
    const float zoom = 1.0f + 0.9f * pop;

    float x = float(digitSlot * 6 + col) - (float(digits * 6) - 1.0f) * 0.5f + 0.5f;
    float y = 3.0f - float(row);
    // Digits that changed with the last increment hop.
    if (p.score > 0 && ((p.score - 1) / power) % 10 != digit) {
        y += 1.4f * sin(kPi * saturate(p.sinceIncrement / 1.2f)) * step(p.sinceIncrement, 1.2f);
    }
    // Revisit: no points, so the score shakes and greys out.
    const float shake = p.part == 1 ? exp(-max(p.sinceRevisit, 0.0f) * 0.45f) : 0.0f;
    x += 1.2f * sin(p.sinceRevisit * 11.0f) * shake;

    float3 color = p.part == 2 ? mix(kGold, kMagenta, 0.55f) : kGold;
    color = mix(color, kGrey, 0.85f * shake);
    color = mix(color, float3(1.0f), 0.6f * saturate(pop));
    const float3 right = float3(1.0f, 0.0f, 0.0f);
    const float3 up = float3(0.0f, cos(kPitch), -sin(kPitch));
    const float3 position = p.scoreAnchor + (right * x + up * y) * v * zoom;
    return box(position, float3(v * zoom * 0.92f), color);
}

}  // namespace

/// One thread per instance slot, in the order given by EXAMPLE02_INSTANCE_COUNT.
[[kernel]] void example02_instances(
    const device uchar* blocked [[buffer(0)]], const device uint* firstHorizontal [[buffer(1)]],
    const device uint* firstVertical [[buffer(2)]], const device uint* candidateOf [[buffer(3)]],
    const device uint* loopFlags [[buffer(4)]], const device Example02Route* route [[buffer(5)]],
    const device Example02Segment* segments [[buffer(6)]], device AoCInstance* out [[buffer(7)]],
    constant Example02VizParams& p [[buffer(8)]], uint i [[thread_position_in_grid]]) {
    const uint cells = p.size.width * p.size.height;
    if (i >= EXAMPLE02_INSTANCE_COUNT(cells)) {
        return;
    }
    const uint routeBase = 3 * cells;
    const uint actorBase = routeBase + EXAMPLE02_MAX_SEGMENTS;
    const uint rippleBase = actorBase + EXAMPLE02_ACTOR_SLOTS;
    const uint scoreBase = rippleBase + EXAMPLE02_RIPPLES * EXAMPLE02_RIPPLE_CUBES;

    const bool ghostVisible = p.part == 2 && p.candidateCell != EXAMPLE02_NONE && p.progress >= 0.25f &&
                              (p.progress < 0.92f || p.candidateLoops != 0);
    Box b = hidden();
    if (i < cells) {
        b = cellBox(i, blocked, candidateOf, loopFlags, p);
    } else if (i < 2 * cells) {
        b = trailBar(i - cells, firstHorizontal[i - cells], true, p);
    } else if (i < routeBase) {
        b = trailBar(i - 2 * cells, firstVertical[i - 2 * cells], false, p);
    } else if (i < actorBase) {
        b = routeBar(i - routeBase, p, route, segments);
    } else if (i < rippleBase) {
        const uint part = i - actorBase;
        if (part < 3) {
            b = actorPart(part, p.guardPosition, p.guardDirection, kGold, 1.0f);
        } else if (ghostVisible) {
            uint direction;
            const float3 at = ghostAt(ghostDistance(p, route, segments), route, segments, p.size, direction);
            b = actorPart(part - 3, at + float3(0.0f, 0.1f, 0.0f), direction, kCyan, 0.85f);
        }
    } else if (i < scoreBase) {
        const uint index = i - rippleBase;
        b = rippleCube(index / EXAMPLE02_RIPPLE_CUBES, index % EXAMPLE02_RIPPLE_CUBES, p);
    } else {
        const uint index = i - scoreBase;
        b = scoreVoxel(index / EXAMPLE02_GLYPH_PIXELS, index % EXAMPLE02_GLYPH_PIXELS, p);
    }

    AoCInstance inst;
    inst.position = b.position;
    inst.scale = b.scale;
    inst.color = b.color;
    out[i] = inst;
}
