// Example 3 — AoC 2022 day 17 "Pyroclastic Flow"
//
// GPU-driven 3D visualization of falling rocks inside a 7-wide volcanic chamber with translucent
// obsidian walls, pulsing gas-jet nozzles, wind streaks, impact embers, and a floating voxel
// height counter.
//
// Part 1 timeline (one step per rock, progress in [0, 1)):
//   0.00  rock spawns 3 units above the tower with a pop-in (easeOutBack)
//   0.08  plays through every recorded (jet push -> drop) tick; wall vent flares and wind streaks
//         blast across the chamber; blocked pushes give a brief bounce
//   0.86  impact! rock locks into the tower, flashes white-hot, embers burst upward, height ticks
//
// Part 2 timeline (cycle detection + 10^12 hyper-jump):
//   prefix    rocks settle in normal volcanic mineral hues
//   cycle 1   rocks in [cycleStart, cycleStart + cycleLength) glow cyan
//   cycle 2   identical repeating band glows magenta right on top of cycle 1
//   jump      warp step: chamber pulses cyan/magenta, vertical warp streaks fly past, and the
//             13-digit voxel height counter rockets across the skipped cycles
//   tail      remaining rocks drop on top to land on the exact 10^12 tower height
#include "AoCKernels.h"
#include "Example03Types.h"

using namespace metal;

namespace {

constant uint kShapeCount[5] = {4, 5, 5, 4, 4};

// Local (dx, dy) cell offsets for the 5 AoC 2022 day 17 rock shapes (dx right, dy up).
constant int2 kShapeCells[5][5] = {
    {int2(0, 0), int2(1, 0), int2(2, 0), int2(3, 0), int2(0, 0)},  // 0: -
    {int2(1, 0), int2(0, 1), int2(1, 1), int2(2, 1), int2(1, 2)},  // 1: +
    {int2(0, 0), int2(1, 0), int2(2, 0), int2(2, 1), int2(2, 2)},  // 2: J
    {int2(0, 0), int2(0, 1), int2(0, 2), int2(0, 3), int2(0, 0)},  // 3: |
    {int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1), int2(0, 0)},  // 4: o
};

// Volcanic mineral palette, one distinct colour per rock shape.
constant float3 kShapeColor[5] = {
    float3(0.98f, 0.68f, 0.18f),  // 0: -  amber gold
    float3(0.22f, 0.84f, 0.48f),  // 1: +  emerald jade
    float3(0.26f, 0.58f, 0.98f),  // 2: J  cobalt azure
    float3(0.72f, 0.38f, 0.96f),  // 3: |  amethyst
    float3(0.96f, 0.32f, 0.36f),  // 4: o  volcanic coral
};

constant float3 kBasalt = float3(0.11f, 0.12f, 0.17f);
constant float3 kGlass = float3(0.16f, 0.24f, 0.38f);
constant float3 kLava = float3(1.00f, 0.34f, 0.06f);
constant float3 kHotGold = float3(1.00f, 0.92f, 0.52f);
constant float3 kJetRight = float3(1.00f, 0.52f, 0.12f);
constant float3 kJetLeft = float3(0.18f, 0.86f, 1.00f);
constant float3 kCyan = float3(0.16f, 0.88f, 1.00f);
constant float3 kMagenta = float3(1.00f, 0.24f, 0.78f);

constant float kSpawnEnd = 0.08f;
constant float kLandAt = 0.86f;

struct Box {
    float3 position;
    float3 scale;
    float4 color;
};

Box hidden() {
    Box b;
    b.position = float3(0.0f);
    b.scale = float3(0.0f);
    b.color = float4(0.0f);
    return b;
}

Box makeBox(float3 position, float3 scale, float3 color, float alpha = 1.0f) {
    Box b;
    b.position = position;
    b.scale = scale;
    b.color = float4(color, alpha);
    return b;
}

/// World coordinate of chamber cell (col 0..6, row 0..).
float3 cellWorld(float col, float row) {
    return float3(col - 3.0f, row + 0.5f, 0.0f);
}

