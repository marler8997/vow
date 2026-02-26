pub const Request = vowproto.Request;
pub const ValidationLayers = vowproto.ValidationLayers;
pub const ShaderStage = vowproto.ShaderStage;
pub const PushConstantRange = vowproto.PushConstantRange;
pub const VertexAttribute = vowproto.VertexAttribute;

pub fn spawn(opt: struct {
    memfds: []const std.posix.fd_t,
    write_exe_path: ?[:0]const u8 = null,
}) !std.fs.File {
    // Read the host's dynamic linker path and libc soname from /usr/bin/env
    const host_interp = readPtInterp("/usr/bin/env") catch |e| std.debug.panic(
        "failed to read PT_INTERP from /usr/bin/env: {t}",
        .{e},
    );
    const host_libc_soname = readLibcSoname("/usr/bin/env") catch |e| std.debug.panic(
        "failed to read libc DT_NEEDED from /usr/bin/env: {t}",
        .{e},
    );

    if (opt.write_exe_path) |path| {
        const file = std.fs.cwd().createFile(path, .{ .mode = 0o755 }) catch |e| std.debug.panic(
            "failed to create vowexe at {s} with {t}",
            .{ path, e },
        );
        defer file.close();
        _ = std.os.linux.fallocate(file.handle, 0, 0, vowexe_content.len);
        try writePatchedExe(file, host_interp, host_libc_soname);
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
        // Write shared buffer preamble: usize count + i32[] fd values
        const file: std.fs.File = .{ .handle = fds[0] };
        var buf: [1000]u8 = undefined;
        var file_writer = file.writer(&buf);
        const w = &file_writer.interface;
        w.writeAll(std.mem.asBytes(&opt.memfds.len)) catch return file_writer.err.?;
        for (opt.memfds) |fd| {
            w.writeAll(std.mem.asBytes(&fd)) catch return file_writer.err.?;
        }
        w.flush() catch return file_writer.err.?;

        fds[0] = -1; // don't close in defer
        return file;
    } else {
        noReturnVowProcess(fds, host_interp, host_libc_soname, opt.write_exe_path);
    }
}
// Markers: must match build.zig exactly.
pub const pt_interp_marker = "!!!VOW_PT_INTERP!!!" ++ ("#" ** (255 - "!!!VOW_PT_INTERP!!!".len));
pub const dt_needed_libc_marker = "!!!VOW_DT_NEEDED_LIBC!!!" ++ ("#" ** (255 - "!!!VOW_DT_NEEDED_LIBC!!!".len));

const vowexe_content = @embedFile("vowexe");

// Offsets come from the analyze_vowexe build tool, which parses the
// ELF at build time (fast native code) instead of expensive comptime evaluation.
const vowexe_analysis = @import("vowexe_analysis");
const pt_interp_offset: usize = vowexe_analysis.pt_interp_offset;
const dt_needed_libc_offset: usize = vowexe_analysis.dt_needed_libc_offset;

fn noReturnVowProcess(fds: [2]i32, host_interp: []const u8, host_libc_soname: []const u8, exe_path: ?[:0]const u8) noreturn {
    std.posix.close(fds[0]);
    exec(fds[1], host_interp, host_libc_soname, exe_path) catch |e| {
        std.log.err("error.{t}", .{e});
        if (@errorReturnTrace()) |t| std.debug.dumpStackTrace(t.*);
        std.process.exit(0xff);
    };
}
fn exec(socket_fd: i32, host_interp: []const u8, host_libc_soname: []const u8, exe_path: ?[:0]const u8) !noreturn {
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
        const fd = try std.posix.memfd_createZ("vowexec", std.posix.MFD.CLOEXEC);
        try std.posix.ftruncate(fd, vowexe_content.len);
        try writePatchedExe(.{ .handle = fd }, host_interp, host_libc_soname);
        const err = linuxext.execveat(fd, "", &argv, envp, std.os.linux.AT.EMPTY_PATH);
        const errno = std.posix.errno(err);
        std.debug.panic("vow: execveat vowexe failed: {t}", .{errno});
    }
}

