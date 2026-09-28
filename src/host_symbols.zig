//! Defined function/object symbols for images loaded in this process.
//!
//! Mach-O keeps `__LINKEDIT` mapped, so macOS reads its symbol table directly
//! from memory. Linux does not map the full `.symtab`; its implementation finds
//! the image with `dladdr`, reads the ELF64 file, and retains debugger-lifetime
//! views of `.symtab` and its linked `.strtab`.
const std = @import("std");
const builtin = @import("builtin");

const DlInfo = extern struct {
    dli_fname: ?[*:0]const u8,
    dli_fbase: ?*anyopaque,
    dli_sname: ?[*:0]const u8,
    dli_saddr: ?*anyopaque,
};
extern "c" fn dladdr(address: *const anyopaque, info: *DlInfo) c_int;

const MachHeader64 = extern struct { magic: u32, cputype: i32, cpusubtype: i32, filetype: u32, ncmds: u32, sizeofcmds: u32, flags: u32, reserved: u32 };
const LoadCommand = extern struct { cmd: u32, cmdsize: u32 };
const SegmentCommand64 = extern struct { cmd: u32, cmdsize: u32, segname: [16]u8, vmaddr: u64, vmsize: u64, fileoff: u64, filesize: u64, maxprot: i32, initprot: i32, nsects: u32, flags: u32 };
const SymtabCommand = extern struct { cmd: u32, cmdsize: u32, symoff: u32, nsyms: u32, stroff: u32, strsize: u32 };
pub const Nlist64 = extern struct { n_strx: u32, n_type: u8, n_sect: u8, n_desc: u16, n_value: u64 };

const MH_MAGIC_64: u32 = 0xfeedfacf;
const LC_SEGMENT_64: u32 = 0x19;
const LC_SYMTAB: u32 = 0x2;
const N_STAB: u8 = 0xe0; // debugger stab entries, not definitions
const N_TYPE: u8 = 0x0e;
const N_SECT: u8 = 0x0e; // defined in a section of this image

extern "c" fn _dyld_get_image_header(image_index: u32) ?*const anyopaque;

const MachImage = struct {
    slide: u64, // load address − linked address
    symbols: []align(1) const Nlist64,
    strings: [*]const u8,

    pub fn open(base: *const anyopaque) ?MachImage {
        const header: *align(1) const MachHeader64 = @ptrCast(base);
        if (header.magic != MH_MAGIC_64) return null;
        var text_vmaddr: ?u64 = null;
        var linkedit: ?*align(1) const SegmentCommand64 = null;
        var symtab: ?*align(1) const SymtabCommand = null;
        var cursor: [*]const u8 = @as([*]const u8, @ptrCast(base)) + @sizeOf(MachHeader64);
        for (0..header.ncmds) |_| {
            const command: *align(1) const LoadCommand = @ptrCast(cursor);
            if (command.cmd == LC_SEGMENT_64) {
                const segment: *align(1) const SegmentCommand64 = @ptrCast(cursor);
                const segment_name = std.mem.sliceTo(&segment.segname, 0);
                if (std.mem.eql(u8, segment_name, "__TEXT")) text_vmaddr = segment.vmaddr;
                if (std.mem.eql(u8, segment_name, "__LINKEDIT")) linkedit = segment;
            } else if (command.cmd == LC_SYMTAB) {
                symtab = @ptrCast(cursor);
            }
            cursor += command.cmdsize;
        }
        const text = text_vmaddr orelse return null;
        const link = linkedit orelse return null;
        const table = symtab orelse return null;
        const slide = @as(u64, @intFromPtr(base)) -% text;
        const linkedit_base = link.vmaddr +% slide -% link.fileoff; // file offsets in __LINKEDIT → mapped addresses
        const symbols: [*]align(1) const Nlist64 = @ptrFromInt(linkedit_base + table.symoff);
        return .{
            .slide = slide,
            .symbols = symbols[0..table.nsyms],
            .strings = @ptrFromInt(linkedit_base + table.stroff),
        };
    }

    pub fn name(self: MachImage, symbol: Nlist64) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(self.strings + symbol.n_strx)));
    }

    pub fn address(self: MachImage, symbol: Nlist64) usize {
        return @intCast(symbol.n_value +% self.slide);
    }
};

fn machDefined(symbol: Nlist64) bool {
    return symbol.n_type & N_STAB == 0 and symbol.n_type & N_TYPE == N_SECT;
}

const ElfSymbol = std.elf.Elf64_Sym;