struct ActivePose {
    float x;
    float y;
    float scale;
    int jetDir;
    float jetStrength;
    bool visible;
};

/// Evaluates the currently falling rock's interpolated position and active jet pulse.
ActivePose activeRockPose(const device Example03RockInfo* rocks, const device Example03FallStep* steps,
                          constant Example03VizParams& p) {
    ActivePose pose;
    pose.x = 2.0f;
    pose.y = float(p.windowBottom);
    pose.scale = 1.0f;
    pose.jetDir = 0;
    pose.jetStrength = 0.0f;
    pose.visible = false;

    if (p.activeRock == EXAMPLE03_NONE || p.isHyperJump != 0 || p.progress >= kLandAt) {
        return pose;
    }

    const Example03RockInfo info = rocks[p.activeRock];
    if (info.fallCount == 0) {
        return pose;
    }
    const Example03FallStep firstStep = steps[info.fallOffset];
    const float spawnY = float(firstStep.yBeforeDrop);

    pose.visible = true;
    if (p.progress < kSpawnEnd) {
        pose.x = 2.0f;
        pose.y = spawnY;
        pose.scale = aoc::easeOutBack(aoc::linear(p.progress, 0.0f, kSpawnEnd));
        return pose;
    }

    const float u = aoc::linear(p.progress, kSpawnEnd, kLandAt) * float(info.fallCount);
    const uint stepIdx = min(uint(u), info.fallCount - 1u);
    const float frac = saturate(u - float(stepIdx));
    const Example03FallStep step = steps[info.fallOffset + stepIdx];

    const float prevX = stepIdx == 0 ? 2.0f : float(steps[info.fallOffset + stepIdx - 1u].xAfterJet);
    const float nextX = float(step.xAfterJet);
    const float startY = float(step.yBeforeDrop);
    const bool isFinal = stepIdx + 1u == info.fallCount;
    const float endY = isFinal ? float(info.finalY) : float(steps[info.fallOffset + stepIdx + 1u].yBeforeDrop);

    if (frac < 0.5f) {
        const float jf = aoc::phase(frac, 0.0f, 0.5f);
        if (step.blocked != 0) {
            pose.x = prevX + float(step.jetDir) * 0.16f * sin(jf * M_PI_F);
        } else {
            pose.x = mix(prevX, nextX, jf);
        }
        pose.y = startY;
        pose.jetDir = step.jetDir;
        pose.jetStrength = sin(frac * 2.0f * M_PI_F);
    } else {
        const float df = aoc::phase(frac, 0.5f, 1.0f);
        pose.x = nextX;
        pose.y = mix(startY, endY, df);
        pose.jetDir = step.jetDir;
        pose.jetStrength = 0.25f * (1.0f - df);
    }
    return pose;
}

Box chamberCellBox(uint index, const device Example03Cell* cells, constant Example03VizParams& p) {
    const uint localRow = index / EXAMPLE03_WIDTH;
    const uint col = index % EXAMPLE03_WIDTH;
    const uint row = p.windowBottom + localRow;
    if (row >= p.totalRows) {
        return hidden();
    }
    const Example03Cell cell = cells[row * EXAMPLE03_WIDTH + col];
    if (cell.rockIndex == EXAMPLE03_NONE || cell.rockIndex >= p.settledCount) {
        return hidden();
    }

    const uint shape = min(cell.shape, 4u);
    const float shade = 0.86f + 0.22f * float(aoc::hash(cell.rockIndex * 17u + col) & 0xffu) / 255.0f;
    float3 color = kShapeColor[shape] * shade;
    float3 scale = float3(0.92f, 0.92f, 0.92f);

    // Part 2 cycle bands: highlight Cycle 1 in cyan and its identical repeat Cycle 2 in magenta.
    if (p.part == 2 && p.cycleLength > 0) {
        const uint c1Start = p.cycleStart;
        const uint c2Start = p.cycleStart + p.cycleLength;
        const uint c2End = c2Start + p.cycleLength;
        if (cell.rockIndex >= c1Start && cell.rockIndex < c2Start) {
            color = mix(color, kCyan, 0.62f);
        } else if (cell.rockIndex >= c2Start && cell.rockIndex < c2End) {
            color = mix(color, kMagenta, 0.65f);
        }
    }

    // Fresh impact flash on the rock that just settled.
    if (p.settledCount > 0 && cell.rockIndex + 1u == p.settledCount && p.isHyperJump == 0) {
        const float flash = saturate(1.0f - p.impactAge);
        color = mix(color, kHotGold, flash * 0.85f);
        const float squash = 0.14f * aoc::springBack(p.impactAge);
        scale = float3(0.92f * (1.0f + squash), 0.92f * (1.0f - squash), 0.92f * (1.0f + squash));
    }

    // During Part 2 hyper-jump, sweep an energetic cyan/magenta wave across the tower.
    if (p.isHyperJump != 0) {
        const float wave = 0.5f + 0.5f * sin(float(row) * 0.65f - p.progress * 24.0f);
        const float envelope = sin(M_PI_F * saturate(p.progress));
        color = mix(color, mix(kCyan, kMagenta, wave), 0.55f * envelope);
    }

    return makeBox(cellWorld(float(col), float(row)), scale, color);
}

