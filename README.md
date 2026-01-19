# opt.zig

Declarative CLI option parsing for Zig. Define options as a struct, get parsing and help generation for free.

## Usage

```zig
const opt = @import("opt");

const Options = struct {
    output: []const u8 = "out.txt",
    port: u16 = 8080,
    verbose: bool = false,

    pub const meta = .{
        .output = .{ .short = 'o', .help = "Output file" },
        .port = .{ .short = 'p', .help = "Server port" },
        .verbose = .{ .short = 'v', .help = "Verbose output" },
    };
    pub const about = .{ .name = "myapp", .desc = "Does useful things" };
};

pub fn main() !void {
    const args = std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var opts = Options{};
    const positionals = opt.parse(Options, &opts, args[1..]) catch |e| {
        if (e == error.Help) opt.printUsage(Options, stdout);
        return e;
    };

    // opts.port, opts.verbose, etc are now populated
    // positionals contains remaining non-option arguments
}
```

## Features

- **Struct-based definition** - fields become options, defaults become defaults
- **Auto-generated help** - from field names, types, and metadata
- **Zero allocations** - everything is comptime or stack-allocated
- **Short and long options** - `-v` and `--verbose`
- **Inline values** - `-p8080` and `--port=8080`
- **Repeatable options** - `Multi(T, capacity)` for `-x foo -x bar`
- **Subcommands** - `parseMerged` for git-style CLIs
- **Type support** - strings, integers, bools, enums, optionals

## Installation

Add to `build.zig.zon`:

```zig
.dependencies = .{
    .opt = .{
        .url = "https://github.com/piranha/opt.zig/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
},
```

Then in `build.zig`:

```zig
const opt = b.dependency("opt", .{});
exe.root_module.addImport("opt", opt.module("opt"));
```

## API

### `parse(T, *T, args) ![][]const u8`

Parse args into struct. Returns positional arguments.

### `parseMerged(G, S, *G, *S, args) ![][]const u8`

Parse into two structs (global + subcommand options). First positional is subcommand name.

### `findSubcmd(E, args) ?E`

Find subcommand name in args, return as enum value.

### `printUsage(T, writer) void`

Print help text to writer.

### `printMergedUsage(G, S, writer) void`

Print combined help for global + subcommand options.

### `Multi(T, capacity) type`

Fixed-capacity list for repeatable options.

## Metadata

Optional `meta` decl for short names and help text:

```zig
pub const meta = .{
    .output = .{ .short = 'o', .help = "Output file path" },
    .count = .{ .help = "Number of iterations" },  // no short
};
```

Optional `about` decl for program info:

```zig
pub const about = .{
    .name = "myapp",
    .desc = "One-line description",
    .usage = "Usage: myapp [options] <file>...",  // optional
};
```

## Subcommands

```zig
const Cmd = enum { build, test, run };
const Global = struct { verbose: bool = false };
const BuildOpts = struct { release: bool = false };

const cmd = opt.findSubcmd(Cmd, args) orelse return error.NoCommand;
switch (cmd) {
    .build => {
        var global = Global{};
        var build_opts = BuildOpts{};
        const rest = try opt.parseMerged(Global, BuildOpts, &global, &build_opts, args);
    },
    // ...
}
```