const ElfImage = struct {
    base: usize,
    symbols: []align(1) const ElfSymbol,
    strings: []const u8,

    pub fn open(base: *const anyopaque) ?ElfImage {
        var info: DlInfo = undefined;
        if (dladdr(base, &info) == 0) return null;
        const path = info.dli_fname orelse return null;
        const load_base = if (info.dli_fbase) |pointer| @intFromPtr(pointer) else 0;
        return openFile(std.mem.span(path), load_base);
    }

    fn openFile(path: []const u8, base: usize) ?ElfImage {
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, std.heap.page_allocator, .limited(2 * 1024 * 1024 * 1024)) catch return null;
        const image = parse(bytes, base) orelse {
            std.heap.page_allocator.free(bytes);
            return null;
        };
        // Intentionally retained: Image views are cached for the debugger's
        // lifetime and every symbol/string slice points into this allocation.
        return image;
    }

    fn parse(bytes: []const u8, base: usize) ?ElfImage {
        const header = structAt(std.elf.Elf64_Ehdr, bytes, 0) orelse return null;
        if (!std.mem.eql(u8, header.e_ident[0..4], "\x7fELF")) return null;
        if (header.e_ident[std.elf.EI.CLASS] != std.elf.ELFCLASS64) return null;
        if (header.e_ident[std.elf.EI.DATA] != std.elf.ELFDATA2LSB) return null;
        if (header.e_shentsize != @sizeOf(std.elf.Elf64_Shdr) or header.e_shnum == 0) return null;

        const section_bytes = range(bytes, header.e_shoff, @as(u64, header.e_shnum) * @sizeOf(std.elf.Elf64_Shdr)) orelse return null;
        const section_ptr: [*]align(1) const std.elf.Elf64_Shdr = @ptrCast(section_bytes.ptr);
        const sections = section_ptr[0..header.e_shnum];
        if (header.e_shstrndx >= sections.len) return null;
        const section_names_header = sections[header.e_shstrndx];
        const section_names = range(bytes, section_names_header.sh_offset, section_names_header.sh_size) orelse return null;

        var symbol_header: ?std.elf.Elf64_Shdr = null;
        var string_header: ?std.elf.Elf64_Shdr = null;
        for (sections) |section| {
            const section_name = stringAt(section_names, section.sh_name) orelse continue;
            if (section.sh_type == std.elf.SHT_SYMTAB and std.mem.eql(u8, section_name, ".symtab")) symbol_header = section;
            if (section.sh_type == std.elf.SHT_STRTAB and std.mem.eql(u8, section_name, ".strtab")) string_header = section;
        }
        const symtab = symbol_header orelse return null;
        var strtab = string_header orelse return null;
        if (symtab.sh_link < sections.len) {
            const linked = sections[symtab.sh_link];
            if (linked.sh_type == std.elf.SHT_STRTAB) strtab = linked;
        }
        if (symtab.sh_entsize != @sizeOf(ElfSymbol) or symtab.sh_size % @sizeOf(ElfSymbol) != 0) return null;
        const raw_symbols = range(bytes, symtab.sh_offset, symtab.sh_size) orelse return null;
        const strings = range(bytes, strtab.sh_offset, strtab.sh_size) orelse return null;
        const symbol_ptr: [*]align(1) const ElfSymbol = @ptrCast(raw_symbols.ptr);
        const all_symbols = symbol_ptr[0 .. raw_symbols.len / @sizeOf(ElfSymbol)];
        var defined: std.ArrayList(ElfSymbol) = .empty;
        for (all_symbols) |symbol| {
            if (elfDefined(symbol)) defined.append(std.heap.page_allocator, symbol) catch return null;
        }
        const symbols = defined.toOwnedSlice(std.heap.page_allocator) catch return null;
        return .{ .base = base, .symbols = symbols, .strings = strings };
    }

    pub fn name(self: ElfImage, symbol: ElfSymbol) []const u8 {
        return stringAt(self.strings, symbol.st_name) orelse "";
    }

    pub fn address(self: ElfImage, symbol: ElfSymbol) usize {
        return self.base +% @as(usize, @intCast(symbol.st_value));
    }
};

fn elfDefined(symbol: ElfSymbol) bool {
    const symbol_type = symbol.st_type();
    return symbol.st_shndx != 0 and (symbol_type == 1 or symbol_type == 2);
}

fn structAt(comptime T: type, bytes: []const u8, offset: u64) ?*align(1) const T {
    const view = range(bytes, offset, @sizeOf(T)) orelse return null;
    return @ptrCast(view.ptr);
}

fn range(bytes: []const u8, offset: u64, size: u64) ?[]const u8 {
    const start = std.math.cast(usize, offset) orelse return null;
    const length = std.math.cast(usize, size) orelse return null;
    const end = std.math.add(usize, start, length) catch return null;
    if (end > bytes.len) return null;
    return bytes[start..end];
}

fn stringAt(strings: []const u8, offset: usize) ?[]const u8 {
    if (offset >= strings.len) return null;
    const tail = strings[offset..];
    const end = std.mem.indexOfScalar(u8, tail, 0) orelse return null;
    return tail[0..end];
}

const UnsupportedSymbol = extern struct { unused: u8 };
const UnsupportedImage = struct {
    symbols: []const UnsupportedSymbol = &.{},
    pub fn open(_: *const anyopaque) ?UnsupportedImage {
        return null;
    }
    pub fn name(_: UnsupportedImage, _: UnsupportedSymbol) []const u8 {
        return "";
    }
    pub fn address(_: UnsupportedImage, _: UnsupportedSymbol) usize {
        return 0;
    }
};

