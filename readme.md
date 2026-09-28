# ZDB - A Zig Debugger

A lightweight source-level debugger for Zig that works through compile-time preprocessing.

**Requirements:** Zig 0.16. Breakpoints and stepping are plain Zig; hot generations
(step into anything, on-demand inspection) currently need macOS on Apple Silicon.

## Why ZDB?

I built this on a whim because any time I used a debugger with Zig, whether it was lldb, gdb or whatever, `std.debug.print` was just a lot more powerful. It had larger scope and worked better with globals. It made it hard to justify using an external debugger. I wanted the same simplicity printing already gave me for free, but with the ability to pause execution and inspect program state. Since there is no hidden control flow in Zig, Zig made it pretty easy.

The approach is almost embarrassingly simple: inject a function call before each line that can pause execution and let you examine the variables in scope. What surprised me was the performance. It was so fast that at first I thought it was broken, despite zero optimization effort. It's a lot faster than traditional debuggers that context-switch to external processes.

This started as a weekend experiment to see if Zig's comptime features could make debugging better. In most languages, building something like this would require wrestling with AST parsers, complex build system integrations, or platform-specific debugging APIs. In Zig, the first working prototype was under 500 lines of straightforward code.

## Features

- **Simple breakpoints**: Just add `_ = .breakpoint;` anywhere in your code, or toggle them from your editor while the app runs
- **Step debugging**: step in, step over and step out, by real stack depth
- **Hot generations**: step into any function — zdb compiles it on the spot and swaps it in, no restart
- **On-demand inspection**: type or click any path (`self.frames[3].pos`); a printer is built for exactly that type, then cached
- **Clear, well-formed output**: structs one field per line, arrays and slices as pageable rows
- **Multi-file support**: automatically handles imports and project structure
- **Build system debugging**: debug your `build.zig` with the same tools

## Installation

