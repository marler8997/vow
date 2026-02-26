extern "xcb" fn xcb_connect(displayname: ?[*:0]const u8, screenp: *c_int) callconv(.c) *Connection;

pub const ConnectError = error{
    SocketError,
    ExtensionNotSupported,
    InsufficientMemory,
    RequestLengthExceeded,
    DisplayParseError,
    InvalidScreen,
    Unexpected,
};

/// calls xcb_connect with error checking. second return value is the screen count, i.e.
///    const connection, const screen_count = connect(display);
/// get display via std.posix.getenv("DISPLAY").
pub fn connect(display: ?[:0]const u8) ConnectError!struct { *Connection, u8 } {
    var screen_count: c_int = undefined;
    const connection = xcb_connect(if (display) |d| d.ptr else null, &screen_count);
    const err = xcb_connection_has_error(connection);
    return switch (err) {
        // intCast valid since x11 protocol uses u8 to send screen count
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

extern "xcb" fn xcb_flush(c: *Connection) callconv(.c) c_int;
pub const flush = xcb_flush;

extern "xcb" fn xcb_get_setup(c: *Connection) callconv(.c) *const xcb_setup_t;
pub const get_setup = xcb_get_setup;

extern "xcb" fn xcb_connection_has_error(c: *Connection) callconv(.c) c_int;
pub const connection_has_error = xcb_connection_has_error;

extern "xcb" fn xcb_setup_roots_iterator(R: *const xcb_setup_t) callconv(.c) xcb_screen_iterator_t;
pub const setup_roots_iterator = xcb_setup_roots_iterator;

extern "xcb" fn xcb_screen_next(i: *xcb_screen_iterator_t) callconv(.c) void;
pub const screen_next = xcb_screen_next;

extern "xcb" fn xcb_generate_id(c: *Connection) callconv(.c) Resource;
pub const generate_id = xcb_generate_id;

extern "xcb" fn xcb_create_window(
    c: *Connection,
    depth: u8,
    wid: Window,
    parent: Window,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
    class: Class,
    visual: Visual,
    value_mask: CreateWindowOptionMask,
    value_list: ?[*]const u32,
) callconv(.c) xcb_void_cookie_t;

pub fn create_window(
    c: *Connection,
    args: CreateWindowArgs,
    options: CreateWindowOptions,
) xcb_void_cookie_t {
    const option_fields = std.meta.fields(CreateWindowOptions);
    var option_mask: CreateWindowOptionMask = .{};
    var option_buf: [option_fields.len]u32 = undefined;
    var option_count: u8 = 0;
    inline for (std.meta.fields(CreateWindowOptions)) |field| {
        if (!isDefaultValue(&options, field)) {
            @field(option_mask, field.name) = 1;
            option_buf[option_count] = optionToU32(@field(options, field.name));
            option_count += 1;
        }
    }

    return xcb_create_window(
        c,
        switch (args.depth) {
            .copy_from_parent => 0,
            .custom => |d| d.byte(),
        },
        args.wid,
        args.parent,
        args.x,
        args.y,
        args.width,
        args.height,
        args.border_width,
        args.class,
        args.visual,
        option_mask,
        &option_buf,
    );
}

pub const CreateWindowArgs = struct {
    wid: Window,
    parent: Window,
    depth: union(enum) {
        copy_from_parent,
        custom: Depth,
    },
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
    class: Class,
    visual: Visual,
};
pub const EventMask = packed struct(u32) {
    KeyPress: u1 = 0,
    KeyRelease: u1 = 0,
    ButtonPress: u1 = 0,
    ButtonRelease: u1 = 0,
    EnterWindow: u1 = 0,
    LeaveWindow: u1 = 0,
    PointerMotion: u1 = 0,
    PointerMotionHint: u1 = 0,
    Button1Motion: u1 = 0,
    Button2Motion: u1 = 0,
    Button3Motion: u1 = 0,
    Button4Motion: u1 = 0,
    Button5Motion: u1 = 0,
    ButtonMotion: u1 = 0,
    KeymapState: u1 = 0,
    Exposure: u1 = 0,
    VisibilityChange: u1 = 0,
    StructureNotify: u1 = 0,
    ResizeRedirect: u1 = 0,
    /// Results in CreateNotify, DestroyNotify, MapNotify, UnmapNotify, ReparentNotify,
    /// ConfigureNotify, GravityNotify, CirculateNotify.
    SubstructureNotify: u1 = 0,
    SubstructureRedirect: u1 = 0,
    FocusChange: u1 = 0,
    PropertyChange: u1 = 0,
    ColormapChange: u1 = 0,
    OwnerGrabButton: u1 = 0,
    _reserved: u7 = 0,
};

const CreateWindowOptionMask = packed struct(u32) {
    bg_pixmap: u1 = 0,
    bg_pixel: u1 = 0,
    border_pixmap: u1 = 0,
    border_pixel: u1 = 0,
    bit_gravity: u1 = 0,
    win_gravity: u1 = 0,
    backing_store: u1 = 0,
    backing_planes: u1 = 0,
    backing_pixel: u1 = 0,
    override_redirect: u1 = 0,
    save_under: u1 = 0,
    event_mask: u1 = 0,
    dont_propagate: u1 = 0,
    colormap: u1 = 0,
    cursor: u1 = 0,
    _unused: u17 = 0,
};
pub const CreateWindowOptions = struct {
    bg_pixmap: BgPixmap = .none,
    bg_pixel: ?u32 = null,
    border_pixmap: BorderPixmap = .copy_from_parent,
    border_pixel: ?u32 = null,
    bit_gravity: BitGravity = .forget,
    win_gravity: WinGravity = .north_west,
    backing_store: BackingStore = .not_useful,
    backing_planes: u32 = 0xffffffff,
    backing_pixel: u32 = 0,
    override_redirect: bool = false,
    save_under: bool = false,
    event_mask: EventMask = .{},
    dont_propagate: u32 = 0,
    colormap: Colormap = .copy_from_parent,
    cursor: Cursor = .none,

    pub const BgPixmap = enum(u32) { none = 0, copy_from_parent = 1 };
    pub const BorderPixmap = enum(u32) { copy_from_parent = 0 };
    pub const BackingStore = enum(u32) { not_useful = 0, when_mapped = 1, always = 2 };
    pub const BitGravity = enum(u4) {
        forget = 0,
        north_west = 1,
        north = 2,
        north_east = 3,
        west = 4,
        center = 5,
        east = 6,
        south_west = 7,
        south = 8,
        south_east = 9,
        static = 10,
    };
    pub const WinGravity = enum(u4) {
        unmap = 0,
        north_west = 1,
        north = 2,
        north_east = 3,
        west = 4,
        center = 5,
        east = 6,
        south_west = 7,
        south = 8,
        south_east = 9,
        static = 10,
    };
};

pub fn optionToU32(value: anytype) u32 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => return @intFromBool(value),
        .@"enum" => return @intFromEnum(value),
        .optional => |opt| {
            switch (@typeInfo(opt.child)) {
                .bool => return @intFromBool(value.?),
                .@"enum" => return @intFromEnum(value.?),
                else => {},
            }
        },
        else => {},
    }
    if (T == u32) return value;
    if (T == EventMask) return @bitCast(value);
    if (T == ?u32) return value.?;
    if (T == u16) return @intCast(value);
    if (T == ?u16) return @intCast(value.?);
    if (T == i16) return @intCast(@as(u16, @bitCast(value)));
    if (T == ?i16) return @intCast(@as(u16, @bitCast(value.?)));
    @compileError("TODO: implement optionToU32 for type: " ++ @typeName(T));
}