Box activeRockCellBox(uint cellSlot, const device Example03RockInfo* rocks, ActivePose pose,
                      constant Example03VizParams& p) {
    if (!pose.visible) {
        return hidden();
    }
    const uint shape = min(rocks[p.activeRock].shape, 4u);
    if (cellSlot >= kShapeCount[shape]) {
        return hidden();
    }
    const int2 offset = kShapeCells[shape][cellSlot];
    const float3 pos = cellWorld(pose.x + float(offset.x), pose.y + float(offset.y));
    const float3 color = mix(kShapeColor[shape], kHotGold, 0.35f + 0.25f * pose.jetStrength);
    return makeBox(pos, float3(0.95f) * pose.scale, color);
}

Box frameBox(uint slot, ActivePose pose, constant Example03VizParams& p) {
    const float winBottom = float(p.windowBottom);
    const float winHeight = float(EXAMPLE03_WINDOW_ROWS);
    const float winMidY = winBottom + winHeight * 0.5f;
    const float wallX = 3.72f;
    const float pillarX = 3.84f;

    switch (slot) {
        case 0:  // Solid basalt floor slab (only visible near y = 0).
            if (p.windowBottom > 2u) {
                return hidden();
            }
            return makeBox(float3(0.0f, -0.55f, 0.0f), float3(8.2f, 0.7f, 2.1f), kBasalt * 1.15f);
        case 1: {  // Glowing lava crust at y = 0.
            if (p.windowBottom > 2u) {
                return hidden();
            }
            const float shimmer = 0.85f + 0.15f * sin(p.time * 3.0f);
            return makeBox(float3(0.0f, -0.10f, 0.0f), float3(7.05f, 0.20f, 1.35f), kLava * shimmer);
        }
        case 2:  // Left translucent obsidian glass wall.
            return makeBox(float3(-wallX, winMidY, 0.0f), float3(0.22f, winHeight, 1.55f), kGlass, 0.26f);
        case 3:  // Right translucent obsidian glass wall.
            return makeBox(float3(wallX, winMidY, 0.0f), float3(0.22f, winHeight, 1.55f), kGlass, 0.26f);
        case 4:  // Back translucent wall.
            return makeBox(float3(0.0f, winMidY, -0.86f), float3(7.30f, winHeight, 0.14f), kGlass * 0.65f, 0.22f);
        case 5:  // Front-left basalt rail.
            return makeBox(float3(-pillarX, winMidY, 0.78f), float3(0.26f, winHeight, 0.26f), kBasalt);
        case 6:  // Front-right basalt rail.
            return makeBox(float3(pillarX, winMidY, 0.78f), float3(0.26f, winHeight, 0.26f), kBasalt);
        case 7:  // Back-left basalt rail.
            return makeBox(float3(-pillarX, winMidY, -0.78f), float3(0.26f, winHeight, 0.26f), kBasalt);
        case 8:  // Back-right basalt rail.
            return makeBox(float3(pillarX, winMidY, -0.78f), float3(0.26f, winHeight, 0.26f), kBasalt);
        default: {  // Active gas-jet nozzle on the blasting wall.
            if (!pose.visible || pose.jetDir == 0 || pose.jetStrength < 0.05f) {
                return hidden();
            }
            const float side = pose.jetDir > 0 ? -3.66f : 3.66f;
            const float3 color = pose.jetDir > 0 ? kJetRight : kJetLeft;
            return makeBox(float3(side, pose.y + 1.0f, 0.0f), float3(0.38f, 1.4f + 0.8f * pose.jetStrength, 0.95f),
                           mix(color, kHotGold, 0.4f * pose.jetStrength));
        }
    }
}

