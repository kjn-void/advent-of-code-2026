// Example 1 — AoC 2023 day 1 "Trebuchet?!"
//
// Data layout (built in Example01.swift):
//   bytes[i]      raw input bytes
//   lineOf[i]     line index of byte i
//   lineStart[l]  offset of the first byte of line l
//
// Solve = two dispatches:
//   1. example01_scan:    one thread per byte; if a digit (or spelled digit) starts here,
//                         atomically min/max its offset into first[line] / last[line].
//   2. example01_combine: one thread per line; 10 * first + last, summed with a SIMD reduction.
#include "AoCKernels.h"
#include "Example01Types.h"

using namespace metal;

namespace {

constant uint kNone = 0xffffffffu;

constant uchar kWords[9][6] = {"one", "two", "three", "four", "five", "six", "seven", "eight", "nine"};
constant uint kWordLength[9] = {3, 3, 5, 4, 4, 3, 5, 5, 4};

/// Digit value (0-9) of the token starting at byte `i`, or -1. `wordLength` receives the token
/// length (1 for a plain digit). Spelled digits may overlap ("eightwo" holds 8 and 2).
int digitAt(const device uchar* bytes, uint i, uint count, bool spelled, thread uint& wordLength) {
    const uchar c = bytes[i];
    wordLength = 1;
    if (c >= '0' && c <= '9') {
        return int(c - '0');
    }
    if (!spelled) {
        return -1;
    }
    for (uint w = 0; w < 9; ++w) {
        const uint len = kWordLength[w];
        if (i + len > count || c != kWords[w][0]) {
            continue;
        }
        bool match = true;
        for (uint k = 1; k < len && match; ++k) {
            match = bytes[i + k] == kWords[w][k];
        }
        if (match) {
            wordLength = len;
            return int(w + 1);
        }
    }
    return -1;
}

}  // namespace

[[kernel]] void example01_scan(const device uchar* bytes [[buffer(0)]], const device uint* lineOf [[buffer(1)]],
                               device atomic_uint* first [[buffer(2)]], device atomic_uint* last [[buffer(3)]],
                               constant Example01Params& params [[buffer(4)]], uint i [[thread_position_in_grid]]) {
    uint length;
    if (digitAt(bytes, i, params.byteCount, params.spelledDigits != 0, length) < 0) {
        return;
    }
    const uint line = lineOf[i];
    atomic_fetch_min_explicit(&first[line], i, memory_order_relaxed);
    atomic_fetch_max_explicit(&last[line], i, memory_order_relaxed);
}

[[kernel]] void example01_combine(const device uchar* bytes [[buffer(0)]], const device uint* first [[buffer(1)]],
                                  const device uint* last [[buffer(2)]], device uint* lineValue [[buffer(3)]],
                                  device atomic_uint* total [[buffer(4)]],
                                  constant Example01Params& params [[buffer(5)]],
                                  uint line [[thread_position_in_grid]]) {
    uint value = 0;
    if (first[line] != kNone) {
        uint length;
        const bool spelled = params.spelledDigits != 0;
        const int tens = digitAt(bytes, first[line], params.byteCount, spelled, length);
        const int ones = digitAt(bytes, last[line], params.byteCount, spelled, length);
        value = uint(tens * 10 + ones);
    }
    lineValue[line] = value;
    aoc::reduceAdd64(value, total);
}

// -------------------------------------------------------------------------------------------------
// Visualisation: the current line rendered as extruded 5x7 voxel text, animated by `progress`:
//
//   0.00  letters drop in (next lines wait dimmed below)
//   0.10  every digit token lights up blue (part 2: spelled words too); first green, last orange
//   0.20  characters outside [first, last] turn red ... 0.26 and explode
//   0.38  characters between first and last turn red ... 0.44 and explode
//   0.56  first/last tokens convert to digit glyphs ("eight" -> 8; plain digits stay put)
//   0.66  the two digits slide together into the line's two-digit value
//   0.76  the value flies up into the running total
//   0.86  the total pops: zooms in with overshoot, counts up fast with a digit wave,
//         then springs back (elastic) from 0.93
//   0.90  the queue (dimmed lines below) moves up
// -------------------------------------------------------------------------------------------------

