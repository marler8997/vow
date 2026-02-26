const window_width = 800;
const window_height = 600;

// Layout must match the shader's RootData buffer reference
const RootData = extern struct {
    angle: f32,
    vertices: [6]Vertex,
};

const Vertex = extern struct {
    pos: [2]f32,
    color: [3]f32,
};

const initial_vertices = [3]Vertex{
    .{ .pos = .{ 0, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
};

const quad_vertices = [6]Vertex{
    .{ .pos = .{ -0.5, -0.5 }, .color = .{ 1, 1, 0 } },
    .{ .pos = .{ 0.5, -0.5 }, .color = .{ 0, 1, 1 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 1, 0, 1 } },
    .{ .pos = .{ -0.5, -0.5 }, .color = .{ 1, 1, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 1, 0, 1 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
};

pub fn main() !void {
    const shared_mem: vow.SharedMem = try .create(4096);

    // Write initial data into shared memory
    const root: *RootData = @ptrCast(@alignCast(shared_mem.slice.ptr));
    root.* = .{
        .angle = 0,
        .vertices = initial_vertices ++ [1]Vertex{.{ .pos = .{ 0, 0 }, .color = .{ 0, 0, 0 } }} ** 3,
    };

    // initialize vow at beginning to minimize handle leaks
    const vow_sock = try vow.spawn(.{
        .memfds = &.{shared_mem.fd},
        // useful to debug the vowexe
        // .write_exe_path = "/tmp/vowexe",
    });

    var vow_write_buf: [1000]u8 = undefined;
    var vow_sock_writer = vow_sock.writer(&vow_write_buf);
    const vow_writer = &vow_sock_writer.interface;

    const stream: std.net.Stream, const conn: Connection = try connect();
    defer conn.disconnect(stream);

    switch (conn) {
        .wl => |*wlc| return mainWayland(root, vow_sock, vow_writer, &vow_sock_writer, stream, wlc),
        .x11 => |*xc| return mainX11(root, vow_writer, &vow_sock_writer, stream, xc),
    }
}

fn mainX11(
    root: *RootData,
    vow_writer: *std.Io.Writer,
    vow_sock_writer: anytype,
    stream: std.net.Stream,
    xc: *const Connection.X11State,
) !void {
    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var socket_writer = x11.socketWriter(stream, &write_buffer);
    var socket_reader = x11.socketReader(stream, &read_buffer);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .initAfterSetup(socket_reader.interface());

    const Key = enum { left, right, up, down };
    var keycode_map = std.AutoHashMapUnmanaged(u8, Key){};

    {
        var it = try x11.synchronousGetKeyboardMapping(&sink, &source, xc.keyrange);
        for (xc.keyrange.min..@as(usize, xc.keyrange.max) + 1) |keycode| {
            for (try it.readSyms(&source)) |sym| switch (sym) {
                .kbd_left => try keycode_map.put(std.heap.page_allocator, @intCast(keycode), .left),
                .kbd_right => try keycode_map.put(std.heap.page_allocator, @intCast(keycode), .right),
                .kbd_up => try keycode_map.put(std.heap.page_allocator, @intCast(keycode), .up),
                .kbd_down => try keycode_map.put(std.heap.page_allocator, @intCast(keycode), .down),
                else => {},
            };
        }
    }

    try sink.CreateWindow(
        .{
            .window_id = xc.ids.window(),
            .parent_window_id = xc.root.window,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
            .border_width = 0,
            .class = .input_output,
            .visual_id = xc.root.visual,
        },
        .{ .event_mask = .{ .KeyPress = 1 } },
    );
    const window: u32 = @intFromEnum(xc.ids.window());

    // Flush X11 CreateWindow before sending vow commands (vowexe needs the window to exist)
    try sink.writer.flush();

    vow.writeCreateGc(vow_writer, .{
        .window = window,
        .validation_layers = .default,
    }) catch return vow_sock_writer.err.?;
    vow.writeShader(vow_writer, .vert, shader_triangle_vert) catch return vow_sock_writer.err.?;
    vow.writeShader(vow_writer, .frag, shader_triangle_frag) catch return vow_sock_writer.err.?;
    // Pipeline 0: default (triangle_list, fill, back-cull)
    vow.writeRasterDesc(vow_writer, .{}) catch return vow_sock_writer.err.?;
    // Pipeline 1: wireframe
    vow.writeRasterDesc(vow_writer, .{ .polygon_mode = .line, .cull_mode = .none }) catch return vow_sock_writer.err.?;
    // Pipeline 2: points
    vow.writeRasterDesc(vow_writer, .{ .polygon_mode = .point, .cull_mode = .none }) catch return vow_sock_writer.err.?;
    // Pipeline 3: line_strip topology
    vow.writeRasterDesc(vow_writer, .{ .topology = .line_strip, .cull_mode = .none }) catch return vow_sock_writer.err.?;
    vow.writeBegin(vow_writer, .{ .map_on_present = 1 }) catch return vow_sock_writer.err.?;
    vow.writeGpuMalloc(vow_writer, 0) catch return vow_sock_writer.err.?;
    vow_writer.flush() catch return vow_sock_writer.err.?;

    var current_scene: u8 = 0;
    const num_scenes = 2;
    var current_pipeline: u8 = 0;
    const num_pipelines = 4;
    const pipeline_names = [_][]const u8{ "fill", "wireframe", "points", "line_strip" };

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
                .KeyPress => {
                    const event = try source.read2(.KeyPress);
                    if (keycode_map.get(event.keycode)) |key| {
                        switch (key) {
                            .left => current_scene = @intCast(@mod(@as(isize, @intCast(current_scene)) - 1, num_scenes)),
                            .right => current_scene = @intCast(@mod(@as(isize, @intCast(current_scene)) + 1, num_scenes)),
                            .up => current_pipeline = @intCast(@mod(@as(isize, @intCast(current_pipeline)) - 1, num_pipelines)),
                            .down => current_pipeline = @intCast(@mod(@as(isize, @intCast(current_pipeline)) + 1, num_pipelines)),
                        }
                        std.log.info("scene={} pipeline={s}", .{ current_scene, pipeline_names[current_pipeline] });
                    }
                },
                .KeyRelease => try source.discardRemaining(),
                .MappingNotify => try source.discardRemaining(),
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
            root.angle = @floatCast(@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

            const vertex_count: u32 = switch (current_scene) {
                0 => blk: {
                    root.vertices[0..3].* = initial_vertices;
                    break :blk 3;
                },
                1 => blk: {
                    root.vertices[0..6].* = quad_vertices;
                    break :blk 6;
                },
                else => unreachable,
            };

            vow.writeGpuUpload(vow_writer, 0) catch return vow_sock_writer.err.?;
            vow.writeBeginRenderPass(vow_writer, .{ 0, 0, 0, 1 }) catch return vow_sock_writer.err.?;
            vow.writeBindPipeline(vow_writer, current_pipeline) catch return vow_sock_writer.err.?;
            vow.writeDraw(vow_writer, .{
                .vertex_count = vertex_count,
                .memfd_id = 0,
                .vertex_offset = 0,
                .pixel_offset = 0,
            }) catch return vow_sock_writer.err.?;
            vow.writeEndRenderPass(vow_writer) catch return vow_sock_writer.err.?;
            vow.writePresent(vow_writer) catch return vow_sock_writer.err.?;
            vow_writer.flush() catch return vow_sock_writer.err.?;
        }
    }
}

fn mainWayland(
    root: *RootData,
    vow_sock: std.fs.File,
    vow_writer: *std.Io.Writer,
    vow_sock_writer: anytype,
    stream: std.net.Stream,
    wlc: *const Connection.WlState,
) !void {
    var ids = wlc.ids;

    var write_buf: [4096]u8 = undefined;
    var stream_writer = stream.writer(&write_buf);
    const writer = &stream_writer.interface;

    var read_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(&read_buf);
    const reader = stream_reader.interface();

    // Send create_device instead of create_gc
    vow.writeCreateDevice(vow_writer, .default) catch return vow_sock_writer.err.?;
    vow.writeShader(vow_writer, .vert, shader_triangle_vert) catch return vow_sock_writer.err.?;
    vow.writeShader(vow_writer, .frag, shader_triangle_frag) catch return vow_sock_writer.err.?;
    // Pipeline 0: default
    vow.writeRasterDesc(vow_writer, .{}) catch return vow_sock_writer.err.?;
    // Pipeline 1: wireframe
    vow.writeRasterDesc(vow_writer, .{ .polygon_mode = .line, .cull_mode = .none }) catch return vow_sock_writer.err.?;
    // Pipeline 2: points
    vow.writeRasterDesc(vow_writer, .{ .polygon_mode = .point, .cull_mode = .none }) catch return vow_sock_writer.err.?;
    // Pipeline 3: line_strip
    vow.writeRasterDesc(vow_writer, .{ .topology = .line_strip, .cull_mode = .none }) catch return vow_sock_writer.err.?;

    // Create 2 render targets (double buffer)
    const buffer_count: u8 = 2;
    vow.writeCreateRenderTargets(vow_writer, .{
        .width = window_width,
        .height = window_height,
        .count = buffer_count,
    }) catch return vow_sock_writer.err.?;

    vow.writeBegin(vow_writer, .{ .map_on_present = 0 }) catch return vow_sock_writer.err.?;
    vow.writeGpuMalloc(vow_writer, 0) catch return vow_sock_writer.err.?;
    vow_writer.flush() catch return vow_sock_writer.err.?;

    // Read render target fd responses from vow socket
    var rt_fds: [2]std.posix.fd_t = undefined;
    var rt_infos: [2]vow.RenderTargetInfo = undefined;
    for (0..buffer_count) |i| {
        const response = vow.readRenderTargetResponse(vow_sock.handle) catch |e| {
            std.log.err("failed to read render target response {}: {s}", .{ i, @errorName(e) });
            return e;
        };
        rt_fds[i] = response.fd;
        rt_infos[i] = response.info;
        std.log.info("received render target {} fd={} transport={s} stride={} size={}", .{
            i, response.fd, @tagName(response.info.transport), response.info.stride, response.info.size,
        });
    }

    // Create wl_buffer objects based on transport type
    const buffer_ids = [2]wl.Id{ .dmabuf_buffer_0, .dmabuf_buffer_1 };
    const pool_ids = [2]wl.Id{ .linux_dmabuf_params_0, .linux_dmabuf_params_1 };

    const use_dmabuf = rt_infos[0].transport == .dmabuf;

    if (use_dmabuf) {
        // Bind zwp_linux_dmabuf_v1
        const dmabuf_name = wlc.linux_dmabuf_name orelse {
            std.log.err("render targets use DMA-BUF but compositor has no zwp_linux_dmabuf_v1", .{});
            return error.WaylandProtocol;
        };
        try wl.registry.bind(
            writer,
            ids.get(.registry),
            dmabuf_name,
            "zwp_linux_dmabuf_v1",
            @min(wl.linux_dmabuf.version, wlc.linux_dmabuf_version),
            ids.new(.linux_dmabuf),
        );
        try writer.flush();

        for (0..buffer_count) |i| {
            // Create params object
            try wl.linux_dmabuf.create_params(writer, ids.get(.linux_dmabuf), ids.new(pool_ids[i]));
            // Flush before sendmsg (add uses sendmsg with SCM_RIGHTS)
            try writer.flush();

            const modifier = rt_infos[i].modifier;
            try wl.linux_dmabuf_params.add(
                stream,
                ids.get(pool_ids[i]),
                rt_fds[i],
                0, // plane_idx
                rt_infos[i].offset,
                rt_infos[i].stride,
                @truncate(modifier >> 32), // modifier_hi
                @truncate(modifier), // modifier_lo
            );
            try wl.linux_dmabuf_params.create_immed(
                writer,
                ids.get(pool_ids[i]),
                ids.new(buffer_ids[i]),
                @intCast(window_width),
                @intCast(window_height),
                rt_infos[i].format, // DRM fourcc
                0, // flags
            );
            try wl.linux_dmabuf_params.destroy(writer, ids.get(pool_ids[i]));
        }
    } else {
        // SHM path: create wl_buffer objects from memfds via wl_shm
        for (0..buffer_count) |i| {
            // Flush before sendmsg (create_pool uses sendmsg with SCM_RIGHTS)
            try writer.flush();
            try wl.shm.create_pool(
                stream,
                ids.get(.shm),
                ids.new(pool_ids[i]),
                rt_fds[i],
                @intCast(rt_infos[i].size),
            );
            try wl.shm_pool.create_buffer(
                writer,
                ids.get(pool_ids[i]),
                ids.new(buffer_ids[i]),
                0, // offset
                @intCast(window_width),
                @intCast(window_height),
                @intCast(rt_infos[i].stride),
                .argb8888,
            );
            // Destroy the pool immediately — the buffer keeps a reference
            try wl.shm_pool.destroy(writer, ids.get(pool_ids[i]));
        }
    }

    try writer.flush();

    // Buffer tracking: both initially free
    var buffer_free = [2]bool{ true, true };

    const current_scene: u8 = 0;
    _ = current_scene;
    const current_pipeline: u8 = 0;
    _ = current_pipeline;

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

        // Process any incoming Wayland events
        if (pollfds[0].revents & std.posix.POLL.IN != 0) {
            while (true) {
                // Non-blocking check for more events
                var peek_pollfds = [_]std.posix.pollfd{.{
                    .fd = stream.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};

                const sender, const opcode, const size = wl.readHeader(reader) catch |err| switch (err) {
                    error.EndOfStream => {
                        std.log.info("Wayland connection closed", .{});
                        return;
                    },
                    else => |e| return e,
                };
                var buffer_released = [2]bool{ false, false };
                wl.handleEvent(&ids, writer, reader, ids.lookup(sender), opcode, size, null, &buffer_released) catch |err| switch (err) {
                    error.WaylandProtocol => return,
                    else => |e| return e,
                };
                // Update buffer_free from release events
                for (0..buffer_count) |bi| {
                    if (buffer_released[bi]) buffer_free[bi] = true;
                }

                _ = std.posix.poll(&peek_pollfds, 0) catch {};
                if (peek_pollfds[0].revents & std.posix.POLL.IN == 0) break;
            }
        }

        // Render a frame at 60fps
        const frame_now: u64 = @intCast(std.time.nanoTimestamp());
        if (frame_now >= next_frame_time) {
            next_frame_time +|= frame_ns;
            if (next_frame_time < frame_now) {
                next_frame_time = frame_now + frame_ns;
            }

            // Find a free buffer
            const buf_idx: u8 = if (buffer_free[0]) 0 else if (buffer_free[1]) 1 else continue;

            const elapsed_ns = std.time.nanoTimestamp() - start_time;
            root.angle = @floatCast(@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
            root.vertices[0..3].* = initial_vertices;

            vow.writeGpuUpload(vow_writer, 0) catch return vow_sock_writer.err.?;
            vow.writeBeginRenderPassDmabuf(vow_writer, buf_idx, .{ 0, 0, 0, 1 }) catch return vow_sock_writer.err.?;
            vow.writeBindPipeline(vow_writer, 0) catch return vow_sock_writer.err.?;
            vow.writeDraw(vow_writer, .{
                .vertex_count = 3,
                .memfd_id = 0,
                .vertex_offset = 0,
                .pixel_offset = 0,
            }) catch return vow_sock_writer.err.?;
            vow.writeEndRenderPass(vow_writer) catch return vow_sock_writer.err.?;
            vow.writeSubmit(vow_writer, buf_idx) catch return vow_sock_writer.err.?;
            vow_writer.flush() catch return vow_sock_writer.err.?;

            // Attach buffer to surface and commit
            buffer_free[buf_idx] = false;
            wl.surface.attach(writer, ids.get(.surface), ids.get(buffer_ids[buf_idx]), 0, 0) catch |e| {
                std.log.err("attach failed: {s}", .{@errorName(e)});
                return e;
            };
            wl.surface.damage(writer, ids.get(.surface), 0, 0, window_width, window_height) catch |e| {
                std.log.err("damage failed: {s}", .{@errorName(e)});
                return e;
            };
            wl.surface.commit(writer, ids.get(.surface)) catch |e| {
                std.log.err("commit failed: {s}", .{@errorName(e)});
                return e;
            };
            writer.flush() catch |e| {
                std.log.err("flush failed: {s}", .{@errorName(e)});
                return e;
            };
        }
    }
}

const Connection = union(enum) {
    wl: WlState,
    x11: X11State,

    pub const WlState = struct {
        ids: wl.IdTable(wl.Id),
        linux_dmabuf_name: ?u32,
        linux_dmabuf_version: u32,
    };
    pub const X11State = struct {
        ids: x11.Ids,
        keyrange: x11.KeycodeRange,
        root: x11.Root,
    };

    pub fn disconnect(conn: *const Connection, stream: std.net.Stream) void {
        switch (conn.*) {
            .wl => wl.disconnect(stream),
            .x11 => x11.disconnect(stream),
        }
    }
};
const StreamConnection = struct { std.net.Stream, Connection };
fn connect() !StreamConnection {
    const compositor, const compositor_reason = determineCompositor();
    std.log.info("compositor {t} ({t})", .{ compositor, compositor_reason });

    if (@as(?enum { or_fail, then_x11 }, switch (compositor) {
        .wayland_or_fail => .or_fail,
        .wayland_then_x11 => .then_x11,
        .x11_or_fail => null,
    })) |then| {
        if (connectWayland()) |result| return result else |err| switch (then) {
            .or_fail => return err,
            .then_x11 => {
                std.log.info("connect to wayland failed ({t}), trying x11...", .{err});
            },
        }
    }

    // try x11.wsaStartup();
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
    return .{
        socket_reader.getStream(),
        .{ .x11 = .{
            .ids = .{ .base = setup.resource_id_base },
            .keyrange = try .init(setup.min_keycode, setup.max_keycode),
            .root = .{
                .window = screen.root,
                .visual = screen.root_visual,
                .depth = x11.Depth.init(screen.root_depth) orelse std.debug.panic(
                    "unsupported depth {}",
                    .{screen.root_depth},
                ),
            },
        } },
    };
}

fn connectWayland() !StreamConnection {
    const stream = blk: {
        var err: wl.SockaddrError = undefined;
        const addr = wl.getSockaddr(&err) catch {
            std.log.err("{f}", .{err});
            std.process.exit(0xff);
        };
        std.log.info("connecting to '{f}'", .{addr});
        break :blk wl.connect(&addr) catch |e| {
            std.log.err("connect to {f} failed with {s}", .{ addr, @errorName(e) });
            std.process.exit(0xff);
        };
    };
    errdefer wl.disconnect(stream);

    var write_buf: [4096]u8 = undefined;
    var stream_writer = stream.writer(&write_buf);
    const writer = &stream_writer.interface;

    var read_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(&read_buf);
    const reader = stream_reader.interface();

    return connectWayland2(stream, writer, reader) catch |err| switch (err) {
        error.WriteFailed => stream_writer.err orelse error.Unexpected,
        error.ReadFailed => stream_reader.getError() orelse error.Unexpected,
        error.EndOfStream, error.WaylandProtocol => |e| e,
    };
}
fn connectWayland2(
    stream: std.net.Stream,
    writer: *wl.Writer,
    reader: *wl.Reader,
) error{ WriteFailed, ReadFailed, EndOfStream, WaylandProtocol }!StreamConnection {
    var ids: wl.IdTable(wl.Id) = .{};

    try wl.display.get_registry(writer, ids.new(.registry));
    try wl.display.sync(writer, ids.new(.callback));
    try writer.flush();

    const Object = struct { name: u32, version: u32 };
    var maybe_shm: ?Object = null;
    var maybe_compositor: ?Object = null;
    var maybe_xdg_wm_base: ?Object = null;
    var maybe_linux_dmabuf: ?Object = null;
    var maybe_xdg_decoration_manager: ?Object = null;
    while (true) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        switch (ids.lookup(sender)) {
            .registry => switch (opcode) {
                wl.registry.event.global => {
                    const name = try reader.takeInt(u32, wl.native_endian);
                    const interface_size = try reader.takeInt(u32, wl.native_endian);
                    const interface_word_count = @divTrunc(interface_size + 3, 4);
                    if (8 + 12 + interface_word_count * 4 != size) return error.WaylandProtocol;
                    var interface_buf: [400]u8 = undefined;
                    const interface = interface_buf[0..@min(interface_buf.len, interface_size -| 1)];
                    try reader.readSliceAll(interface);
                    try reader.discardAll(interface_word_count * 4 - interface.len);
                    const version = try reader.takeInt(u32, wl.native_endian);
                    std.log.info("registry event global name={} interface='{s}' version={}", .{ name, interface, version });
                    if (std.mem.eql(u8, interface, "wl_shm")) {
                        if (maybe_shm != null) {
                            std.log.err("got wl_shm multiple times", .{});
                            return error.WaylandProtocol;
                        }
                        maybe_shm = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, "wl_compositor")) {
                        if (maybe_compositor != null) {
                            std.log.err("got wl_compositor multiple times", .{});
                            return error.WaylandProtocol;
                        }
                        maybe_compositor = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, "xdg_wm_base")) {
                        if (maybe_xdg_wm_base != null) {
                            std.log.err("got xdg_wm_base multiple times", .{});
                            return error.WaylandProtocol;
                        }
                        maybe_xdg_wm_base = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, "zwp_linux_dmabuf_v1")) {
                        if (maybe_linux_dmabuf != null) {
                            std.log.err("got zwp_linux_dmabuf_v1 multiple times", .{});
                            return error.WaylandProtocol;
                        }
                        maybe_linux_dmabuf = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, "zxdg_decoration_manager_v1")) {
                        if (maybe_xdg_decoration_manager != null) {
                            std.log.err("got zxdg_decoration_manager_v1 multiple times", .{});
                            return error.WaylandProtocol;
                        }
                        maybe_xdg_decoration_manager = .{ .name = name, .version = version };
                    }
                },
                else => @panic("unhandled registry event"),
            },
            .callback => switch (opcode) {
                wl.callback.event.done => {
                    if (size != 12) {
                        std.log.err("expected wl_callback.done event to be 12 bytes but got {}", .{size});
                        return error.WaylandProtocol;
                    }
                    const data: u32 = try reader.takeInt(u32, wl.native_endian);
                    std.log.info("done data={}", .{data});
                    break;
                },
                else => @panic("unhandled opcode"),
            },
            else => |sender_id| std.debug.panic("unhandled event from {t}", .{sender_id}),
        }
    }

    const compositor_global = maybe_compositor orelse {
        std.log.err("no wl_compositor object", .{});
        std.process.exit(0xff);
    };
    try wl.registry.bind(
        writer,
        ids.get(.registry),
        compositor_global.name,
        "wl_compositor",
        @min(wl.compositor.version, compositor_global.version),
        ids.new(.compositor),
    );

    const shm_global = maybe_shm orelse {
        std.log.err("no wl_shm object", .{});
        std.process.exit(0xff);
    };
    try wl.registry.bind(
        writer,
        ids.get(.registry),
        shm_global.name,
        "wl_shm",
        @min(wl.shm.version, shm_global.version),
        ids.new(.shm),
    );

    const xdg_wm_base_global = maybe_xdg_wm_base orelse {
        std.log.err("no xdg_wm_base object", .{});
        std.process.exit(0xff);
    };
    try wl.registry.bind(
        writer,
        ids.get(.registry),
        xdg_wm_base_global.name,
        "xdg_wm_base",
        @min(wl.xdg_wm_base.version, xdg_wm_base_global.version),
        ids.new(.xdg_wm_base),
    );

    try wl.compositor.create_surface(writer, ids.get(.compositor), ids.new(.surface));
    try wl.xdg_wm_base.get_xdg_surface(writer, ids.get(.xdg_wm_base), ids.new(.xdg_surface), ids.get(.surface));
    try wl.xdg_surface.get_toplevel(writer, ids.get(.xdg_surface), ids.new(.xdg_toplevel));
    try wl.xdg_toplevel.set_title(writer, ids.get(.xdg_toplevel), "vow triangle");

    // Request server-side decorations if available
    if (maybe_xdg_decoration_manager) |deco_global| {
        try wl.registry.bind(
            writer,
            ids.get(.registry),
            deco_global.name,
            "zxdg_decoration_manager_v1",
            @min(wl.xdg_decoration_manager.version, deco_global.version),
            ids.new(.xdg_decoration_manager),
        );
        try wl.xdg_decoration_manager.get_toplevel_decoration(
            writer,
            ids.get(.xdg_decoration_manager),
            ids.new(.xdg_toplevel_decoration),
            ids.get(.xdg_toplevel),
        );
        try wl.xdg_toplevel_decoration.set_mode(writer, ids.get(.xdg_toplevel_decoration), .server_side);
    }

    // Initial empty commit to get the configure event
    try wl.surface.commit(writer, ids.get(.surface));
    try writer.flush();

    // Wait for the initial xdg configure sequence
    var configured = false;
    while (!configured) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        try wl.handleEvent(&ids, writer, reader, ids.lookup(sender), opcode, size, &configured, null);
    }
    try writer.flush();

    return .{
        stream,
        .{ .wl = .{
            .ids = ids,
            .linux_dmabuf_name = if (maybe_linux_dmabuf) |d| d.name else null,
            .linux_dmabuf_version = if (maybe_linux_dmabuf) |d| d.version else 0,
        } },
    };
}

const Compositor = enum {
    wayland_or_fail,
    x11_or_fail,
    wayland_then_x11,

    pub const Reason = enum {
        xdg_session_type,
        no_xdg_session_type,
    };
};
fn determineCompositor() struct { Compositor, Compositor.Reason } {
    if (std.posix.getenv("XDG_SESSION_TYPE")) |session_type| {
        if (std.mem.eql(u8, session_type, "x11")) return .{ .x11_or_fail, .xdg_session_type };
        if (std.mem.eql(u8, session_type, "wayland")) return .{ .wayland_or_fail, .xdg_session_type };
    }
    return .{ .wayland_then_x11, .no_xdg_session_type };
}

const std = @import("std");
const x11 = @import("x11.zig");
const wl = @import("wl.zig");
const vow = @import("vow");

const shader_triangle_vert = @embedFile("shaders.triangle.vert");
const shader_triangle_frag = @embedFile("shaders.triangle.frag");