pub fn isDefaultValue(s: anytype, comptime field: std.builtin.Type.StructField) bool {
    const default_value_ptr = @as(?*align(1) const field.type, @ptrCast(field.default_value_ptr)) orelse
        @compileError("isDefaultValue was called on field '" ++ field.name ++ "' which has no default value");
    switch (@typeInfo(field.type)) {
        .optional => {
            comptime std.debug.assert(default_value_ptr.* == null); // we're assuming all Optionals default to null
            return @field(s, field.name) == null;
        },
        else => {
            return @field(s, field.name) == default_value_ptr.*;
        },
    }
}

pub const wait_for_event = @extern(*const fn (c: *Connection) callconv(.c) ?*generic_event_t, .{
    .name = "xcb_wait_for_event",
    .library_name = "xcb",
});
pub const poll_for_event = @extern(*const fn (c: *Connection) callconv(.c) ?*generic_event_t, .{
    .name = "xcb_poll_for_event",
    .library_name = "xcb",
});
pub const get_file_descriptor = @extern(*const fn (c: *Connection) callconv(.c) c_int, .{
    .name = "xcb_get_file_descriptor",
    .library_name = "xcb",
});
pub const intern_atom = @extern(*const InternAtomFn, .{
    .name = "xcb_intern_atom",
    .library_name = "xcb",
});