namespace {

constant float kAdvance = 6.0f;                              // glyph width + 1 voxel gap
constant float3 kQueueOffset = float3(0.0f, -11.0f, -5.0f);  // per queued line: below and behind
constant float kTotalY = 22.0f;

// Running-total "pop" timeline (fractions of a line's progress).
constant float kArrive = 0.86f;    // the line value lands; zoom-in and count-up start
constant float kZoomedIn = 0.91f;  // peak reached (with overshoot)
constant float kCounted = 0.93f;   // count-up finished; elastic zoom-out starts
constant float kPopScale = 2.2f;   // peak scale of the total

constant float3 kWhite = float3(0.86f, 0.87f, 0.92f);
constant float3 kBlue = float3(0.30f, 0.52f, 1.00f);
constant float3 kGreen = float3(0.25f, 0.92f, 0.45f);
constant float3 kOrange = float3(1.00f, 0.56f, 0.18f);
constant float3 kRed = float3(0.95f, 0.12f, 0.10f);
constant float3 kGold = float3(1.00f, 0.84f, 0.30f);

struct LineInfo {
    uint start;
    uint length;
    bool hasDigits;
    uint firstPos, firstLen, lastPos, lastLen;  // relative to line start
    int tens, ones;
};

LineInfo lineInfo(uint line, const device uchar* bytes, const device uint* lineStart, const device uint* first,
                  const device uint* last, constant Example01VizParams& p) {
    LineInfo info;
    info.start = lineStart[line];
    const uint end = line + 1 < p.lineCount ? lineStart[line + 1] - 1 : p.byteCount - 1;  // the '\n'
    info.length = end - info.start;
    info.hasDigits = first[line] != kNone;
    info.firstPos = info.firstLen = info.lastPos = info.lastLen = 0;
    info.tens = info.ones = 0;
    if (info.hasDigits) {
        const bool spelled = p.spelledDigits != 0;
        info.tens = digitAt(bytes, first[line], p.byteCount, spelled, info.firstLen);
        info.ones = digitAt(bytes, last[line], p.byteCount, spelled, info.lastLen);
        info.firstPos = first[line] - info.start;
        info.lastPos = last[line] - info.start;
    }
    return info;
}

/// True if character `c` of the line is covered by any digit token (digit or spelled word).
bool inAnyToken(const device uchar* bytes, uint start, uint c, uint count, bool spelled) {
    for (uint back = 0; back <= 4 && back <= c; ++back) {
        uint len;
        if (digitAt(bytes, start + c - back, count, spelled, len) >= 0 && len > back) {
            return true;
        }
    }
    return false;
}

/// Ballistic explosion of one voxel, `dt` in pseudo-seconds since detonation.
void explode(thread float3& pos, thread float& size, thread float3& color, uint seed, float dt) {
    if (dt <= 0.0f) {
        return;
    }
    const uint h1 = aoc::hash(seed);
    const uint h2 = aoc::hash(h1);
    const uint h3 = aoc::hash(h2);
    const float3 r = float3(float(h1 & 0xffffu), float(h2 & 0xffffu), float(h3 & 0xffffu)) / 65535.0f;
    const float3 dir = normalize(float3(r.x - 0.5f, r.y * 0.9f + 0.3f, (r.z - 0.5f) * 1.6f));
    const float speed = 30.0f + 30.0f * r.y;
    pos += dir * speed * dt + float3(0.0f, -45.0f, 0.0f) * dt * dt;
    size *= saturate(1.0f - dt * 1.6f);
    color = mix(color, float3(1.0f, 0.65f, 0.15f), saturate(dt * 3.0f));
}

/// x of the left edge of glyph slot `c` for a line of `length` characters, centred on x = 0.
float glyphX(float c, float length) {
    return (c - length * 0.5f) * kAdvance;
}

}  // namespace

