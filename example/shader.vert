#version 450
#extension GL_EXT_buffer_reference : require

layout(buffer_reference, std430) readonly buffer RootData {
    float angle;
    // vertices: 3 * {pos: vec2, color: vec3} = 3 * 5 floats
    float vertex_data[];
};

layout(push_constant) uniform PushConstants {
    RootData vertex_data;
    uint pixel_data_lo;
    uint pixel_data_hi;
} pc;

layout(location = 0) out vec3 v_color;

void main() {
    float angle = pc.vertex_data.angle;

    // Each vertex has 5 floats: pos.x, pos.y, color.r, color.g, color.b
    int base = gl_VertexIndex * 5;
    vec2 a_pos = vec2(pc.vertex_data.vertex_data[base + 0], pc.vertex_data.vertex_data[base + 1]);
    vec3 a_color = vec3(pc.vertex_data.vertex_data[base + 2], pc.vertex_data.vertex_data[base + 3], pc.vertex_data.vertex_data[base + 4]);

    float c = cos(angle);
    float s = sin(angle);
    vec2 rotated = vec2(
        a_pos.x * c - a_pos.y * s,
        a_pos.x * s + a_pos.y * c
    );
    gl_Position = vec4(rotated, 0.0, 1.0);
    v_color = a_color;
}