Add ZDB to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/jlwiza/zdb
```

Add to your `build.zig`:

```zig
const std = @import("std");
const zdb = @import("zdb");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = makeExecutable(b, "my-app", target, optimize);
    b.installArtifact(exe);

    const debug_exe = makeExecutable(b, "my-app-debug", target, optimize);
    zdb.addTo(b, debug_exe, .{
        .enable_step_mode = true,
        .enable_live_mode = true,
        .discover_breakpoint = true, // the first file with `_ = .breakpoint;`
        .enable_generations = true, // step into anything; inspect on demand (macOS arm64)
        // Optional: instrument only selected source-relative paths.
        // .include = &.{"main.zig"},
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

- `zig build debug` — build and run with the debugger. Always launch this way:
  generations need the environment this step sets.
- `zig build debug-check` — compile and link without launching.

When a selected file contains `_ = .breakpoint;`, hooks are injected from that
marker onward in its function; other functions stay ordinary code. With
`discover_breakpoint = true`, the lexicographically first source file containing
a marker is selected automatically. `include` targets a file or directory explicitly.

## Usage

Add a breakpoint:

```zig
pub fn main() !void {
    var x: i32 = 42;
    const name = "Zig";

    _ = .breakpoint; // pause here

    x += 10;
    processData(&x, name);
}
```

The marker is case-sensitive: spell it `.breakpoint`. Then:

```bash
zig build debug
```

When paused:

| Command | Does |
|---|---|
| `c` | continue |
| `s` | step in — into the next function called, building it if needed |
| `n` | next — step over calls, stop at this depth or shallower |
| `o` | out — run until this function returns |
| `v` | list locals |
| `r` | reload the debugger sidecar |
| `name`, `name.field[2]` | inspect a local or any path on it |
| `data[10..20]` | a range of an array or slice |

## Hot generations

With `enable_generations = true`, the initial debug build instruments exactly one
function and gives every other function a tiny redirect wrapper. As you work,
zdb builds small dylibs ("generations") in the background:

- **A ring around where you are.** Callers first, then callees, two hops out. It
  recenters whenever you stop in a different function, so the next step is usually
  ready before you ask for it.
- **Step into anything.** If a step enters a function no generation covers yet, zdb
  builds it on the spot and waits: it stops, or it tells you why it can't.
- **Inspection on demand.** The first look at a type and path compiles a printer for
  exactly that. Each one also includes a *level* printer, so clicking one field
  deeper is instant, and the level below that is prefetched quietly.

Generated code shares the host's globals (matched by symbol name) and forwards
breakpoints and step state to the host, so there is one program state, not two.
Pointers are probed before they're followed: a stale or wrong path prints why
instead of crashing.

## Neovim (optional)

The plugin lives in `lua/zdb.lua`; with lazy.nvim:

```lua
{ 'jlwiza/zdb', config = function() require('zdb').setup() end }
```

Options: `gutter_click = true` toggles breakpoints by clicking a .zig gutter (off by
default, since it maps `<LeftMouse>` globally). `keys = { next = '<F10>', ... }` remaps,
`keys = { quit = false }` skips one, `keys = false` maps none. `:Zdb` opens the panel.
In the panel, click a field or `[index]` to go deeper, and use `[` / `]` to page.

## How it talks

The app and any front end share four files in the project root: `zdb_breakpoints.zon`
(breakpoints, written by the editor, polled by the app), `zdb_state.txt` (stop
location + locals, written by the app), `zdb_command.txt` (one command per write:
`continue`, `step`, `next`, `out`, `quit`, or an inspect path like `self.frames[3]`),
and `zdb_output.txt` (the answer). Any editor can drive zdb through these files.
Add the last three to your `.gitignore`.

## Limits

- Only code in the executable's own source tree is instrumented; files in other
  Zig modules (e.g. a library module your main imports) run uninstrumented, and
  their globals are duplicated inside generations.
- Functions with `comptime`/`anytype` params can't be stepped into through a generation.
- Step state is global: other threads running instrumented code can trip a step.
- An error crossing a generation as `anyerror` can't be translated and panics with a message.

## Internals: the reloadable sidecar

`enable_sidecar = true` loads a versioned dynamic library at the first breakpoint;
`r` while paused reloads it (`zig build debug-sidecar -Dzdb-sidecar-generation=<n>`).
It predates generations and is kept as a debugger-behavior reload boundary.

## Philosophy

ZDB is an experiment in making debugging as simple as print statements but as powerful as traditional debuggers.

The goal is a debugger that's:
- Easy to extend - want custom visualizations? Add them.
- Pleasant to look at - data should be readable

This is still very much exploratory. I have ideas about what debugging could be - watch expressions that actually work, memory visualization that makes sense, time-travel debugging that's practical. ZDB is the foundation for experimenting with these ideas.

## Technical Approach

ZDB works by preprocessing your Zig source code before compilation. When you run `zig build debug`, it:

1. Scans your source for breakpoint markers
2. Injects debugging calls that capture the locals in scope
3. Wraps every function so a later generation can take it over
4. Compiles the instrumented code with the ZDB runtime
5. Runs your program with interactive debugging enabled

The preprocessor understands Zig's syntax well enough to track variable scopes, handle imports, and maintain correct behavior while adding debugging capabilities. The Zig compiler does the rest: `@TypeOf` and comptime reflection replace the debug-info parsing a traditional debugger needs.

## Contributing

This is an experimental project and I welcome ideas, bug reports, and contributions. The codebase is intentionally small and hackable. If you've ever been frustrated by debuggers and have ideas for improvement, this is a good place to experiment.
You can use `zig build test-debug` to debug the test file in the repo to experiment and build on.

## Future Ideas

- **Call stack in the panel**: every frame, clickable
- **Watch expressions**: `@watch(x > 100)` to break when conditions are met
- **Time-travel debugging**: Record and replay execution
- **Memory visualization**: See how your data structures actually layout in memory
- **Custom formatters**: Define how your types display in the debugger
- **Remote debugging**: Debug programs running on other machines
- **Linux support** for generations (an ELF symbol reader)

## License

MIT License - see LICENSE file for details.

Use it, hack it, ship it. No warranties, but plenty of enthusiasm for making debugging better.