extern "xcb" fn xcb_intern_atom_reply(
    c: *Connection,
    cookie: intern_atom_cookie_t,
    e: ?**xcb_generic_error_t,
) callconv(.c) ?*intern_atom_reply_t;
pub const intern_atom_reply = xcb_intern_atom_reply;

extern "xcb" fn xcb_change_property(
    c: *Connection,
    mode: prop_mode_t,
    window: Window,
    property: atom_t,
    type: atom_t,
    format: u8,
    data_len: u32,
    data: ?*const anyopaque,
) callconv(.c) xcb_void_cookie_t;
pub const change_property = xcb_change_property;

extern "xcb" fn xcb_map_window(c: *Connection, window: Window) callconv(.c) xcb_void_cookie_t;
pub const map_window = xcb_map_window;

pub const InternAtomFn = fn (
    c: *Connection,
    only_if_exists: u8,
    name_len: u16,
    name: [*:0]const u8,
) callconv(.c) intern_atom_cookie_t;

pub const InternAtomReplyFn = fn (
    c: *Connection,
    cookie: intern_atom_cookie_t,
    e: ?**xcb_generic_error_t,
) callconv(.c) *intern_atom_reply_t;

pub const Connection = opaque {};
pub const keycode_t = u8;
pub const Resource = enum(u32) {
    none = 0,
    _,

    pub fn window(r: Resource) Window {
        return @enumFromInt(@intFromEnum(r));
    }

    // pub fn drawable(r: Resource) Drawable {
    //     return @enumFromInt(@intFromEnum(r));
    // }

    // pub fn font(r: Resource) Font {
    //     return @enumFromInt(@intFromEnum(r));
    // }

    // pub fn fontable(r: Resource) Fontable {
    //     return @enumFromInt(@intFromEnum(r));
    // }

    // pub fn graphicsContext(r: Resource) GraphicsContext {
    //     return @enumFromInt(@intFromEnum(r));
    // }

    // pub fn pixmap(r: Resource) Pixmap {
    //     return @enumFromInt(@intFromEnum(r));
    // }

    // pub fn picture(r: Resource) render.Picture {
    //     return @enumFromInt(@intFromEnum(r));
    // }

    // pub fn colormap(r: Resource) Colormap {
    //     return @enumFromInt(@intFromEnum(r));
    // }

    // pub fn fixesRegion(r: Resource) fixes.Region {
    //     return @enumFromInt(@intFromEnum(r));
    // }

    pub fn format(r: Resource, writer: *std.Io.Writer) error{WriteFailed}!void {
        try fmtEnum(r).format(writer);
    }
};
pub const Window = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Window {
        return @enumFromInt(i);
    }

    // pub fn resource(w: Window) Resource {
    //     return @enumFromInt(@intFromEnum(w));
    // }
    // pub fn drawable(w: Window) Drawable {
    //     return @enumFromInt(@intFromEnum(w));
    // }

    pub fn format(w: Window, writer: *std.Io.Writer) error{WriteFailed}!void {
        try fmtEnum(w).format(writer);
    }
};
pub const colormap_t = u32;
pub const Class = enum(u8) {
    copy_from_parent = 0,
    input_output = 1,
    input_only = 2,
};
pub const Colormap = enum(u32) {
    copy_from_parent = 0,
    _,

    pub fn fromInt(i: u32) Colormap {
        return @enumFromInt(i);
    }

    pub fn format(c: Colormap, writer: *std.Io.Writer) error{WriteFailed}!void {
        try fmtEnum(c).format(writer);
    }
};
pub const Visual = enum(u32) {
    pub fn fromInt(i: u32) Visual {
        return @enumFromInt(i);
    }

    copy_from_parent = 0,
    _,

    pub fn forma(visual: Visual, writer: *std.Io.Writer) error{WriteFailed}!void {
        try fmtEnum(visual).format(writer);
    }
};
pub const Cursor = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Cursor {
        return @enumFromInt(i);
    }

    pub fn format(c: Cursor, writer: *std.Io.Writer) error{WriteFailed}!void {
        try fmtEnum(c).format(writer);
    }
};
pub const timestamp_t = u32;

