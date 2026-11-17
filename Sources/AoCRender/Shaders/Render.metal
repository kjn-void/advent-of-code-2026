// Instanced box renderer. The cube is generated from vertex_id, so the only buffers are the
// instance array (written by scenes / their compute kernels) and the frame uniforms.
#include <metal_stdlib>

#include "AoCShared.h"

using namespace metal;

struct BoxVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 normal;
    float3 local;  // [-0.5, 0.5]^3 position within the box, for edge shading
    float4 color;
};

// 6 faces x 2 triangles x 3 vertices, counter-clockwise when viewed from outside.
constant float3 kFaceNormals[6] = {float3(1, 0, 0),  float3(-1, 0, 0), float3(0, 1, 0),
                                   float3(0, -1, 0), float3(0, 0, 1),  float3(0, 0, -1)};
// Linear RGB; must match Renderer.clearColor.
constant float3 kBackground = float3(0.010f, 0.012f, 0.018f);

constant float2 kQuad[6] = {float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1)};

static float3 cubeCorner(uint vid, thread float3& normal) {
    const uint face = vid / 6;
    const float2 q = kQuad[vid % 6] * 0.5f;
    normal = kFaceNormals[face];
    // Tangent frame per face so the winding stays consistent.
    const float3 n = normal;
    const float3 t = abs(n.y) > 0.5f ? float3(1, 0, 0) : float3(0, 1, 0);
    const float3 u = cross(t, n);
    const float3 v = cross(n, u);
    return n * 0.5f + u * q.x + v * q.y;
}

[[vertex]] BoxVertexOut box_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device AoCInstance* instances [[buffer(0)]],
                                   constant AoCFrameUniforms& frame [[buffer(1)]]) {
    const AoCInstance inst = instances[iid];
    float3 normal;
    const float3 local = cubeCorner(vid, normal);
    const float3 world = inst.position + local * inst.scale;

    BoxVertexOut out;
    out.position = frame.viewProjection * float4(world, 1.0f);
    out.worldPosition = world;
    out.normal = normal;
    out.local = local;
    out.color = inst.color;
    return out;
}

[[fragment]] float4 box_fragment(BoxVertexOut in [[stage_in]], constant AoCFrameUniforms& frame [[buffer(1)]]) {
    const float3 n = normalize(in.normal);
    const float3 l = frame.lightDirection;

    // Hemisphere ambient + wrapped diffuse keeps unlit faces readable.
    const float hemi = mix(0.35f, 0.65f, n.y * 0.5f + 0.5f);
    const float diffuse = saturate(dot(n, l) * 0.6f + 0.4f);
    float3 color = in.color.rgb * (hemi * 0.55f + diffuse * 0.65f);

    // Darken box edges slightly so adjacent voxels read as separate cells.
    const float3 edge = abs(in.local) * 2.0f;
    const float3 sorted = float3(min(min(edge.x, edge.y), edge.z), 0, max(max(edge.x, edge.y), edge.z));
    const float middle = edge.x + edge.y + edge.z - sorted.x - sorted.z;
    color *= mix(1.0f, 0.72f, smoothstep(0.86f, 0.98f, middle));

    // Exponential distance fog towards the background colour.
    const float dist = length(in.worldPosition - frame.cameraPosition);
    const float fog = 1.0f - exp(-dist * frame.fogDensity);
    color = mix(color, kBackground, saturate(fog));

    return float4(color, in.color.a);
}
