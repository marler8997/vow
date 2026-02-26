const std = @import("std");

fn usage() noreturn {
    fatal("usage: analyze_vowexe <input> <output> <pt_interp_marker> <dt_needed_libc_marker>", .{});
}

pub fn main() !void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var args = try std.process.argsWithAllocator(arena);
    _ = args.next();
    const input_path = args.next() orelse usage();
    const output_path = args.next() orelse usage();
    const pt_interp_marker = args.next() orelse usage();
    const dt_needed_libc_marker = args.next() orelse usage();

    const file = try std.fs.cwd().openFile(input_path, .{});
    defer file.close();

    // Read ELF header
    var ehdr_buf: [@sizeOf(std.elf.Elf64_Ehdr)]u8 align(@alignOf(std.elf.Elf64_Ehdr)) = undefined;
    if (try file.preadAll(&ehdr_buf, 0) < @sizeOf(std.elf.Elf64_Ehdr))
        fatal("vowexe too small for ELF header", .{});
    const ehdr: *const std.elf.Elf64_Ehdr = @ptrCast(&ehdr_buf);
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], "\x7fELF"))
        fatal("vowexe is not a valid ELF", .{});

    // Find PT_INTERP
    var pt_interp_offset: ?u64 = null;
    var i: u16 = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        var phdr_buf: [@sizeOf(std.elf.Elf64_Phdr)]u8 align(@alignOf(std.elf.Elf64_Phdr)) = undefined;
        const phdr_file_off = ehdr.e_phoff + @as(u64, i) * ehdr.e_phentsize;
        if (try file.preadAll(&phdr_buf, phdr_file_off) < @sizeOf(std.elf.Elf64_Phdr))
            fatal("truncated program header", .{});
        const phdr: *const std.elf.Elf64_Phdr = @ptrCast(&phdr_buf);
        if (phdr.p_type == std.elf.PT_INTERP) {
            // Verify marker is present
            var interp_buf: [255]u8 = undefined;
            const filesz: usize = @intCast(phdr.p_filesz);
            if (filesz < pt_interp_marker.len)
                fatal("PT_INTERP too small for marker ({} < {})", .{ filesz, pt_interp_marker.len });
            if (try file.preadAll(interp_buf[0..pt_interp_marker.len], phdr.p_offset) < pt_interp_marker.len)
                fatal("could not read PT_INTERP content", .{});
            if (!std.mem.eql(u8, interp_buf[0..pt_interp_marker.len], pt_interp_marker))
                fatal("PT_INTERP does not contain expected marker", .{});
            pt_interp_offset = phdr.p_offset;
            break;
        }
    }
    if (pt_interp_offset == null)
        fatal("vowexe has no PT_INTERP program header", .{});

    // Find PT_DYNAMIC and the DT_NEEDED libc marker
    var dyn_off: ?u64 = null;
    var dyn_size: ?u64 = null;
    var loads: [32]struct { vaddr: u64, offset: u64, filesz: u64 } = undefined;
    var load_count: usize = 0;

    i = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        var phdr_buf: [@sizeOf(std.elf.Elf64_Phdr)]u8 align(@alignOf(std.elf.Elf64_Phdr)) = undefined;
        const phdr_file_off = ehdr.e_phoff + @as(u64, i) * ehdr.e_phentsize;
        _ = try file.preadAll(&phdr_buf, phdr_file_off);
        const phdr: *const std.elf.Elf64_Phdr = @ptrCast(&phdr_buf);
        if (phdr.p_type == std.elf.PT_DYNAMIC) {
            dyn_off = phdr.p_offset;
            dyn_size = phdr.p_filesz;
        }
        if (phdr.p_type == std.elf.PT_LOAD) {
            if (load_count >= loads.len) fatal("too many LOAD segments", .{});
            loads[load_count] = .{
                .vaddr = phdr.p_vaddr,
                .offset = phdr.p_offset,
                .filesz = phdr.p_filesz,
            };
            load_count += 1;
        }
    }
    if (dyn_off == null) fatal("vowexe has no PT_DYNAMIC", .{});

    // Find STRTAB address from dynamic section
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
    if (strtab_addr == null) fatal("vowexe has no DT_STRTAB", .{});

    // Map STRTAB vaddr to file offset
    const strtab_file_off: u64 = blk: {
        for (loads[0..load_count]) |load| {
            if (strtab_addr.? >= load.vaddr and strtab_addr.? < load.vaddr + load.filesz) {
                break :blk load.offset + (strtab_addr.? - load.vaddr);
            }
        }
        fatal("could not map DT_STRTAB vaddr to file offset", .{});
    };

    // Collect DT_NEEDED entries and find the libc marker
    var dt_needed_libc_file_offset: ?u64 = null;
    j = 0;
    while (j < dyn_entry_count) : (j += 1) {
        _ = try file.preadAll(&dyn_buf, dyn_off.? + j * @sizeOf(std.elf.Elf64_Dyn));
        const dyn: *const std.elf.Elf64_Dyn = @ptrCast(&dyn_buf);
        if (dyn.d_tag == std.elf.DT_NEEDED) {
            const str_file_off = strtab_file_off + dyn.d_val;
            // Read enough bytes to check for the marker prefix
            var name_buf: [256]u8 = undefined;
            const n = try file.preadAll(&name_buf, str_file_off);
            const name = std.mem.sliceTo(name_buf[0..n], 0);

            // Check if this is the libc marker
            const marker_prefix = "!!!VOW_DT_NEEDED_LIBC!!!";
            if (name.len >= marker_prefix.len and
                std.mem.eql(u8, name[0..marker_prefix.len], marker_prefix))
            {
                if (dt_needed_libc_file_offset != null)
                    fatal("multiple DT_NEEDED entries match the libc marker", .{});
                dt_needed_libc_file_offset = str_file_off;
            } else {
                // Unexpected DT_NEEDED — vowexe should only have the marker
                fatal("vowexe has unexpected DT_NEEDED: {s}", .{name});
            }
        }
    }
    if (dt_needed_libc_file_offset == null)
        fatal("vowexe has no DT_NEEDED entry matching the libc marker '{s}'", .{dt_needed_libc_marker[0..@min(dt_needed_libc_marker.len, 40)]});

    // Verify the full marker is present at the found offset
    {
        var marker_buf: [255]u8 = undefined;
        if (try file.preadAll(&marker_buf, dt_needed_libc_file_offset.?) < dt_needed_libc_marker.len)
            fatal("could not read full DT_NEEDED libc marker", .{});
        if (!std.mem.eql(u8, &marker_buf, dt_needed_libc_marker))
            fatal("DT_NEEDED libc marker content mismatch", .{});
    }

    // Write output: a zig file with the offset constants
    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var out_buf: [1000]u8 = undefined;
    var file_writer = out_file.writer(&out_buf);
    const w = &file_writer.interface;
    w.print("pub const pt_interp_offset: usize = {};\n", .{pt_interp_offset.?}) catch return file_writer.err.?;
    w.print("pub const dt_needed_libc_offset: usize = {};\n", .{dt_needed_libc_file_offset.?}) catch return file_writer.err.?;
    w.flush() catch return file_writer.err.?;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}
