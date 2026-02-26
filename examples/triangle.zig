const window_width = 800;
const window_height = 600;

const Ids = struct {
    base: x11.ResourceBase,
    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
};

pub fn main() !void {
    // Create a shared buffer before spawn (Phase 1: import only, no rendering use yet)
    const shared_mem: vow.SharedMem = try .create(4096);

    // initialize vow at beginning to minimize handle leaks
    const vow_sock = try vow.spawn(.{
        .memfds = &.{shared_mem.fd},
        // useful to debug the vowexe
        // .write_exe_path = "/tmp/vowexe",
    });

    var vow_write_buf: [1000]u8 = undefined;
    var vow_sock_writer = vow_sock.writer(&vow_write_buf);
    const vow_writer = &vow_sock_writer.interface;

    try x11.wsaStartup();

    const Screen = struct {
        window: x11.Window,
        visual: x11.Visual,
        depth: x11.Depth,
    };
    const stream: std.net.Stream, const ids: Ids, const screen: Screen = blk: {
        var read_buffer: [1000]u8 = undefined;
        var socket_reader, const used_auth = try x11.draft.connect(&read_buffer);
        errdefer x11.disconnect(socket_reader.getStream());
        _ = used_auth;
        const setup = try x11.readSetupSuccess(socket_reader.interface());
        std.log.info("setup reply {f}", .{setup});
        var source: x11.Source = .initFinishSetup(socket_reader.interface(), &setup);
        const screen = try x11.draft.readSetupDynamic(&source, &setup, .{}) orelse {
            std.log.err("no screen?", .{});
            std.process.exit(0xff);
        };
        break :blk .{
            socket_reader.getStream(), .{ .base = setup.resource_id_base }, .{
                .window = screen.root,
                .visual = screen.root_visual,
                .depth = x11.Depth.init(screen.root_depth) orelse std.debug.panic(
                    "unsupported depth {}",
                    .{screen.root_depth},
                ),
            },
        };
    };
    defer x11.disconnect(stream);

    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var socket_writer = x11.socketWriter(stream, &write_buffer);
    var socket_reader = x11.socketReader(stream, &read_buffer);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .initAfterSetup(socket_reader.interface());

    try sink.CreateWindow(
        .{
            .window_id = ids.window(),
            .parent_window_id = screen.window,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
            .border_width = 0,
            .class = .input_output,
            .visual_id = screen.visual,
        },
        .{},
    );
    vow.writeCreateGc(vow_writer, .{
        .window = @intFromEnum(ids.window()),
        .validation_layers = .default,
    }) catch return vow_sock_writer.err.?;
    vow.writeShader(vow_writer, .vert, shader_triangle_vert) catch return vow_sock_writer.err.?;
    vow.writeShader(vow_writer, .frag, shader_triangle_frag) catch return vow_sock_writer.err.?;
    vow.writeVertices(vow_writer, .{
        .vertex_count = vertices.len,
        .stride = @sizeOf(Vertex),
        .attributes = &.{
            .{ .location = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "pos") },
            .{ .location = 1, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "color") },
        },
        .data = std.mem.asBytes(&vertices),
    }) catch return vow_sock_writer.err.?;
    vow.writePushConstantRanges(vow_writer, &.{.{
        .stage_flags = vow.ShaderStage.vertex,
        .offset = 0,
        .size = @sizeOf(f32),
    }}) catch return vow_sock_writer.err.?;
    vow.writeClearColor(vow_writer, .{ 0, 0, 0, 1 }) catch return vow_sock_writer.err.?;
    vow.writePlaceholder(vow_writer, .{ .map_on_present = 1 }) catch return vow_sock_writer.err.?;
    vow_writer.flush() catch return vow_sock_writer.err.?;

    try sink.writer.flush();

    const start_time = std.time.nanoTimestamp();
    const frame_ns: u64 = std.time.ns_per_s / 60;
    var next_frame_time: u64 = @intCast(start_time);

    while (true) {
        const now: u64 = @intCast(std.time.nanoTimestamp());
        const wait_ms: i32 = if (now < next_frame_time)
            @intCast((next_frame_time - now) / std.time.ns_per_ms)
        else
            0;
        var pollfds = [_]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = std.posix.poll(&pollfds, wait_ms) catch {};

        if (pollfds[0].revents & std.posix.POLL.IN != 0) {
            const msg_kind = source.readKind() catch |err| return switch (err) {
                error.EndOfStream => {
                    std.log.info("X11 connection closed (EndOfStream)", .{});
                    std.process.exit(0);
                },
                else => |e| switch (socket_reader.getError() orelse e) {
                    error.ConnectionResetByPeer => {
                        std.log.info("X11 connection closed (ConnectionReset)", .{});
                        return std.process.exit(0);
                    },
                    else => |e2| e2,
                },
            };
            switch (msg_kind) {
                else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
            }
        }

        // Send draw frame at 60fps
        const frame_now: u64 = @intCast(std.time.nanoTimestamp());
        if (frame_now >= next_frame_time) {
            next_frame_time +|= frame_ns;
            if (next_frame_time < frame_now) {
                next_frame_time = frame_now + frame_ns;
            }

            const elapsed_ns = std.time.nanoTimestamp() - start_time;
            const angle: f32 = @floatCast(@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
            vow.writeUpdate(vow_writer, std.mem.asBytes(&angle)) catch return vow_sock_writer.err.?;
            vow_writer.flush() catch return vow_sock_writer.err.?;
        }
    }
}

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

const std = @import("std");
const x11 = @import("x11");
const vow = @import("vow");
const Vertex = struct {
    pos: [2]f32,
    color: [3]f32,
};

const vertices = [_]Vertex{
    .{ .pos = .{ 0, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
};

const shader_triangle_vert = @embedFile("shaders.triangle.vert");
const shader_triangle_frag = @embedFile("shaders.triangle.frag");