fn writePatchedExe(file: std.fs.File, host_interp: []const u8, host_libc_soname: []const u8) !void {
    var patched_interp: [255]u8 = @splat(0);
    @memcpy(patched_interp[0..host_interp.len], host_interp);

    var patched_libc: [255]u8 = @splat(0);
    @memcpy(patched_libc[0..host_libc_soname.len], host_libc_soname);

    // Write the exe with both markers patched. The two markers are at
    // different offsets; write the content in order, patching each one.
    const first_offset = @min(pt_interp_offset, dt_needed_libc_offset);
    const second_offset = @max(pt_interp_offset, dt_needed_libc_offset);
    const first_patch: *const [255]u8 = if (first_offset == pt_interp_offset) &patched_interp else &patched_libc;
    const second_patch: *const [255]u8 = if (second_offset == pt_interp_offset) &patched_interp else &patched_libc;

    try file.writeAll(vowexe_content[0..first_offset]);
    try file.writeAll(first_patch);
    try file.writeAll(vowexe_content[first_offset + 255 .. second_offset]);
    try file.writeAll(second_patch);
    try file.writeAll(vowexe_content[second_offset + 255 ..]);
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

/// Read the libc soname from an ELF file's DT_NEEDED entries.
/// Returns the first DT_NEEDED entry that looks like libc.
/// Returns a slice into a static buffer.
fn readLibcSoname(path: []const u8) ![]const u8 {
    const S = struct {
        var buf: [255]u8 = undefined;
    };

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Read ELF header
    var ehdr_buf: [@sizeOf(std.elf.Elf64_Ehdr)]u8 align(@alignOf(std.elf.Elf64_Ehdr)) = undefined;
    if (try file.preadAll(&ehdr_buf, 0) < @sizeOf(std.elf.Elf64_Ehdr)) return error.InvalidElf;
    const ehdr: *const std.elf.Elf64_Ehdr = @ptrCast(&ehdr_buf);
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], "\x7fELF")) return error.InvalidElf;

    // Find PT_DYNAMIC and PT_LOAD segments
    var dyn_off: ?u64 = null;
    var dyn_size: ?u64 = null;
    var loads: [32]struct { vaddr: u64, offset: u64, filesz: u64 } = undefined;
    var load_count: usize = 0;

    var i: u16 = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        var phdr_buf: [@sizeOf(std.elf.Elf64_Phdr)]u8 align(@alignOf(std.elf.Elf64_Phdr)) = undefined;
        const phdr_off = ehdr.e_phoff + @as(u64, i) * ehdr.e_phentsize;
        if (try file.preadAll(&phdr_buf, phdr_off) < @sizeOf(std.elf.Elf64_Phdr)) return error.InvalidElf;
        const phdr: *const std.elf.Elf64_Phdr = @ptrCast(&phdr_buf);
        if (phdr.p_type == std.elf.PT_DYNAMIC) {
            dyn_off = phdr.p_offset;
            dyn_size = phdr.p_filesz;
        }
        if (phdr.p_type == std.elf.PT_LOAD) {
            if (load_count >= loads.len) return error.InvalidElf;
            loads[load_count] = .{ .vaddr = phdr.p_vaddr, .offset = phdr.p_offset, .filesz = phdr.p_filesz };
            load_count += 1;
        }
    }
    if (dyn_off == null) return error.NoDynamic;

    // Find STRTAB
    var strtab_addr: ?u64 = null;
    const dyn_entry_count = dyn_size.? / @sizeOf(std.elf.Elf64_Dyn);
    var dyn_buf: [@sizeOf(std.elf.Elf64_Dyn)]u8 align(@alignOf(std.elf.Elf64_Dyn)) = undefined;
    var j: u64 = 0;
    while (j < dyn_entry_count) : (j += 1) {
        _ = try file.preadAll(&dyn_buf, dyn_off.? + j * @sizeOf(std.elf.Elf64_Dyn));
        const dyn: *const std.elf.Elf64_Dyn = @ptrCast(&dyn_buf);
        if (dyn.d_tag == std.elf.DT_STRTAB) {
            strtab_addr = dyn.d_val;
            break;
        }
    }
    if (strtab_addr == null) return error.NoStrtab;

    // Map STRTAB vaddr to file offset
    const strtab_file_off: u64 = blk: {
        for (loads[0..load_count]) |load| {
            if (strtab_addr.? >= load.vaddr and strtab_addr.? < load.vaddr + load.filesz) {
                break :blk load.offset + (strtab_addr.? - load.vaddr);
            }
        }
        return error.InvalidElf;
    };

    // Scan DT_NEEDED entries for one that looks like libc
    j = 0;
    while (j < dyn_entry_count) : (j += 1) {
        _ = try file.preadAll(&dyn_buf, dyn_off.? + j * @sizeOf(std.elf.Elf64_Dyn));
        const dyn: *const std.elf.Elf64_Dyn = @ptrCast(&dyn_buf);
        if (dyn.d_tag == std.elf.DT_NEEDED) {
            var name_buf: [256]u8 = undefined;
            const n = try file.preadAll(&name_buf, strtab_file_off + dyn.d_val);
            const name = std.mem.sliceTo(name_buf[0..n], 0);
            // Match libc sonames: "libc.so.6" (glibc), "libc.musl-*.so.1" (musl),
            // or "ld-musl-*.so.1" (musl where ld is libc)
            if (std.mem.startsWith(u8, name, "libc.") or
                std.mem.startsWith(u8, name, "ld-musl"))
            {
                if (name.len > S.buf.len) return error.SonameTooLong;
                @memcpy(S.buf[0..name.len], name);
                return S.buf[0..name.len];
            }
        }
    }
    return error.NoLibcFound;
}

pub const SharedMem = struct {
    fd: std.posix.fd_t,
    slice: []align(std.heap.page_size_min) u8,
    pub fn create(size: usize) !SharedMem {
        const fd = try std.posix.memfd_createZ("vow_shared", 0); // no CLOEXEC
        errdefer std.posix.close(fd);
        try std.posix.ftruncate(fd, @intCast(size));
        const mapped = try std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
        return .{ .fd = fd, .slice = mapped.ptr[0..size] };
    }
    pub fn destroy(s: SharedMem) void {
        std.posix.munmap(s.slice);
        std.posix.close(s.fd);
    }
};

// pub fn resizeMemfd(memfd: *Memfd, new_size: usize) !void {
//     try std.posix.ftruncate(buf.fd, @intCast(new_size));
//     const new_ptr = std.os.linux.mremap(buf.ptr, buf.len, new_size, .{ .MAYMOVE = true });
//     if (new_ptr == std.posix.MAP_FAILED) return error.MremapFailed;
//     buf.ptr = @ptrCast(@alignCast(new_ptr));
//     buf.len = new_size;
// }

// pub fn writeResizeSharedMem(writer: *std.Io.Writer, named: struct {
//     buffer_id: u32,
//     new_size: u64,
// }) error{WriteFailed}!void {
//     try writer.writeByte(@intFromEnum(Request.resize_shared_buffer));
//     try writer.writeAll(std.mem.asBytes(&named.buffer_id));
//     try writer.writeAll(std.mem.asBytes(&named.new_size));
// }

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