pub const Depth = enum(u8) {
    /// mono (just black/white)
    @"1",
    /// 16-color (early CGA/EGA era)
    @"4",
    /// 256-color (indexed/palette-based color)
    @"8",
    /// 32,768 colors (5 bits per channel)
    @"15",
    /// 65,536 colors (typically 5-6-5 RGB)
    @"16",
    /// 16.7 million colors (8 bits per RGB channel)
    @"24",
    /// same as 24-bit but with an 8-bit alpha or just padding
    @"32",

    pub fn init(b: u8) ?Depth {
        return switch (b) {
            1 => .@"1",
            4 => .@"4",
            8 => .@"8",
            15 => .@"15",
            16 => .@"16",
            24 => .@"24",
            32 => .@"32",
            else => null,
        };
    }

    pub fn byte(depth: Depth) u8 {
        return switch (depth) {
            .@"1" => 1,
            .@"4" => 4,
            .@"8" => 8,
            .@"15" => 15,
            .@"16" => 16,
            .@"24" => 24,
            .@"32" => 32,
        };
    }

    // pub fn rgbFrom24(depth: Depth, color: u24) u32 {
    //     return switch (depth) {
    //         .@"1" => rgb1From24(color),
    //         .@"4" => rgb4From24(color),
    //         .@"8" => rgb8From24(color),
    //         .@"15" => rgb15From24(color),
    //         .@"16" => rgb16From24(color),
    //         .@"24" => color,
    //         .@"32" => rgb32From24(color),
    //     };
    // }
};

pub const CW = struct {
    pub const BACK_PIXMAP = 1;
    pub const BACK_PIXEL = 2;
    pub const BORDER_PIXMAP = 4;
    pub const BORDER_PIXEL = 8;
    pub const BIT_GRAVITY = 16;
    pub const WIN_GRAVITY = 32;
    pub const BACKING_STORE = 64;
    pub const BACKING_PLANES = 128;
    pub const BACKING_PIXEL = 256;
    pub const OVERRIDE_REDIRECT = 512;
    pub const SAVE_UNDER = 1024;
    pub const EVENT_MASK = 2048;
    pub const DONT_PROPAGATE = 4096;
    pub const COLORMAP = 8192;
    pub const CURSOR = 16384;
};

pub const EVENT_MASK = struct {
    pub const NO_EVENT = 0;
    pub const KEY_PRESS = 1;
    pub const KEY_RELEASE = 2;
    pub const BUTTON_PRESS = 4;
    pub const BUTTON_RELEASE = 8;
    pub const ENTER_WINDOW = 16;
    pub const LEAVE_WINDOW = 32;
    pub const POINTER_MOTION = 64;
    pub const POINTER_MOTION_HINT = 128;
    pub const BUTTON_1_MOTION = 256;
    pub const BUTTON_2_MOTION = 512;
    pub const BUTTON_3_MOTION = 1024;
    pub const BUTTON_4_MOTION = 2048;
    pub const BUTTON_5_MOTION = 4096;
    pub const BUTTON_MOTION = 8192;
    pub const KEYMAP_STATE = 16384;
    pub const EXPOSURE = 32768;
    pub const VISIBILITY_CHANGE = 65536;
    pub const STRUCTURE_NOTIFY = 131072;
    pub const RESIZE_REDIRECT = 262144;
    pub const SUBSTRUCTURE_NOTIFY = 524288;
    pub const SUBSTRUCTURE_REDIRECT = 1048576;
    pub const FOCUS_CHANGE = 2097152;
    pub const PROPERTY_CHANGE = 4194304;
    pub const COLOR_MAP_CHANGE = 8388608;
    pub const OWNER_GRAB_BUTTON = 16777216;
};

pub const COPY_FROM_PARENT: c_long = 0;

pub const intern_atom_reply_t = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    atom: atom_t,
};

const xcb_generic_error_t = extern struct {
    response_type: u8,
    error_code: u8,
    sequence: u16,
    resource_id: u32,
    minor_code: u16,
    major_code: u8,
    pad0: u8,
    pad: [5]u32,
    full_sequence: u32,
};

