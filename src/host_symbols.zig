//! Symbol tables of Mach-O images loaded in this process, read from memory
//! (__LINKEDIT is mapped). Debug builds keep local symbols, so every global and
//! function appears under its fully qualified Zig name — identically in the host
//! and in a generation compiled from the same tree. That shared name is the key.
const std = @import("std");

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

const DlInfo = extern struct {
    dli_fname: ?[*:0]const u8,
    dli_fbase: ?*anyopaque,
    dli_sname: ?[*:0]const u8,
    dli_saddr: ?*anyopaque,
};
extern "c" fn dladdr(address: *const anyopaque, info: *DlInfo) c_int;
extern "c" fn _dyld_get_image_header(image_index: u32) ?*const anyopaque;

pub const Image = struct {
    slide: u64, // load address − linked address
    symbols: []align(1) const Nlist64,
    strings: [*]const u8,

    pub fn open(base: *const anyopaque) ?Image {
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

    pub fn name(self: Image, symbol: Nlist64) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(self.strings + symbol.n_strx)));
    }

    pub fn address(self: Image, symbol: Nlist64) usize {
        return @intCast(symbol.n_value +% self.slide);
    }
};

pub fn isDefined(symbol: Nlist64) bool {
    return symbol.n_type & N_STAB == 0 and symbol.n_type & N_TYPE == N_SECT;
}

/// The main executable is always image 0.
pub fn hostImage() ?Image {
    const header = _dyld_get_image_header(0) orelse return null;
    return Image.open(header);
}

/// Header of whichever loaded image contains `address`.
pub fn imageBase(address: usize) ?*const anyopaque {
    var info: DlInfo = undefined;
    if (address == 0 or dladdr(@ptrFromInt(address), &info) == 0) return null;
    return info.dli_fbase;
}
