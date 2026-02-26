pub const Request = vowproto.Request;
pub const ValidationLayers = vowproto.ValidationLayers;
pub const ShaderStage = vowproto.ShaderStage;
pub const PushConstantRange = vowproto.PushConstantRange;
pub const VertexAttribute = vowproto.VertexAttribute;

pub fn spawn(opt: struct {
    write_exe_path: ?[:0]const u8 = null,
}) !std.net.Stream {
    // Read the host's dynamic linker path from /usr/bin/env
    const host_interp = readPtInterp("/usr/bin/env") catch |e| std.debug.panic(
        "failed to read PT_INTERP from /usr/bin/env: {t}",
        .{e},
    );

    if (opt.write_exe_path) |path| {
        const file = std.fs.cwd().createFile(path, .{ .mode = 0o755 }) catch |e| std.debug.panic(
            "failed to create vowexe at {s} with {t}",
            .{ path, e },
        );
        defer file.close();
        writePatchedExe(file, host_interp);
    }

    var fds: [2]i32 = undefined;
    switch (std.posix.errno(std.os.linux.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
        &fds,
    ))) {
        .SUCCESS => {},
        else => |errno| {
            std.log.err("socketpair failed with unexpected errno {}", .{errno});
            return error.Unexpected;
        },
    }
    defer {
        if (fds[0] != -1) std.posix.close(fds[0]);
        if (fds[1] != -1) std.posix.close(fds[1]);
    }

    const pid = try std.posix.fork();
    const is_original_process = (pid != 0);
    if (is_original_process) {
        const parent_fd = fds[0];
        fds[0] = -1; // don't close in defer
        return .{ .handle = parent_fd };
    } else {
        noReturnVowProcess(fds, host_interp, opt.write_exe_path);
    }
}
// PT_INTERP marker: must match build.zig exactly.
pub const pt_interp_marker = "!!!VOW_PT_INTERP!!!" ++ ("#" ** (255 - "!!!VOW_PT_INTERP!!!".len));

const vowexe_content = @embedFile("vowexe");

// PT_INTERP offset comes from the analyze_vowexe build tool, which parses the
// ELF at build time (fast native code) instead of expensive comptime evaluation.
const vowexe_analysis = @import("vowexe_analysis");
const pt_interp_offset: usize = vowexe_analysis.pt_interp_offset;

fn noReturnVowProcess(fds: [2]i32, host_interp: []const u8, exe_path: ?[:0]const u8) noreturn {
    std.posix.close(fds[0]);
    exec(fds[1], host_interp, exe_path) catch |e| {
        std.log.err("error.{t}", .{e});
        if (@errorReturnTrace()) |t| std.debug.dumpStackTrace(t.*);
        std.process.exit(0xff);
    };
}
fn exec(socket_fd: i32, host_interp: []const u8, exe_path: ?[:0]const u8) !noreturn {
    // TODO: should we close other file descriptors?
    const stdin = 0;
    if (socket_fd != stdin) {
        try std.posix.dup2(socket_fd, stdin);
        std.posix.close(socket_fd);
    }
    const argv = [_:null]?[*:0]const u8{"vowexe"};
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.os.environ.ptr);

    // TODO: vowexe should be compressed
    if (exe_path) |path| {
        const err = std.posix.execveZ(path, &argv, envp);
        std.debug.panic("vow: execve {s} failed: {t}", .{ path, err });
    } else {
        // Write patched exe to memfd and execveat it
        const fd = std.posix.memfd_createZ("vowexec", std.posix.MFD.CLOEXEC) catch |e| std.debug.panic(
            "memfd_create failed with {t}",
            .{e},
        );
        writePatchedExe(.{ .handle = fd }, host_interp);
        const err = linuxext.execveat(fd, "", &argv, envp, std.os.linux.AT.EMPTY_PATH);
        const errno = std.posix.errno(err);
        std.debug.panic("vow: execveat vowexe failed: {t}", .{errno});
    }
}

fn writePatchedExe(file: std.fs.File, host_interp: []const u8) void {
    // Prepare the replacement: real path padded with zeroes to 255 bytes
    var patched_interp: [255]u8 = @splat(0);
    @memcpy(patched_interp[0..host_interp.len], host_interp);

    // Write content before the PT_INTERP marker
    file.writeAll(vowexe_content[0..pt_interp_offset]) catch |e| std.debug.panic(
        "failed to write vowexe pre-marker: {t}",
        .{e},
    );

    // Write the patched PT_INTERP
    file.writeAll(&patched_interp) catch |e| std.debug.panic(
        "failed to write patched PT_INTERP: {t}",
        .{e},
    );

    // Write content after the marker
    file.writeAll(vowexe_content[pt_interp_offset + pt_interp_marker.len ..]) catch |e| std.debug.panic(
        "failed to write vowexe post-marker: {t}",
        .{e},
    );
}