Box jetStreakBox(uint k, ActivePose pose, constant Example03VizParams& p) {
    if (!pose.visible || pose.jetDir == 0 || pose.jetStrength < 0.08f) {
        return hidden();
    }
    const uint h = aoc::hash(k * 97u + p.activeRock * 13u);
    const float laneY = (float(h & 0xffu) / 255.0f - 0.35f) * 2.4f;
    const float laneZ = ((float((h >> 8) & 0xffu) / 255.0f) - 0.5f) * 0.9f;
    const float phase = fract(float(k) / float(EXAMPLE03_JET_STREAKS) + p.progress * 11.0f);
    const float dir = float(pose.jetDir);
    const float x = mix(-3.3f * dir, 3.3f * dir, phase);
    const float len = (0.7f + 1.2f * pose.jetStrength) * sin(M_PI_F * phase);
    const float3 color = pose.jetDir > 0 ? kJetRight : kJetLeft;
    return makeBox(float3(x, pose.y + 0.8f + laneY, laneZ), float3(len, 0.09f, 0.09f), color, 0.72f);
}

Box particleBox(uint k, const device Example03RockInfo* rocks, constant Example03VizParams& p) {
    const uint h1 = aoc::hash(k * 31u + p.settledCount * 131u);
    const uint h2 = aoc::hash(h1);
    const float r1 = float(h1 & 0xffffu) / 65535.0f;
    const float r2 = float(h2 & 0xffffu) / 65535.0f;

    if (p.isHyperJump != 0) {
        // High-speed vertical cyan/magenta warp streaks rushing past the chamber walls.
        const float envelope = sin(M_PI_F * saturate(p.progress));
        if (envelope < 0.04f) {
            return hidden();
        }
        const float side = (k % 2u == 0u ? -1.0f : 1.0f) * (4.4f + 2.8f * r1);
        const float z = (r2 - 0.5f) * 4.0f;
        const float yFrac = fract(r1 + r2 - p.progress * (3.0f + 2.5f * r2));
        const float y = float(p.windowBottom) + yFrac * float(EXAMPLE03_WINDOW_ROWS);
        const float3 color = (k % 3u == 0u) ? kMagenta : kCyan;
        return makeBox(float3(side, y, z), float3(0.14f, 2.6f * envelope, 0.14f), color, 0.78f);
    }

    if (p.activeRock == EXAMPLE03_NONE || p.progress < kLandAt) {
        return hidden();
    }
    const float dt = aoc::linear(p.progress, kLandAt, 1.0f);
    const Example03RockInfo info = rocks[p.activeRock];
    const uint shape = min(info.shape, 4u);
    const int2 cell = kShapeCells[shape][k % kShapeCount[shape]];
    const float3 origin = cellWorld(float(info.finalX) + float(cell.x), float(info.finalY) + float(cell.y));
    const float angle = r1 * 2.0f * M_PI_F;
    const float speed = 1.6f + 2.6f * r2;
    const float3 vel = float3(cos(angle) * speed, 2.4f + 2.8f * r1, sin(angle) * speed * 0.7f);
    const float3 pos = origin + vel * dt + float3(0.0f, -4.5f, 0.0f) * dt * dt;
    const float size = 0.22f * (1.0f - dt * dt);
    const float3 color = mix(kHotGold, kLava, dt);
    return makeBox(pos, float3(size), color);
}