pub const Symbol = switch (builtin.os.tag) {
    .macos => Nlist64,
    .linux => ElfSymbol,
    else => UnsupportedSymbol,
};

pub const Image = switch (builtin.os.tag) {
    .macos => MachImage,
    .linux => ElfImage,
    else => UnsupportedImage,
};

pub fn isDefined(symbol: Symbol) bool {
    return switch (builtin.os.tag) {
        .macos => machDefined(symbol),
        .linux => elfDefined(symbol),
        else => false,
    };
}

pub fn hostImage() ?Image {
    return switch (builtin.os.tag) {
        .macos => MachImage.open(_dyld_get_image_header(0) orelse return null),
        .linux => blk: {
            var info: DlInfo = undefined;
            if (dladdr(@ptrCast(&hostImage), &info) == 0) break :blk null;
            const base = if (info.dli_fbase) |pointer| @intFromPtr(pointer) else 0;
            break :blk ElfImage.openFile("/proc/self/exe", base);
        },
        else => null,
    };
}

pub fn imageBase(address: usize) ?*const anyopaque {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return null;
    var info: DlInfo = undefined;
    if (address == 0 or dladdr(@ptrFromInt(address), &info) == 0) return null;
    return info.dli_fbase;
}

test "ELF64 reads and relocates defined object/function symbols" {
    const ehdr_size = @sizeOf(std.elf.Elf64_Ehdr);
    const shdr_size = @sizeOf(std.elf.Elf64_Shdr);
    const sym_size = @sizeOf(ElfSymbol);
    const shoff = ehdr_size;
    const shstr_off = shoff + 4 * shdr_size;
    const shstr = "\x00.shstrtab\x00.symtab\x00.strtab\x00";
    const symoff = std.mem.alignForward(usize, shstr_off + shstr.len, @alignOf(ElfSymbol));
    const stroff = symoff + 3 * sym_size;
    const strtab = "\x00ignored\x00object\x00function\x00";
    var storage: [1024]u8 = @splat(0);
    const bytes = storage[0 .. stroff + strtab.len];

    const header: *align(1) std.elf.Elf64_Ehdr = @ptrCast(bytes.ptr);
    header.* = std.mem.zeroes(std.elf.Elf64_Ehdr);
    @memcpy(header.e_ident[0..4], "\x7fELF");
    header.e_ident[std.elf.EI.CLASS] = std.elf.ELFCLASS64;
    header.e_ident[std.elf.EI.DATA] = std.elf.ELFDATA2LSB;
    header.e_shoff = shoff;
    header.e_shentsize = shdr_size;
    header.e_shnum = 4;
    header.e_shstrndx = 1;

    const section_ptr: [*]align(1) std.elf.Elf64_Shdr = @ptrCast(bytes[shoff..].ptr);
    const sections = section_ptr[0..4];
    @memset(std.mem.sliceAsBytes(sections), 0);
    sections[1].sh_name = 1;
    sections[1].sh_type = std.elf.SHT_STRTAB;
    sections[1].sh_offset = shstr_off;
    sections[1].sh_size = shstr.len;
    sections[2].sh_name = 11;
    sections[2].sh_type = std.elf.SHT_SYMTAB;
    sections[2].sh_offset = symoff;
    sections[2].sh_size = 3 * sym_size;
    sections[2].sh_link = 3;
    sections[2].sh_entsize = sym_size;
    sections[3].sh_name = 19;
    sections[3].sh_type = std.elf.SHT_STRTAB;
    sections[3].sh_offset = stroff;
    sections[3].sh_size = strtab.len;
    @memcpy(bytes[shstr_off..][0..shstr.len], shstr);
    @memcpy(bytes[stroff..][0..strtab.len], strtab);

    const symbol_ptr: [*]align(1) ElfSymbol = @ptrCast(bytes[symoff..].ptr);
    const symbols = symbol_ptr[0..3];
    @memset(std.mem.sliceAsBytes(symbols), 0);
    symbols[0].st_name = 1;
    symbols[0].st_info = 1;
    symbols[0].st_shndx = 0;
    symbols[1].st_name = 9;
    symbols[1].st_info = 1;
    symbols[1].st_shndx = 1;
    symbols[1].st_value = 0x10;
    symbols[2].st_name = 16;
    symbols[2].st_info = 2;
    symbols[2].st_shndx = 1;
    symbols[2].st_value = 0x20;

    const image = ElfImage.parse(bytes, 0x1000) orelse return error.InvalidTestElf;
    try std.testing.expectEqual(@as(usize, 2), image.symbols.len);
    try std.testing.expectEqualStrings("object", image.name(image.symbols[0]));
    try std.testing.expectEqualStrings("function", image.name(image.symbols[1]));
    try std.testing.expectEqual(@as(usize, 0x1010), image.address(image.symbols[0]));
    try std.testing.expectEqual(@as(usize, 0x1020), image.address(image.symbols[1]));
}
