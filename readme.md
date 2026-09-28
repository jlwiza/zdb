# ZDB - A Zig Debugger

A lightweight source-level debugger for Zig that works through compile-time preprocessing.

## Why ZDB?

I built this on a whim because any time I used a debugger with zig, whether it was lldb gdb or whatever. `std.debug.print` was just a lot more powerful. It had larger scope would work better with globals. It made it hard to justify using an external debugger. I wanted that same simplicity for printing zig already gave me for free and leverage that. but with the ability to pause execution and inspect program state. Since there is no hidden control flow in zig, zig made it really pretty easy.

The approach is almost embarrassingly simple: inject a function call before each line that can pause execution and let you examine all variables in scope - local, global, and thread-local. but, what surprised me was the performance, It's was so fast in fact, at first I thought it was broken. Despite zero optimization effort. It's A lot faster than traditional debuggers that context-switch to external processes.

This started as a weekend experiment to see if Zig's comptime features could make debugging better. In most languages, building something like this would require wrestling with AST parsers, complex build system integrations, or platform-specific debugging APIs. In Zig, the first working prototype was under 500 lines of straightforward code.

## Features

- **Simple breakpoints**: Just add `_ = .breakpoint;` anywhere in your code
- **Step debugging**: Step through code line by line with variable inspection
- **Clear Well formed output**: Struct arrays display as tables, not walls of text
- **Multi-file support**: Automatically handles imports and project structure
- **Zero dependencies**: Pure Zig, no external tools required
- **Build system debugging**: Debug your `build.zig` with the same tools

## Installation

Add ZDB to your `build.zig.zon`:

```zig
.dependencies = .{
        .zdb = .{
            .url = "https://github.com/jlwiza/zdb/archive/refs/tags/v0.1.5.tar.gz",
            .hash = "zdb-0.1.1-BcQz1SroAAA6PHmFnv4pMKTtQOHFqqnwxyEkv6__8pv1",
        },
},
```

Add to your build.zig:

```zig
const std = @import("std");
// Step 1: at the top of you're build add the build support functions
const zdb = @import("zdb");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = makeExecutable(b, "my-app", target, optimize);
    b.installArtifact(exe);
    const debug_exe = makeExecutable(b, "my-app-debug", target, optimize);
    zdb.addTo(b, debug_exe, .{
        .enable_live_mode = true,
        .discover_breakpoint = true,
        // Optional: instrument only selected source-relative paths.
        // Leave empty to instrument the complete source tree.
        .include = &.{"main.zig"},
    });
}

fn makeExecutable(b: *std.Build, name: []const u8,
    target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Add all application imports, native sources and link settings here.
    return b.addExecutable(.{ .name = name, .root_module = mod });
}
```

`addTo` instruments the supplied dedicated executable in place, after its
configuration is complete. Give it its own root module; do not pass the normal
executable. Source files and adjacent assets are staged in the build cache.
`zig build debug-check` compiles and links without launching the application.
Build-script instrumentation remains a separate `debug-build` tool.

When a selected file contains `_ = .breakpoint;`, step and live hooks are
injected only from that marker onward in its function. Other functions in that
file stay ordinary code unless they contain their own marker. Marker-free files
retain whole-function instrumentation for external live breakpoints. For large
applications, use `include` to target the file or directory under investigation.
An empty `include` list retains whole-tree source selection.
With `discover_breakpoint = true`, the lexicographically first source file
containing a breakpoint marker is selected automatically. An explicit build
option can still provide an exact `include` selection.

### Reloadable debugger sidecar

Consumers may set `enable_sidecar = true` in `zdb.addTo`. The debug run then
loads a versioned dynamic library at the first breakpoint. Enter `r` while
paused to close it, snapshot the newly built file under a unique name, load it,
check its ABI version, and call its pause handler. Rebuild the installed file
with `zig build debug-sidecar -Dzdb-sidecar-generation=<n>`.

