pub const IdTable = wl.IdTable;
pub const SockaddrError = wl.SockaddrError;
pub const Reader = wl.Reader;
pub const Writer = wl.Writer;

pub const callback = wl.callback;
pub const compositor = wl.compositor;
pub const connect = wl.connect;
pub const disconnect = wl.disconnect;
pub const display = wl.display;
pub const getSockaddr = wl.getSockaddr;
pub const linux_dmabuf = wl.linux_dmabuf;
pub const linux_dmabuf_params = wl.linux_dmabuf_params;
pub const native_endian = wl.native_endian;
pub const readHeader = wl.readHeader;
pub const registry = wl.registry;
pub const shm = wl.shm;
pub const shm_pool = wl.shm_pool;
pub const surface = wl.surface;
pub const wl_buffer = wl.wl_buffer;
pub const xdg_decoration_manager = wl.xdg_decoration_manager;
pub const xdg_surface = wl.xdg_surface;
pub const xdg_toplevel = wl.xdg_toplevel;
pub const xdg_toplevel_decoration = wl.xdg_toplevel_decoration;
pub const xdg_wm_base = wl.xdg_wm_base;

pub const Id = enum {
    display,
    registry,
    callback,
    compositor,
    shm,
    xdg_wm_base,
    surface,
    xdg_surface,
    xdg_toplevel,
    shm_pool,
    buffer,
    xdg_decoration_manager,
    xdg_toplevel_decoration,
    linux_dmabuf,
    linux_dmabuf_params_0,
    linux_dmabuf_params_1,
    dmabuf_buffer_0,
    dmabuf_buffer_1,
};