pub const intern_atom_cookie_t = extern struct {
    sequence: c_uint,
};

const xcb_void_cookie_t = extern struct {
    sequence: c_uint,
};

const xcb_setup_t = extern struct {
    status: u8,
    pad0: u8,
    protocol_major_version: u16,
    protocol_minor_version: u16,
    length: u16,
    release_number: u32,
    resource_id_base: u32,
    resource_id_mask: u32,
    motion_buffer_size: u32,
    vendor_len: u16,
    maximum_request_length: u16,
    roots_len: u8,
    pixmap_formats_len: u8,
    image_byte_order: u8,
    bitmap_format_bit_order: u8,
    bitmap_format_scanline_unit: u8,
    bitmap_format_scanline_pad: u8,
    min_keycode: keycode_t,
    max_keycode: keycode_t,
    pad1: [4]u8,
};

const xcb_screen_iterator_t = extern struct {
    data: *xcb_screen_t,
    rem: c_int,
    index: c_int,
};
const xcb_screen_t = extern struct {
    root: Window,
    default_colormap: colormap_t,
    white_pixel: u32,
    black_pixel: u32,
    current_input_masks: u32,
    width_in_pixels: u16,
    height_in_pixels: u16,
    width_in_millimeters: u16,
    height_in_millimeters: u16,
    min_installed_maps: u16,
    max_installed_maps: u16,
    root_visual: Visual,
    backing_stores: u8,
    save_unders: u8,
    root_depth: u8,
    allowed_depths_len: u8,
};

pub const prop_mode_t = enum(c_int) {
    REPLACE = 0,
    PREPEND = 1,
    APPEND = 2,
    _,
};

pub const atom_t = enum(u32) {
    NONE = 0,
    PRIMARY = 1,
    SECONDARY = 2,
    ARC = 3,
    ATOM = 4,
    BITMAP = 5,
    CARDINAL = 6,
    COLORMAP = 7,
    CURSOR = 8,
    CUT_BUFFER0 = 9,
    CUT_BUFFER1 = 10,
    CUT_BUFFER2 = 11,
    CUT_BUFFER3 = 12,
    CUT_BUFFER4 = 13,
    CUT_BUFFER5 = 14,
    CUT_BUFFER6 = 15,
    CUT_BUFFER7 = 16,
    DRAWABLE = 17,
    FONT = 18,
    INTEGER = 19,
    PIXMAP = 20,
    POINT = 21,
    RECTANGLE = 22,
    RESOURCE_MANAGER = 23,
    RGB_COLOR_MAP = 24,
    RGB_BEST_MAP = 25,
    RGB_BLUE_MAP = 26,
    RGB_DEFAULT_MAP = 27,
    RGB_GRAY_MAP = 28,
    RGB_GREEN_MAP = 29,
    RGB_RED_MAP = 30,
    STRING = 31,
    VISUALID = 32,
    WINDOW = 33,
    WM_COMMAND = 34,
    WM_HINTS = 35,
    WM_CLIENT_MACHINE = 36,
    WM_ICON_NAME = 37,
    WM_ICON_SIZE = 38,
    WM_NAME = 39,
    WM_NORMAL_HINTS = 40,
    WM_SIZE_HINTS = 41,
    WM_ZOOM_HINTS = 42,
    MIN_SPACE = 43,
    NORM_SPACE = 44,
    MAX_SPACE = 45,
    END_SPACE = 46,
    SUPERSCRIPT_X = 47,
    SUPERSCRIPT_Y = 48,
    SUBSCRIPT_X = 49,
    SUBSCRIPT_Y = 50,
    UNDERLINE_POSITION = 51,
    UNDERLINE_THICKNESS = 52,
    STRIKEOUT_ASCENT = 53,
    STRIKEOUT_DESCENT = 54,
    ITALIC_ANGLE = 55,
    X_HEIGHT = 56,
    QUAD_WIDTH = 57,
    WEIGHT = 58,
    POINT_SIZE = 59,
    RESOLUTION = 60,
    COPYRIGHT = 61,
    NOTICE = 62,
    FONT_NAME = 63,
    FAMILY_NAME = 64,
    FULL_NAME = 65,
    CAP_HEIGHT = 66,
    WM_CLASS = 67,
    WM_TRANSIENT_FOR = 68,
    _,
};

