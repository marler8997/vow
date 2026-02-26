#version 450

layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec3 a_color;

layout(location = 0) out vec3 v_color;

layout(push_constant) uniform PushConstants {
    float angle;
} pc;

void main() {
    float c = cos(pc.angle);
    float s = sin(pc.angle);
    vec2 rotated = vec2(
        a_pos.x * c - a_pos.y * s,
        a_pos.x * s + a_pos.y * c
    );
    gl_Position = vec4(rotated, 0.0, 1.0);
    v_color = a_color;
}