pub fn handleEvent(
    ids: *const wl.IdTable(Id),
    writer: *wl.Writer,
    reader: *wl.Reader,
    sender: Id,
    opcode: u16,
    size: u16,
    configured: ?*bool,
    buffer_released: ?*[2]bool,
) error{ WriteFailed, ReadFailed, EndOfStream, WaylandProtocol }!void {
    switch (sender) {
        .display => switch (opcode) {
            wl.display.event.@"error" => {
                const object_id = try reader.takeInt(u32, wl.native_endian);
                const code = try reader.takeInt(u32, wl.native_endian);
                const msg_size = try reader.takeInt(u32, wl.native_endian);
                const msg_word_count = @divTrunc(msg_size + 3, 4);
                var msg_buf: [400]u8 = undefined;
                const msg = msg_buf[0..@min(msg_buf.len, msg_size -| 1)];
                try reader.readSliceAll(msg);
                try reader.discardAll(msg_word_count * 4 - msg.len);
                std.log.err("display error: object={} code={} message='{s}'", .{ object_id, code, msg });
                return error.WaylandProtocol;
            },
            wl.display.event.delete_id => {
                const deleted_id = try reader.takeInt(u32, wl.native_endian);
                std.log.info("delete_id {}", .{deleted_id});
            },
            else => std.debug.panic("unhandled display event opcode={}", .{opcode}),
        },
        .shm => switch (opcode) {
            wl.shm.event.format => {
                const format = try reader.takeInt(u32, wl.native_endian);
                std.log.info("shm format {}", .{format});
            },
            else => std.debug.panic("unhandled shm event opcode={}", .{opcode}),
        },
        .xdg_wm_base => switch (opcode) {
            wl.xdg_wm_base.event.ping => {
                const serial = try reader.takeInt(u32, wl.native_endian);
                std.log.info("ping serial={}", .{serial});
                try wl.xdg_wm_base.pong(writer, ids.get(.xdg_wm_base), serial);
            },
            else => std.debug.panic("unhandled xdg_wm_base event opcode={}", .{opcode}),
        },
        .xdg_surface => switch (opcode) {
            wl.xdg_surface.event.configure => {
                const serial = try reader.takeInt(u32, wl.native_endian);
                std.log.info("xdg_surface configure serial={}", .{serial});
                try wl.xdg_surface.ack_configure(writer, ids.get(.xdg_surface), serial);
                if (configured) |c| c.* = true;
            },
            else => std.debug.panic("unhandled xdg_surface event opcode={}", .{opcode}),
        },
        .xdg_toplevel => switch (opcode) {
            wl.xdg_toplevel.event.configure => {
                // width(int) + height(int) + states(array: len + data)
                const toplevel_width = try reader.takeInt(i32, wl.native_endian);
                const toplevel_height = try reader.takeInt(i32, wl.native_endian);
                const states_len = try reader.takeInt(u32, wl.native_endian);
                const states_word_count = @divTrunc(states_len + 3, 4);
                try reader.discardAll(states_word_count * 4);
                std.log.info("xdg_toplevel configure width={} height={}", .{ toplevel_width, toplevel_height });
            },
            wl.xdg_toplevel.event.close => {
                std.log.info("xdg_toplevel close", .{});
                std.process.exit(0);
            },
            wl.xdg_toplevel.event.configure_bounds => {
                // width(int) + height(int)
                const bounds_width = try reader.takeInt(i32, wl.native_endian);
                const bounds_height = try reader.takeInt(i32, wl.native_endian);
                std.log.info("xdg_toplevel configure_bounds width={} height={}", .{ bounds_width, bounds_height });
            },
            wl.xdg_toplevel.event.wm_capabilities => {
                // array: len + data
                const caps_len = try reader.takeInt(u32, wl.native_endian);
                const caps_word_count = @divTrunc(caps_len + 3, 4);
                try reader.discardAll(caps_word_count * 4);
                std.log.info("xdg_toplevel wm_capabilities", .{});
            },
            else => std.debug.panic("unhandled xdg_toplevel event opcode={}", .{opcode}),
        },
        .xdg_decoration_manager => std.debug.panic("unexpected event from xdg_decoration_manager", .{}),
        .xdg_toplevel_decoration => switch (opcode) {
            wl.xdg_toplevel_decoration.event.configure => {
                const mode = try reader.takeInt(u32, wl.native_endian);
                std.log.info("xdg_toplevel_decoration configure mode={}", .{mode});
            },
            else => std.debug.panic("unhandled xdg_toplevel_decoration event opcode={}", .{opcode}),
        },
        .buffer => {
            // wl_buffer.release
            std.log.info("buffer release (size={})", .{size});
        },
        .linux_dmabuf => switch (opcode) {
            wl.linux_dmabuf.event.format => {
                // deprecated format event: format(u32)
                _ = try reader.takeInt(u32, wl.native_endian);
            },
            wl.linux_dmabuf.event.modifier => {
                // format(u32) + modifier_hi(u32) + modifier_lo(u32) + pad(u32)
                _ = try reader.takeInt(u32, wl.native_endian);
                _ = try reader.takeInt(u32, wl.native_endian);
                _ = try reader.takeInt(u32, wl.native_endian);
                _ = try reader.takeInt(u32, wl.native_endian);
            },
            else => std.debug.panic("unhandled linux_dmabuf event opcode={}", .{opcode}),
        },
        .dmabuf_buffer_0 => switch (opcode) {
            wl.wl_buffer.event.release => {
                // std.log.info("dmabuf buffer 0 release", .{});
                if (buffer_released) |br| br[0] = true;
            },
            else => std.debug.panic("unhandled dmabuf_buffer_0 event opcode={}", .{opcode}),
        },
        .dmabuf_buffer_1 => switch (opcode) {
            wl.wl_buffer.event.release => {
                // std.log.info("dmabuf buffer 1 release", .{});
                if (buffer_released) |br| br[1] = true;
            },
            else => std.debug.panic("unhandled dmabuf_buffer_1 event opcode={}", .{opcode}),
        },
        else => std.debug.panic(
            "unhandled event, sender={} opcode={} size={}",
            .{ @intFromEnum(sender), opcode, size },
        ),
    }
}

const std = @import("std");
const wl = @import("wl");
