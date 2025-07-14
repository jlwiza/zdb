# ZDB - A Zig Debugger

A lightweight source-level debugger for Zig that works through compile-time preprocessing.

## Why ZDB?

I built this on a whim because any time I used a debugger with zig, whether it was lldb dgb or windbg, `std.debug.print` was just a lot more powerful. It had larger scope would work better with globals. You have to install this entire package. The setup can be a pain depending on you're OS. I wanted that same simplicity for debugging, but with the ability to pause execution and inspect program state, since there is no hidden control flow in zig, set it up for extensibility.

The approach is almost embarrassingly simple: inject a function call before each line that can pause execution and let you examine all variables in scope - local, global, and thread-local. but, what surprised me was the performance, It's was so fast in fact, at first I thought it was broken. Despite zero optimization effort. Just A lot faster than traditional debuggers that context-switch to external processes.

This started as a weekend experiment to see if Zig's comptime features could make debugging better. In most languages, building something like this would require wrestling with AST parsers, complex build system integrations, or platform-specific debugging APIs. In Zig, the first working version was under 500 lines of straightforward code.

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
.{
    .name = "your-app-name",
    .version = "0.1.0",
    .dependencies = .{
        .zdb = .{
        .url = "https://github.com/jlwiza/zdb/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "...",
        },
    },
}
```

Then add one line to your `build.zig`:

```zig
const std = @import("std");
const zdb = @import("zdb");

pub fn build(b: *std.Build) !void {
    // ... your normal build setup ...
    
    // Add debugging support
    zdb.addTo(b, exe, .{});
}
```

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