pub const window_class_t = enum(c_int) {
    COPY_FROM_PARENT = 0,
    INPUT_OUTPUT = 1,
    INPUT_ONLY = 2,
    _,
};

pub const generic_event_t = extern struct {
    response_type: ResponseType,
    pad0: u8,
    sequence: u16,
    pad: [7]u32,
    full_sequence: u32,
};

pub const ResponseType = packed struct(u8) {
    op: Op,
    mystery: u1,

    pub const Op = enum(u7) {
        KEY_PRESS = 2,
        KEY_RELEASE = 3,
        BUTTON_PRESS = 4,
        BUTTON_RELEASE = 5,
        MOTION_NOTIFY = 6,
        ENTER_NOTIFY = 7,
        LEAVE_NOTIFY = 8,
        FOCUS_IN = 9,
        FOCUS_OUT = 10,
        KEYMAP_NOTIFY = 11,
        EXPOSE = 12,
        GRAPHICS_EXPOSURE = 13,
        NO_EXPOSURE = 14,
        VISIBILITY_NOTIFY = 15,
        CREATE_NOTIFY = 16,
        DESTROY_NOTIFY = 17,
        UNMAP_NOTIFY = 18,
        MAP_NOTIFY = 19,
        MAP_REQUEST = 20,
        REPARENT_NOTIFY = 21,
        CONFIGURE_NOTIFY = 22,
        CONFIGURE_REQUEST = 23,
        GRAVITY_NOTIFY = 24,
        RESIZE_REQUEST = 25,
        CIRCULATE_NOTIFY = 26,
        CIRCULATE_REQUEST = 27,
        PROPERTY_NOTIFY = 28,
        SELECTION_CLEAR = 29,
        SELECTION_REQUEST = 30,
        SELECTION_NOTIFY = 31,
        COLORMAP_NOTIFY = 32,
        CLIENT_MESSAGE = 33,
        MAPPING_NOTIFY = 34,
        GE_GENERIC = 35,
    };
};

pub const client_message_event_t = extern struct {
    response_type: ResponseType,
    format: u8,
    sequence: u16,
    window: Window,
    type: atom_t,
    data: client_message_data_t,
};

pub const client_message_data_t = extern union {
    data8: [20]u8,
    data16: [10]u16,
    data32: [5]u32,
};

pub const configure_notify_event_t = extern struct {
    response_type: ResponseType,
    pad0: u8,
    sequence: u16,
    event: Window,
    window: Window,
    above_sibling: Window,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
    override_redirect: u8,
    pad1: u8,
};

pub const key_press_event_t = extern struct {
    response_type: ResponseType,
    detail: keycode_t,
    sequence: u16,
    time: timestamp_t,
    root: Window,
    event: Window,
    child: Window,
    root_x: i16,
    root_y: i16,
    event_x: i16,
    event_y: i16,
    state: u16,
    same_screen: u8,
    pad0: u8,
};

pub fn fmtDisplay(display: ?[]const u8) FmtDisplay {
    return .{ .display = display };
}
pub const FmtDisplay = struct {
    display: ?[]const u8,
    pub fn format(f: FmtDisplay, writer: *std.Io.Writer) error{WriteFailed}!void {
        if (f.display) |d| try writer.print("\"{s}\"", .{d}) else try writer.writeAll("null");
    }
};

/// returns a formatter that will print the enum value name if it exists,
/// otherwise, it prints a question mark followed by the value, i.e. ?(123)
pub fn fmtEnum(enum_value: anytype) FmtEnum(@TypeOf(enum_value)) {
    return .{ .value = enum_value };
}
pub fn FmtEnum(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();
        pub fn format(self: Self, writer: *std.Io.Writer) error{WriteFailed}!void {
            if (@typeInfo(T).@"enum".is_exhaustive) {
                try writer.print("{s}", .{@tagName(self.value)});
            } else {
                @setEvalBranchQuota(@typeInfo(T).@"enum".fields.len);
                if (std.enums.tagName(T, self.value)) |name| {
                    try writer.print("{s}", .{name});
                } else {
                    try writer.print("?({d})", .{@intFromEnum(self.value)});
                }
            }
        }
    };
}

const std = @import("std");
