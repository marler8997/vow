pub const Connection = xcb.Connection;
pub const ConnectError = xcb.ConnectError;
pub const Window = xcb.Window;
pub const Visual = xcb.Visual;
pub const VoidCookie = xcb.VoidCookie;

pub const fmtDisplay = xcb.fmtDisplay;

pub fn connect(display: ?[:0]const u8) ConnectError!struct { *Connection, u8 } {
    var screen_count: c_int = undefined;
    const connection = lazy.xcb_connect(if (display) |d| d.ptr else null, &screen_count);
    const err = lazy.xcb_connection_has_error(connection);
    return switch (err) {
        0 => .{ connection, @intCast(screen_count) },
        1 => error.SocketError,
        2 => error.ExtensionNotSupported,
        3 => error.InsufficientMemory,
        4 => error.RequestLengthExceeded,
        5 => error.DisplayParseError,
        6 => error.InvalidScreen,
        else => |e| {
            std.log.err("unexpected xcb connection error {}", .{e});
            return error.Unexpected;
        },
    };
}
pub const disconnect = lazy.xcb_disconnect;
pub const map_window = lazy.xcb_map_window;
pub const flush = lazy.xcb_flush;

const xcb_lib = "libxcb.so.1";
const lazy = solazy.namespace(.panic, &.{
    .{ .lib = xcb_lib, .name = "xcb_connect", .Fn = fn (display: ?[*:0]const u8, screenp: *c_int) callconv(.c) *Connection },
    .{ .lib = xcb_lib, .name = "xcb_disconnect", .Fn = fn (*Connection) callconv(.c) void },
    .{ .lib = xcb_lib, .name = "xcb_connection_has_error", .Fn = fn (*Connection) callconv(.c) c_int },
    .{ .lib = xcb_lib, .name = "xcb_flush", .Fn = fn (*Connection) callconv(.c) c_int },
    .{ .lib = xcb_lib, .name = "xcb_map_window", .Fn = fn (*Connection, Window) callconv(.c) VoidCookie },
});

const std = @import("std");
const xcb = @import("xcb");
const solazy = @import("solazy");