Box scoreVoxelBox(uint digitSlot, uint pixel, constant Example03VizParams& p) {
    const ulong value = p.displayHeight;
    uint digits = 1;
    for (ulong v = value; v >= 10ul; v /= 10ul) {
        ++digits;
    }
    if (digitSlot >= digits || digitSlot >= EXAMPLE03_SCORE_DIGITS) {
        return hidden();
    }
    ulong power = 1ul;
    for (uint i = digitSlot + 1u; i < digits; ++i) {
        power *= 10ul;
    }
    const uint digit = uint((value / power) % 10ul);
    const uint col = pixel % 5u;
    const uint row = pixel / 5u;
    if (!aoc::glyphPixel(uchar('0' + digit), col, row)) {
        return hidden();
    }

    // Shrink voxel size smoothly for 13-digit Part 2 numbers so the full readout fits comfortably.
    const float baseVoxel = digits > 7u ? 0.15f : 0.25f;
    const float zoom = 1.0f + 0.35f * p.popAmount;
    const float v = baseVoxel * zoom;

    const float x = float(digitSlot * 6u + col) - (float(digits * 6u) - 1.0f) * 0.5f + 0.5f;
    float y = 3.0f - float(row);
    const uint prevDigit = uint((p.previousHeight / power) % 10ul);
    if (p.displayHeight != p.previousHeight && prevDigit != digit) {
        y += 1.6f * sin(M_PI_F * saturate(p.impactAge));
    }

    float3 color = p.part == 2 ? mix(kHotGold, kMagenta, 0.35f + 0.45f * p.popAmount) : kHotGold;
    color = mix(color, float3(1.0f), 0.5f * saturate(p.popAmount));
    const float3 anchor = float3(0.0f, p.cameraY + 9.8f, 1.8f);
    return makeBox(anchor + float3(x * v, y * v, 0.0f), float3(v * 0.90f, v * 0.90f, v * 1.5f), color);
}

}  // namespace

[[kernel]] void example03_instances(const device Example03Cell* cells [[buffer(0)]],
                                    const device Example03RockInfo* rocks [[buffer(1)]],
                                    const device Example03FallStep* steps [[buffer(2)]],
                                    device AoCInstance* out [[buffer(3)]], constant Example03VizParams& p [[buffer(4)]],
                                    uint i [[thread_position_in_grid]]) {
    if (i >= EXAMPLE03_INSTANCE_COUNT) {
        return;
    }

    const uint cellSlots = EXAMPLE03_WINDOW_ROWS * EXAMPLE03_WIDTH;
    const uint rockBase = cellSlots;
    const uint frameBase = rockBase + EXAMPLE03_ROCK_CELLS;
    const uint jetBase = frameBase + EXAMPLE03_FRAME_SLOTS;
    const uint particleBase = jetBase + EXAMPLE03_JET_STREAKS;
    const uint scoreBase = particleBase + EXAMPLE03_PARTICLES;

    const ActivePose pose = activeRockPose(rocks, steps, p);
    Box b = hidden();

    if (i < rockBase) {
        b = chamberCellBox(i, cells, p);
    } else if (i < frameBase) {
        b = activeRockCellBox(i - rockBase, rocks, pose, p);
    } else if (i < jetBase) {
        b = frameBox(i - frameBase, pose, p);
    } else if (i < particleBase) {
        b = jetStreakBox(i - jetBase, pose, p);
    } else if (i < scoreBase) {
        b = particleBox(i - particleBase, rocks, p);
    } else {
        const uint index = i - scoreBase;
        b = scoreVoxelBox(index / EXAMPLE03_GLYPH_PIXELS, index % EXAMPLE03_GLYPH_PIXELS, p);
    }

    AoCInstance inst;
    inst.position = b.position;
    inst.scale = b.scale;
    inst.color = b.color;
    out[i] = inst;
}