The preprocessor builds the initial handoff frame directly from lexical scope.
Parameters and `const` locals are stable copies; lexical `var` locals are mutable
pointers. The versioned ABI describes each name, Zig type name, storage kind,
address and size. `continue_execution` is honored; failure and function-return
outcomes leave the host paused because this boundary cannot perform them safely.

The instrumented executable still owns post-marker Zig control flow. This does
not yet transform arbitrary statements into a dylib continuation, edit arbitrary
types, or make step-into reloadable. Those require generated continuation entry
points and stricter layout/lifetime validation on top of this frame ABI.

## Usage

Add breakpoints to your code:

```zig
pub fn main() !void {
    var x: i32 = 42;
    var name = "Zig";
    
    _ = .breakpoint;  // Pause here
    
    x += 10;
    processData(&x, name);
}
```

The marker is case-sensitive: spell it `.breakpoint`.

Run with debugging:

```bash
zig build debug
```

When you hit a breakpoint:
- Type variable names to inspect them
- Use `s` to enable step mode
- Use `c` to continue execution
- Array slicing: `data[10..20]` to see a range
- Paging: `n`/`p` for next/previous page of large arrays

## Philosophy

ZDB is an experiment in making debugging as simple as print statements but as powerful as traditional debuggers.

The goal is a debugger that's:
- Easy to extend - want custom visualizations? Add them.
- Pleasant to look at - data should be readable

This is still very much exploratory. I have ideas about what debugging could be - watch expressions that actually work, memory visualization that makes sense, time-travel debugging that's practical. ZDB is the foundation for experimenting with these ideas.

## Technical Approach

ZDB works by preprocessing your Zig source code before compilation. When you run `zig build debug`, it:

1. Scans your source for breakpoint markers
2. Injects debugging calls that track all variables in scope
3. Compiles the instrumented code with the ZDB runtime
4. Runs your program with interactive debugging enabled

The preprocessor understands Zig's syntax well enough to track variable scopes, handle imports, and maintain correct behavior while adding debugging capabilities.
### Neovim (optional)

The plugin lives in `lua/zdb.lua`; with lazy.nvim:

```lua
{ 'jlwiza/zdb', config = function() require('zdb').setup() end }
```

Options: `gutter_click = true` toggles breakpoints by clicking a .zig gutter (off by
default — it maps `<LeftMouse>` globally). `keys = { next = '<F10>', ... }` remaps,
`keys = { quit = false }` skips one, `keys = false` maps none. `:Zdb` opens the panel.

## How it talks

The app and any front end share four files in the project root: `zdb_breakpoints.zon`
(breakpoints, written by the editor, polled by the app), `zdb_state.txt` (stop
location + locals, written by the app), `zdb_command.txt` (one command per write:
`continue`, `step`, `next`, `out`, `quit`, or an inspect path like `self.frames[3]`),
and `zdb_output.txt` (the answer). Any editor can drive zdb through these files.

## Limits

- Only code in the executable's own source tree is instrumented; files in other
  Zig modules (e.g. a library module your main imports) run uninstrumented, and
  their globals are duplicated inside generations.
- Functions with `comptime`/`anytype` params can't be stepped into through a generation.
- Step state is global: other threads running instrumented code can trip a step.
- An error crossing a generation as `anyerror` can't be translated and panics with a message.
## Contributing

This is an experimental project and I welcome ideas, bug reports, and contributions. The codebase is intentionally small and hackable. If you've ever been frustrated by debuggers and have ideas for improvement, this is a good place to experiment.
 you can use `zig build test-debug` to debug the test file in the repo to experiment and build on.

## Future Ideas

- **Watch expressions**: `@watch(x > 100)` to break when conditions are met
- **Time-travel debugging**: Record and replay execution
- **Memory visualization**: See how your data structures actually layout in memory
- **Custom formatters**: Define how your types display in the debugger
- **Remote debugging**: Debug programs running on other machines
- **Hot reload**: Modify code while debugging

## License

MIT License - see LICENSE file for details.

Use it, hack it, ship it. No warranties, but plenty of enthusiasm for making debugging better.