/// One thread per (glyph pixel, glyph slot). Slots: (queuedLines + 1) * maxLineLength line
/// characters, then 2 result digits (tens, ones), then EXAMPLE01_TOTAL_DIGITS total digits.
[[kernel]] void example01_instances(const device uchar* bytes [[buffer(0)]], const device uint* lineStart [[buffer(1)]],
                                    const device uint* first [[buffer(2)]], const device uint* last [[buffer(3)]],
                                    device AoCInstance* out [[buffer(4)]], constant Example01VizParams& p [[buffer(5)]],
                                    uint2 gid [[thread_position_in_grid]]) {
    const uint pixel = gid.x;
    const uint slot = gid.y;
    const uint col = pixel % 5;
    const uint row = pixel / 5;
    const uint outIndex = slot * EXAMPLE01_GLYPH_PIXELS + pixel;
    const float t = p.progress;
    const bool spelled = p.spelledDigits != 0;

    AoCInstance inst;
    inst.position = float3(0.0f);
    inst.scale = float3(0.0f);
    inst.color = float4(0.0f);

    const LineInfo cur = lineInfo(p.line, bytes, lineStart, first, last, p);
    const uint lineSlots = (p.queuedLines + 1) * p.maxLineLength;
    const float3 pixelOffset = float3(float(col), float(6 - row), 0.0f);

    float3 pos = float3(0.0f);
    float size = 0.0f;
    float3 color = kWhite;

    if (slot < lineSlots) {
        // ---- characters of the current line (k == 0) or of a queued line (k > 0) ----
        const uint k = slot / p.maxLineLength;
        const uint c = slot % p.maxLineLength;
        const uint line = p.line + k;
        if (line >= p.lineCount) {
            out[outIndex] = inst;
            return;
        }
        const LineInfo info = k == 0 ? cur : lineInfo(line, bytes, lineStart, first, last, p);
        if (c >= info.length || !aoc::glyphPixel(bytes[info.start + c], col, row)) {
            out[outIndex] = inst;
            return;
        }

        const float advance = aoc::phase(t, 0.90f, 1.0f);
        pos = float3(glyphX(float(c), float(info.length)), 0.0f, 0.0f) + pixelOffset;
        pos += kQueueOffset * (float(k) - advance);
        size = 1.0f;

        if (k > 0) {
            color = kWhite * mix(0.30f, 0.80f, advance * float(k == 1)) / float(k);
        } else {
            // Drop in, staggered by column.
            pos.y += 18.0f * (1.0f - aoc::phase(t, float(c) * 0.0015f, 0.08f + float(c) * 0.0015f));

            const bool inFirst = info.hasDigits && c >= info.firstPos && c < info.firstPos + info.firstLen;
            const bool inLast = info.hasDigits && c >= info.lastPos && c < info.lastPos + info.lastLen;
            const bool outer = !info.hasDigits || c < info.firstPos || c >= info.lastPos + info.lastLen;
            const bool middle = !inFirst && !inLast && !outer;
            const bool token = inAnyToken(bytes, info.start, c, p.byteCount, spelled);

            const float highlight = aoc::phase(t, 0.10f, 0.18f);
            if (token) {
                color = mix(color, kBlue, highlight);
            }
            if (inFirst || inLast) {
                const float3 target = inFirst && inLast ? kGold : (inFirst ? kGreen : kOrange);
                color = mix(color, target, highlight);
                // Converted into a digit glyph (result slots take over from here).
                size *= 1.0f - aoc::phase(t, 0.56f, 0.64f);
                pos.y += 2.0f * aoc::phase(t, 0.10f, 0.18f);
            } else if (outer || middle) {
                const float redAt = outer ? 0.20f : 0.38f;
                color = mix(color, kRed, aoc::phase(t, redAt, redAt + 0.06f));
                explode(pos, size, color, outIndex, (t - (redAt + 0.06f)) * 3.0f);
            }
        }
    } else if (slot < lineSlots + 2) {
        // ---- the two result digits: appear at their token, slide together, fly into the total ----
        if (!cur.hasDigits || t < 0.56f) {
            out[outIndex] = inst;
            return;
        }
        const bool tens = slot == lineSlots;
        const uint digit = uint(tens ? cur.tens : cur.ones);
        if (!aoc::glyphPixel(uchar('0' + digit), col, row)) {
            out[outIndex] = inst;
            return;
        }
        const float tokenPos = tens ? float(cur.firstPos) + float(cur.firstLen) * 0.5f - 0.5f
                                    : float(cur.lastPos) + float(cur.lastLen) * 0.5f - 0.5f;
        const float3 start = float3(glyphX(tokenPos, float(cur.length)), 2.0f, 0.0f);
        const float3 paired = float3(tens ? -kAdvance : 0.0f, 2.0f, 0.0f);
        const float3 total = float3(0.0f, kTotalY, 0.0f);

        const float slide = aoc::phase(t, 0.66f, 0.76f);
        const float fly = aoc::phase(t, 0.76f, kArrive);
        pos = mix(mix(start, paired, slide), total, fly) + pixelOffset * (1.0f - 0.6f * fly);
        pos.z += 3.0f * sin(slide * M_PI_F);  // arc towards the viewer while sliding
        size = aoc::phase(t, 0.56f, 0.64f) * (1.0f - fly * 0.6f) * (t < kArrive ? 1.0f : 0.0f);
        color = mix(tens ? kGreen : kOrange, kGold, fly);
    } else {
        // ---- running total: pops in, counts up fast, springs back ----
        const uint d = slot - lineSlots - 2;
        const float count = aoc::easeOutCubic(aoc::linear(t, kArrive, kCounted));
        const uint gain = p.totalAfter - p.totalBefore;
        const uint value = p.totalBefore + min(gain, uint(float(gain) * count + 0.5f));
        uint digits = 1;
        for (uint v = value; v >= 10; v /= 10) {
            ++digits;
        }
        if (d >= digits) {
            out[outIndex] = inst;
            return;
        }
        uint divisor = 1;
        for (uint i = d + 1; i < digits; ++i) {
            divisor *= 10;
        }
        const uint digit = (value / divisor) % 10;
        if (!aoc::glyphPixel(uchar('0' + digit), col, row)) {
            out[outIndex] = inst;
            return;
        }
        // Zoom: overshooting grow, then an elastic spring back (dipping slightly below 1 for squash).
        const float grow = aoc::easeOutBack(aoc::linear(t, kArrive, kZoomedIn));
        const float pop = t < kCounted ? grow : aoc::springBack(aoc::linear(t, kCounted, 1.0f));
        const float scale = 1.0f + (kPopScale - 1.0f) * pop;

        // Each digit hops in turn while the number ticks (a wave running left to right).
        const float hopStart = kArrive + 0.008f * float(d);
        const float hop = sin(M_PI_F * aoc::linear(t, hopStart, hopStart + 0.05f));

        // Scale about the centre of the number so it zooms in place.
        const float3 centre = float3(-0.5f, kTotalY + 3.0f, 0.0f);
        pos = float3(glyphX(float(d), float(digits)), kTotalY, 0.0f) + pixelOffset;
        pos = centre + (pos - centre) * scale;
        pos.y += 2.5f * hop * scale;
        pos.z += 6.0f * saturate(pop);  // towards the viewer while popped
        size = scale;

        const float ticking = t >= kArrive && t < kCounted ? 1.0f : 0.0f;
        color = mix(kGold, float3(1.0f, 0.97f, 0.85f), saturate(0.85f * ticking + 0.6f * hop + 0.4f * pop));
    }

    inst.position = pos;
    inst.scale = float3(0.92f, 0.92f, 1.6f) * size;
    inst.color = float4(color, 1.0f);
    out[outIndex] = inst;
}