/// Read PT_INTERP from an ELF file on disk.
/// Returns a slice into a static buffer.
fn readPtInterp(path: []const u8) ![]const u8 {
    const S = struct {
        var buf: [255]u8 = undefined;
    };

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Read ELF header
    var ehdr_buf: [@sizeOf(std.elf.Elf64_Ehdr)]u8 align(@alignOf(std.elf.Elf64_Ehdr)) = undefined;
    const ehdr_len = try file.preadAll(&ehdr_buf, 0);
    if (ehdr_len < @sizeOf(std.elf.Elf64_Ehdr)) return error.InvalidElf;

    const ehdr: *const std.elf.Elf64_Ehdr = @ptrCast(&ehdr_buf);
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], "\x7fELF")) return error.InvalidElf;

    // Iterate program headers to find PT_INTERP
    var i: u16 = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        var phdr_buf: [@sizeOf(std.elf.Elf64_Phdr)]u8 align(@alignOf(std.elf.Elf64_Phdr)) = undefined;
        const phdr_off = ehdr.e_phoff + @as(u64, i) * ehdr.e_phentsize;
        const phdr_read = try file.preadAll(&phdr_buf, phdr_off);
        if (phdr_read < @sizeOf(std.elf.Elf64_Phdr)) return error.InvalidElf;

        const phdr: *const std.elf.Elf64_Phdr = @ptrCast(&phdr_buf);
        if (phdr.p_type == std.elf.PT_INTERP) {
            if (phdr.p_filesz < 2 or phdr.p_filesz > 256) return error.InvalidElf;
            const filesz: usize = @intCast(phdr.p_filesz);
            // PT_INTERP includes null terminator in filesz
            const len = filesz - 1;
            const read_len = try file.preadAll(S.buf[0..len], phdr.p_offset);
            if (read_len < len) return error.InvalidElf;
            return S.buf[0..len];
        }
    }
    return error.NoPtInterp;
}

pub fn writeCreateGc(writer: *std.Io.Writer, named: struct {
    window: u32,
    validation_layers: ValidationLayers,
}) error{WriteFailed}!void {
    try writer.writeByte(@intFromEnum(Request.create_gc));
    try writer.writeAll(std.mem.asBytes(&named.window));
    try writer.writeByte(@intFromEnum(named.validation_layers));
}
pub fn writeShader(writer: *std.Io.Writer, kind: enum { vert, frag }, shader: []const u8) error{WriteFailed}!void {
    try writer.writeByte(switch (kind) {
        .vert => @intFromEnum(Request.vert_shader),
        .frag => @intFromEnum(Request.frag_shader),
    });
    try writer.writeAll(std.mem.asBytes(&shader.len));
    try writer.writeAll(shader);
}
pub fn writeVertices(writer: *std.Io.Writer, named: struct {
    vertex_count: u32,
    stride: u32,
    attributes: []const VertexAttribute,
    data: []const u8,
}) error{WriteFailed}!void {
    try writer.writeByte(@intFromEnum(Request.vertices));
    try writer.writeAll(std.mem.asBytes(&named.vertex_count));
    try writer.writeAll(std.mem.asBytes(&named.stride));
    const num_attrs: u8 = @intCast(named.attributes.len);
    try writer.writeByte(num_attrs);
    for (named.attributes) |attr| {
        try writer.writeByte(attr.location);
        const fmt: u32 = @intFromEnum(attr.format);
        try writer.writeAll(std.mem.asBytes(&fmt));
        try writer.writeAll(std.mem.asBytes(&attr.offset));
    }
    try writer.writeAll(named.data);
}
pub fn writePushConstantRanges(writer: *std.Io.Writer, ranges: []const PushConstantRange) error{WriteFailed}!void {
    try writer.writeByte(@intFromEnum(Request.push_constant_ranges));
    const count: u8 = @intCast(ranges.len);
    try writer.writeByte(count);
    try writer.writeAll(std.mem.sliceAsBytes(ranges));
}
pub fn writeUpdate(writer: *std.Io.Writer, push_constants: []const u8) error{WriteFailed}!void {
    try writer.writeByte(@intFromEnum(Request.update));
    try writer.writeAll(std.mem.asBytes(&push_constants.len));
    try writer.writeAll(push_constants);
}
pub fn writeClearColor(writer: *std.Io.Writer, color: [4]f32) error{WriteFailed}!void {
    try writer.writeByte(@intFromEnum(Request.clear_color));
    try writer.writeAll(std.mem.asBytes(&color));
}
pub fn writePlaceholder(writer: *std.Io.Writer, named: struct {
    map_on_present: u8,
}) error{WriteFailed}!void {
    try writer.writeByte(@intFromEnum(Request.placeholder));
    try writer.writeByte(named.map_on_present);
}

const linuxext = struct {
    pub fn execveat(dirfd: std.posix.fd_t, path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, e: [*:null]const ?[*:0]const u8, flags: usize) usize {
        return std.os.linux.syscall5(
            .execveat,
            @bitCast(@as(isize, dirfd)),
            @intFromPtr(path),
            @intFromPtr(argv),
            @intFromPtr(e),
            flags,
        );
    }
};

const builtin = @import("builtin");
const std = @import("std");
const root = @import("root");
const vowproto = @import("vowproto");
