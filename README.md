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
    var positionals_buf: [256][]const u8 = undefined;
    const positionals = opt.parse(Options, &opts, args[1..], &positionals_buf) catch |e| {
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
- **Negation with `--no-*`** - `--no-verbose` sets bool to false, `--no-config` sets optional to null
- **Value-optional flags** - `--compress` alone vs inline values like `--compress=gzip` via `flag_value`
- **Custom parsers** - `parse` in meta for octal, special formats, validation
- **Repeatable options** - `Multi(T, capacity)` for `-x foo -x bar`
- **Subcommands** - `CommandParser` for git-style and nested command CLIs
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

### `parse(T, *T, args, positionals_buf) ![][]const u8`

Parse args into struct. Returns positional arguments stored in the caller-owned `positionals_buf`.

### `CommandParser(spec) type`

Generate a parser for global options plus one or more command levels. Commands and options are defined with normal Zig structs. Global options are visible before commands; command options become visible only after their command name.

```zig
const Cli = opt.CommandParser(.{
    .name = "myapp",
    .global = GlobalOpts,
    .commands = .{
        .build = BuildOpts,
        .service = .{
            .options = ServiceOpts,
            .commands = .{
                .restart = RestartOpts,
                .status = StatusOpts,
            },
        },
    },
});

var positionals_buf: [256][]const u8 = undefined;
const parsed = try Cli.parse(args, &positionals_buf);
```

The result contains `global`, `command`, `command_name`, `command_index`, and `positionals`. The `positionals` slice uses the caller-owned buffer.

### `printUsage(T, writer) void`

Print help text to writer.

### `Multi(T, capacity) type`

Fixed-capacity list for repeatable options.

## Metadata

Optional `meta` decl for short names, help text, and special behaviors:

```zig
pub const meta = .{
    .output = .{ .short = 'o', .help = "Output file path" },
    .count = .{ .help = "Number of iterations" },  // no short
    .compress = .{ .flag_value = .on, .no_value = .off },  // see below
};
```

`meta` entries must correspond to real fields, and duplicate short options in the same option struct are compile errors. For `CommandParser`, duplicate option names/shorts on the same visible command path are compile errors; sibling commands may reuse option spellings because only the selected command path is visible.

Optional `about` decl for program info:

```zig
pub const about = .{
    .name = "myapp",
    .desc = "One-line description",
    .usage = "Usage: myapp [options] <file>...",  // optional
};
```

## Positional arguments

Options are parsed throughout the argument list, and non-option arguments are returned as positionals:

```zig
// myapp --verbose file1 --output out.txt file2
// Result: verbose=true, output="out.txt", positionals=["file1", "file2"]
```

Use `--` to explicitly end option parsing:

```zig
// myapp -v -- --not-an-option
// Result: verbose=true, positionals=["--not-an-option"]
```

## Negation with `--no-*`

The `--no-*` prefix negates options:

| Field type | `--no-flag` behavior |
|------------|---------------------|
| `bool` | sets to `false` |
| `?T` (optional) | sets to `null` |
| any (with `no_value`) | sets to `no_value` |

```zig
const Opts = struct {
    verbose: bool = true,           // --no-verbose → false
    config: ?[]const u8 = "a.conf", // --no-config → null
    compress: Compress = .auto,     // --no-compress → .off (via meta)

    pub const meta = .{
        .compress = .{ .no_value = .off },
    };
};
```

## Value-optional flags with `flag_value`

Some flags work both with and without values (`--compress` vs `--compress=gzip`). Use `flag_value` in meta. The value is optional only when written inline; `--compress file` sets the flag value and leaves `file` positional.

```zig
const Compress = enum { off, on, auto, gzip, lz4 };

const Opts = struct {
    compress: Compress = .auto,

    pub const meta = .{
        .compress = .{ .flag_value = .on, .no_value = .off },
    };
};

// Results:
// (nothing)        → .auto (default)
// --compress       → .on (flag_value)
// --compress=gzip  → .gzip (parsed)
// --no-compress    → .off (no_value)
```

## Custom parsers

For special formats like octal, use `parse` in meta. The function can return `T`, `?T`, or `!T`:

```zig
const Opts = struct {
    chmod: ?u16 = 0o755,

    pub const meta = .{
        .chmod = .{
            .parse = struct {
                fn p(val: []const u8) ?u16 {
                    return std.fmt.parseInt(u16, val, 8) catch null;
                }
            }.p,
            .help = "File mode in octal",
        },
    };
};

// --chmod 644    → 0o644
// --chmod 755    → 0o755
// --chmod 899    → error (invalid octal)
// --no-chmod     → null
```

## Subcommands

```zig
const Global = struct {
    verbose: bool = false,
    service: []const u8 = "default",

    pub const meta = .{
        .verbose = .{ .short = 'v' },
        .service = .{ .short = 's', .help = "Service name" },
    };
};

const BuildOpts = struct { release: bool = false };
const RestartOpts = struct { force: bool = false };
const StatusOpts = struct {};
const ServiceOpts = struct { name: []const u8 = "cam" };

const Cli = opt.CommandParser(.{
    .name = "myapp",
    .global = Global,
    .commands = .{
        .build = BuildOpts,
        .service = .{
            .options = ServiceOpts,
            .commands = .{
                .restart = RestartOpts,
                .status = StatusOpts,
            },
        },
    },
});

var positionals_buf: [256][]const u8 = undefined;
const parsed = try Cli.parse(args, &positionals_buf);
switch (parsed.command) {
    .build => |build| try runBuild(parsed.global, build, parsed.positionals),
    .service => |service| switch (service.command) {
        .restart => |restart| try restartService(parsed.global, service.options, restart),
        .status => |status| try serviceStatus(parsed.global, service.options, status),
    },
}
```

Command parsing is strict about option visibility: global options are visible while looking for commands, but a command's options are only visible after that command name. For nested commands, parent command options must appear before the nested command name.

```sh
myapp --service cam service --name cam restart --force
```

Command-specific options before their command name are rejected, so `myapp --force restart` is an unknown option unless `force` is global.
