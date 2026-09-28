pub const version: u32 = 3;

/// The permanent host-to-continuation vocabulary. Every hooked local crosses
/// as a pointer into the paused frame; storage says whether a reader may write.
pub const LocalStorage = enum(u8) {
    copied_value,
    mutable_pointer,
    read_only_pointer, // const local; bytes_ptr was @constCast — never write through it
};

pub const LocalRef = extern struct {
    name_ptr: [*]const u8,
    name_len: usize,
    type_name_ptr: [*]const u8,
    type_name_len: usize,
    storage: LocalStorage,
    bytes_ptr: [*]u8,
    bytes_len: usize, // 0 ⇒ comptime-only or zero-sized; nothing to read
};

pub const ContinuationOutcome = enum(u8) {
    remain_paused,
    continue_execution,
    return_from_function,
    fail,
};

pub const PauseEvent = extern struct {
    function_name_ptr: [*]const u8,
    function_name_len: usize,
    breakpoint_count: usize,
    locals_ptr: ?[*]LocalRef,
    locals_len: usize,
};

pub const PauseReply = extern struct {
    generation: u64,
    message_len: usize,
    message: [128]u8,
    outcome: ContinuationOutcome,
};

pub const VersionFn = *const fn () callconv(.c) u32;
pub const OnPauseFn = *const fn (*const PauseEvent, *PauseReply) callconv(.c) void;
pub const ContinueFn = *const fn (*const PauseEvent) callconv(.c) ContinuationOutcome;
