//! Declarative CLI option parsing for Zig
//!
//! Define options as a struct with defaults and optional metadata:
//!
//!   const Options = struct {
//!       interface: []const u8 = "wlan0",
//!       port: u16 = 5600,
//!       verbose: bool = false,
//!
//!       pub const meta = .{
//!           .interface = .{ .short = 'i', .help = "Network interface" },
//!           .port = .{ .short = 'p', .help = "UDP port" },
//!           .verbose = .{ .short = 'v', .help = "Verbose output" },
//!       };
//!       pub const about = .{ .name = "myapp", .desc = "Does things" };
//!   };
//!
//!   var opts = Options{};
//!   const positionals = opt.parse(Options, &opts, args) catch |e| {
//!       if (e == error.Help) opt.printUsage(Options, stdout);
//!       return e;
//!   };

const std = @import("std");

pub const ParseError = error{
    MissingValue,
    InvalidValue,
    UnknownOption,
    Help,
    OutOfMemory,
    TooManyValues,
};

/// Parse args into opts struct. Returns remaining positional args.
pub fn parse(comptime T: type, opts: *T, args: []const []const u8) ParseError![]const []const u8 {
    return parseInternal(T, void, opts, undefined, args, false);
}

/// Parse args into two structs (global + subcommand). Options can appear anywhere.
/// First positional is subcommand name (skipped). Returns remaining positional args.
pub fn parseMerged(
    comptime G: type,
    comptime S: type,
    global: *G,
    sub: *S,
    args: []const []const u8,
) ParseError![]const []const u8 {
    return parseInternal(G, S, global, sub, args, true);
}

fn parseInternal(
    comptime G: type,
    comptime S: type,
    global: *G,
    sub: anytype,
    args: []const []const u8,
    comptime merged: bool,
) ParseError![]const []const u8 {
    const g_fields = @typeInfo(G).@"struct".fields;
    const g_has_meta = @hasDecl(G, "meta");
    const s_fields = if (S != void) @typeInfo(S).@"struct".fields else &[_]std.builtin.Type.StructField{};
    const s_has_meta = if (S != void) @hasDecl(S, "meta") else false;

    var i: usize = 0;
    var found_subcmd = false;
    var positional_count: usize = 0;
    var stop_parsing_options = false;

    // First pass: count positionals and parse options
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len == 0) continue;

        // After --, everything is positional
        if (stop_parsing_options) {
            positional_count += 1;
            continue;
        }

        // Help flag
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return ParseError.Help;
        }

        // End of options marker - everything after is positional
        if (std.mem.eql(u8, arg, "--")) {
            stop_parsing_options = true;
            continue;
        }

        // Long option: --name or --name=value or --no-name
        if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') {
            const rest = arg[2..];
            var name: []const u8 = rest;
            var inline_value: ?[]const u8 = null;
            var is_negated = false;

            // Check for --no-* prefix
            if (rest.len > 3 and std.mem.startsWith(u8, rest, "no-")) {
                is_negated = true;
                name = rest[3..];
            }

            if (std.mem.indexOf(u8, name, "=")) |eq| {
                inline_value = name[eq + 1 ..];
                name = name[0..eq];
            }

            var name_buf: [64]u8 = undefined;
            const norm_name = normalizeName(name, &name_buf);

            // Try global first, then subcommand
            const g_result = if (is_negated)
                setFieldNegated(G, g_fields, g_has_meta, global, norm_name)
            else
                setField(G, g_fields, g_has_meta, global, norm_name, inline_value, args, &i);
            switch (g_result) {
                .ok => continue,
                .missing_value => return ParseError.MissingValue,
                .invalid_value => return ParseError.InvalidValue,
                .not_found => {},
            }
            if (merged and S != void) {
                const s_result = if (is_negated)
                    setFieldNegated(S, s_fields, s_has_meta, sub, norm_name)
                else
                    setField(S, s_fields, s_has_meta, sub, norm_name, inline_value, args, &i);
                switch (s_result) {
                    .ok => continue,
                    .missing_value => return ParseError.MissingValue,
                    .invalid_value => return ParseError.InvalidValue,
                    .not_found => {},
                }
            }
            // In merged mode with empty subcommand struct, skip unknown options
            if (merged and s_fields.len == 0) {
                if (inline_value == null and i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-') {
                    i += 1;
                }
                continue;
            }
            return ParseError.UnknownOption;
        }

        // Short option: -x or -xvalue
        if (arg.len >= 2 and arg[0] == '-' and arg[1] != '-') {
            const short = arg[1];
            const inline_value: ?[]const u8 = if (arg.len > 2) arg[2..] else null;

            // Try global first, then subcommand
            const g_result = setFieldByShort(G, g_fields, g_has_meta, global, short, inline_value, args, &i);
            switch (g_result) {
                .ok => continue,
                .missing_value => return ParseError.MissingValue,
                .invalid_value => return ParseError.InvalidValue,
                .not_found => {},
            }
            if (merged and S != void) {
                const s_result = setFieldByShort(S, s_fields, s_has_meta, sub, short, inline_value, args, &i);
                switch (s_result) {
                    .ok => continue,
                    .missing_value => return ParseError.MissingValue,
                    .invalid_value => return ParseError.InvalidValue,
                    .not_found => {},
                }
            }
            // In merged mode with empty subcommand struct, skip unknown short options
            if (merged and s_fields.len == 0) {
                if (inline_value == null and i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-') {
                    i += 1;
                }
                continue;
            }
            return ParseError.UnknownOption;
        }

        // Positional
        if (merged and !found_subcmd) {
            found_subcmd = true;
            continue;
        }
        positional_count += 1;
    }

    // Second pass: collect positionals into buffer using thread-local storage
    const S2 = struct {
        threadlocal var positional_buf: [256][]const u8 = undefined;
    };

    var pos_idx: usize = 0;
    i = 0;
    found_subcmd = false;
    stop_parsing_options = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len == 0) continue;

        // After --, everything is positional
        if (stop_parsing_options) {
            if (pos_idx < 256) {
                S2.positional_buf[pos_idx] = arg;
                pos_idx += 1;
            }
            continue;
        }

        // End of options marker
        if (std.mem.eql(u8, arg, "--")) {
            stop_parsing_options = true;
            continue;
        }

        // Long option - skip it and its value
        if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') {
            const rest = arg[2..];
            var name: []const u8 = rest;
            var has_inline_value = false;

            if (rest.len > 3 and std.mem.startsWith(u8, rest, "no-")) {
                name = rest[3..];
            }

            if (std.mem.indexOf(u8, name, "=")) |_| {
                has_inline_value = true;
            }

            // Skip next arg if it's the value (non-bool option without inline value)
            if (!has_inline_value) {
                var name_buf: [64]u8 = undefined;
                const norm_name = normalizeName(name, &name_buf);
                if (needsValue(G, g_fields, g_has_meta, norm_name) or
                    (merged and S != void and needsValue(S, s_fields, s_has_meta, norm_name)))
                {
                    i += 1;
                }
            }
            continue;
        }

        // Short option - skip it and its value
        if (arg.len >= 2 and arg[0] == '-' and arg[1] != '-') {
            const short = arg[1];
            const has_inline_value = arg.len > 2;

            // Skip next arg if it's the value
            if (!has_inline_value) {
                if (needsValueShort(G, g_fields, g_has_meta, short) or
                    (merged and S != void and needsValueShort(S, s_fields, s_has_meta, short)))
                {
                    i += 1;
                }
            }
            continue;
        }

        // Positional
        if (merged and !found_subcmd) {
            found_subcmd = true;
            continue;
        }
        if (pos_idx < 256) {
            S2.positional_buf[pos_idx] = arg;
            pos_idx += 1;
        }
    }

    return S2.positional_buf[0..pos_idx];
}

fn normalizeName(name: []const u8, buf: []u8) []const u8 {
    var j: usize = 0;
    for (name) |c| {
        if (j >= buf.len) break;
        buf[j] = if (c == '-') '_' else c;
        j += 1;
    }
    return buf[0..j];
}

fn needsValue(
    comptime T: type,
    comptime fields: []const std.builtin.Type.StructField,
    comptime has_meta: bool,
    name: []const u8,
) bool {
    _ = T;
    _ = has_meta;
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            // Bool fields don't need a value
            if (field.type == bool) return false;
            // Optional bool fields don't need a value
            if (@typeInfo(field.type) == .optional and @typeInfo(field.type).optional.child == bool) return false;
            return true;
        }
    }
    return false;
}

fn needsValueShort(
    comptime T: type,
    comptime fields: []const std.builtin.Type.StructField,
    comptime has_meta: bool,
    short: u8,
) bool {
    if (!has_meta) return false;

    inline for (fields) |field| {
        if (@hasField(@TypeOf(T.meta), field.name)) {
            const field_meta = @field(T.meta, field.name);
            if (@hasField(@TypeOf(field_meta), "short")) {
                if (field_meta.short == short) {
                    // Bool fields don't need a value
                    if (field.type == bool) return false;
                    // Optional bool fields don't need a value
                    if (@typeInfo(field.type) == .optional and @typeInfo(field.type).optional.child == bool) return false;
                    return true;
                }
            }
        }
    }
    return false;
}

const FieldResult = enum { not_found, ok, missing_value, invalid_value };

fn setField(
    comptime T: type,
    comptime fields: []const std.builtin.Type.StructField,
    comptime has_meta: bool,
    opts: *T,
    name: []const u8,
    inline_value: ?[]const u8,
    args: []const []const u8,
    i: *usize,
) FieldResult {
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            setValue(T, opts, field, has_meta, inline_value, args, i) catch |e| return switch (e) {
                error.MissingValue => .missing_value,
                else => .invalid_value,
            };
            return .ok;
        }
    }
    return .not_found;
}

fn setFieldNegated(
    comptime T: type,
    comptime fields: []const std.builtin.Type.StructField,
    comptime has_meta: bool,
    opts: *T,
    name: []const u8,
) FieldResult {
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            setNegatedValue(T, opts, field, has_meta) catch return .invalid_value;
            return .ok;
        }
    }
    return .not_found;
}

fn setNegatedValue(
    comptime T: type,
    opts: *T,
    comptime field: std.builtin.Type.StructField,
    comptime has_meta: bool,
) ParseError!void {
    const F = field.type;

    // Check for no_value in meta first
    if (has_meta and @hasField(@TypeOf(T.meta), field.name)) {
        const field_meta = @field(T.meta, field.name);
        if (@hasField(@TypeOf(field_meta), "no_value")) {
            @field(opts, field.name) = field_meta.no_value;
            return;
        }
    }

    // Bool fields: --no-foo sets to false
    if (F == bool) {
        @field(opts, field.name) = false;
        return;
    }

    // Optional fields: --no-foo sets to null
    if (@typeInfo(F) == .optional) {
        @field(opts, field.name) = null;
        return;
    }

    // No no_value in meta and not bool/optional - error
    return ParseError.InvalidValue;
}

fn setFieldByShort(
    comptime T: type,
    comptime fields: []const std.builtin.Type.StructField,
    comptime has_meta: bool,
    opts: *T,
    short: u8,
    inline_value: ?[]const u8,
    args: []const []const u8,
    i: *usize,
) FieldResult {
    if (!has_meta) return .not_found;

    inline for (fields) |field| {
        if (@hasField(@TypeOf(T.meta), field.name)) {
            const field_meta = @field(T.meta, field.name);
            if (@hasField(@TypeOf(field_meta), "short")) {
                if (field_meta.short == short) {
                    setValue(T, opts, field, has_meta, inline_value, args, i) catch |e| return switch (e) {
                        error.MissingValue => .missing_value,
                        else => .invalid_value,
                    };
                    return .ok;
                }
            }
        }
    }
    return .not_found;
}

fn setValue(
    comptime T: type,
    opts: *T,
    comptime field: std.builtin.Type.StructField,
    comptime has_meta: bool,
    inline_value: ?[]const u8,
    args: []const []const u8,
    i: *usize,
) ParseError!void {
    const F = field.type;

    // Bool fields are flags (no value needed)
    if (F == bool) {
        @field(opts, field.name) = true;
        return;
    }

    // Check if we have a value (inline or next arg that doesn't look like a flag)
    const value: ?[]const u8 = inline_value orelse blk: {
        if (i.* + 1 >= args.len) break :blk null;
        const next = args[i.* + 1];
        // Next arg looks like a flag, not a value
        if (next.len > 0 and next[0] == '-') break :blk null;
        i.* += 1;
        break :blk next;
    };

    // No value provided - check for flag_value in meta
    if (value == null) {
        if (has_meta and @hasField(@TypeOf(T.meta), field.name)) {
            const field_meta = @field(T.meta, field.name);
            if (@hasField(@TypeOf(field_meta), "flag_value")) {
                @field(opts, field.name) = field_meta.flag_value;
                return;
            }
        }
        return ParseError.MissingValue;
    }

    // Check for custom parse function in meta
    if (has_meta and @hasField(@TypeOf(T.meta), field.name)) {
        const field_meta = @field(T.meta, field.name);
        if (@hasField(@TypeOf(field_meta), "parse")) {
            const result = field_meta.parse(value.?);
            if (@typeInfo(@TypeOf(result)) == .error_union) {
                @field(opts, field.name) = result catch return ParseError.InvalidValue;
            } else if (@typeInfo(@TypeOf(result)) == .optional) {
                @field(opts, field.name) = result orelse return ParseError.InvalidValue;
            } else {
                @field(opts, field.name) = result;
            }
            return;
        }
    }

    // Repeatable options: append when the field is a list-like type.
    if (listElemType(F)) |Elem| {
        const parsed = try parseScalar(Elem, value.?);
        var list_ptr = &@field(opts, field.name);
        list_ptr.append(parsed) catch |e| {
            const name = @errorName(e);
            if (std.mem.eql(u8, name, "OutOfMemory")) return ParseError.OutOfMemory;
            if (std.mem.eql(u8, name, "Overflow")) return ParseError.TooManyValues;
            return ParseError.InvalidValue;
        };
        return;
    }

    @field(opts, field.name) = try parseScalar(F, value.?);
}

fn parseScalar(comptime T: type, value: []const u8) ParseError!T {
    if (T == []const u8) return value;

    switch (@typeInfo(T)) {
        .optional => {
            const Child = @typeInfo(T).optional.child;
            const parsed = try parseScalar(Child, value);
            return @as(T, parsed);
        },
        .int => return std.fmt.parseInt(T, value, 0) catch return ParseError.InvalidValue,
        .@"enum" => return std.meta.stringToEnum(T, value) orelse return ParseError.InvalidValue,
        else => return ParseError.InvalidValue,
    }
}

/// Fixed-capacity list for repeatable options (no allocator required).
///
///   const Opts = struct {
///       exclude: opt.Multi([]const u8, 32) = .{},
///       pub const meta = .{ .exclude = .{ .short = 'x' } };
///   };
pub fn Multi(comptime Elem: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]Elem = undefined,
        len: usize = 0,

        pub fn append(self: *Self, item: Elem) error{Overflow}!void {
            if (self.len >= capacity) return error.Overflow;
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *Self) []Elem {
            return self.buffer[0..self.len];
        }

        pub fn constSlice(self: *const Self) []const Elem {
            return self.buffer[0..self.len];
        }
    };
}

fn listElemType(comptime ListT: type) ?type {
    if (@typeInfo(ListT) != .@"struct") return null;

    if (!@hasDecl(ListT, "append")) return null;
    const append_info = @typeInfo(@TypeOf(ListT.append));
    if (append_info != .@"fn") return null;
    const params = append_info.@"fn".params;
    if (params.len != 2) return null;

    const fields = @typeInfo(ListT).@"struct".fields;
    var elem: ?type = null;
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, "items")) {
            const info = @typeInfo(field.type);
            if (info == .pointer and info.pointer.size == .slice) elem = info.pointer.child;
        }
        if (std.mem.eql(u8, field.name, "buffer")) {
            const info = @typeInfo(field.type);
            if (info == .array) elem = info.array.child;
        }
    }

    const found = elem orelse return null;
    const item_param = params[1].type orelse return null;
    if (item_param != found) return null;

    return found;
}

const spaces = "                        "; // 24 spaces

/// Print usage/help for opts struct
pub fn printUsage(comptime T: type, writer: anytype) void {
    const fields = @typeInfo(T).@"struct".fields;
    const has_meta = @hasDecl(T, "meta");
    const has_about = @hasDecl(T, "about");

    if (has_about) {
        writer.print("{s}", .{T.about.name}) catch return;
        if (@hasField(@TypeOf(T.about), "desc")) {
            writer.print(" - {s}", .{T.about.desc}) catch return;
        }
        writer.writeAll("\n\n") catch return;
        if (@hasField(@TypeOf(T.about), "usage")) {
            writer.writeAll(T.about.usage) catch return;
            writer.writeAll("\n") catch return;
        }
    }

    writer.writeAll("Options:\n") catch return;

    inline for (fields) |field| {
        const short: ?u8 = if (has_meta and @hasField(@TypeOf(T.meta), field.name)) blk: {
            const m = @field(T.meta, field.name);
            break :blk if (@hasField(@TypeOf(m), "short")) m.short else null;
        } else null;

        const help: ?[]const u8 = if (has_meta and @hasField(@TypeOf(T.meta), field.name)) blk: {
            const m = @field(T.meta, field.name);
            break :blk if (@hasField(@TypeOf(m), "help")) m.help else null;
        } else null;

        writer.writeAll("  ") catch return;

        if (short) |s| {
            writer.print("-{c}, ", .{s}) catch return;
        } else {
            writer.writeAll("    ") catch return;
        }

        writer.writeAll("--") catch return;
        for (field.name) |c| {
            writer.writeByte(if (c == '_') '-' else c) catch return;
        }

        if (field.type != bool) {
            writer.print(" <{s}>", .{typeName(field.type)}) catch return;
        }

        const name_len = field.name.len + 2 + (if (field.type != bool) typeName(field.type).len + 3 else 0);
        const pad = if (name_len < 24) 24 - name_len else 1;
        writer.writeAll(spaces[0..pad]) catch return;

        if (help) |h| {
            writer.writeAll(h) catch return;
        }

        if (field.defaultValue()) |def| {
            if (field.type == bool) {
                // skip
            } else if (field.type == []const u8) {
                writer.print(" (default: {s})", .{def}) catch return;
            } else if (@typeInfo(field.type) == .optional) {
                // skip
            } else if (@typeInfo(field.type) == .int) {
                writer.print(" (default: {d})", .{def}) catch return;
            } else if (@typeInfo(field.type) == .@"enum") {
                writer.print(" (default: {s})", .{@tagName(def)}) catch return;
            }
        }

        writer.writeAll("\n") catch return;
    }

    writer.writeAll("  -h, --help                  Show this help\n") catch return;
}

fn typeName(comptime T: type) [:0]const u8 {
    if (T == []const u8) return "str";
    if (@typeInfo(T) == .optional) return typeName(@typeInfo(T).optional.child);
    if (listElemType(T)) |Elem| return typeName(Elem);
    if (@typeInfo(T) == .int) return @typeName(T);
    if (@typeInfo(T) == .@"enum") return "enum";
    return "?";
}

/// Find subcommand name (first positional arg)
pub fn findSubcmd(comptime E: type, args: []const []const u8) ?E {
    for (args) |arg| {
        if (arg.len > 0 and arg[0] != '-') {
            return std.meta.stringToEnum(E, arg);
        }
    }
    return null;
}

/// Print merged usage (global + subcommand opts)
pub fn printMergedUsage(comptime G: type, comptime S: type, writer: anytype) void {
    const has_about = @hasDecl(S, "about");

    if (has_about) {
        writer.print("{s}", .{S.about.name}) catch return;
        if (@hasField(@TypeOf(S.about), "desc")) {
            writer.print(" - {s}", .{S.about.desc}) catch return;
        }
        writer.writeAll("\n\n") catch return;
    }

    writer.writeAll("Options:\n") catch return;
    printFields(S, writer);

    writer.writeAll("\nGlobal options:\n") catch return;
    printFields(G, writer);

    writer.writeAll("  -h, --help              Show this help\n") catch return;
}

fn printFields(comptime T: type, writer: anytype) void {
    const fields = @typeInfo(T).@"struct".fields;
    const has_meta = @hasDecl(T, "meta");

    inline for (fields) |field| {
        const short: ?u8 = if (has_meta and @hasField(@TypeOf(T.meta), field.name)) blk: {
            const m = @field(T.meta, field.name);
            break :blk if (@hasField(@TypeOf(m), "short")) m.short else null;
        } else null;

        const help: ?[]const u8 = if (has_meta and @hasField(@TypeOf(T.meta), field.name)) blk: {
            const m = @field(T.meta, field.name);
            break :blk if (@hasField(@TypeOf(m), "help")) m.help else null;
        } else null;

        writer.writeAll("  ") catch return;

        if (short) |s| {
            writer.print("-{c}, ", .{s}) catch return;
        } else {
            writer.writeAll("    ") catch return;
        }

        writer.writeAll("--") catch return;
        for (field.name) |c| {
            writer.writeByte(if (c == '_') '-' else c) catch return;
        }

        if (field.type != bool) {
            writer.print(" <{s}>", .{typeName(field.type)}) catch return;
        }

        const name_len = field.name.len + 2 + (if (field.type != bool) typeName(field.type).len + 3 else 0);
        const pad = if (name_len < 24) 24 - name_len else 1;
        writer.writeAll(spaces[0..pad]) catch return;

        if (help) |h| {
            writer.writeAll(h) catch return;
        }

        if (field.defaultValue()) |def| {
            if (field.type == bool) {
                // skip
            } else if (field.type == []const u8) {
                writer.print(" (default: {s})", .{def}) catch return;
            } else if (@typeInfo(field.type) == .optional) {
                // skip
            } else if (@typeInfo(field.type) == .int) {
                writer.print(" (default: {d})", .{def}) catch return;
            } else if (@typeInfo(field.type) == .@"enum") {
                writer.print(" (default: {s})", .{@tagName(def)}) catch return;
            }
        }

        writer.writeAll("\n") catch return;
    }
}

// ============ Tests ============

test "parse basic options" {
    const Opts = struct {
        name: []const u8 = "default",
        count: u32 = 0,
        verbose: bool = false,

        pub const meta = .{
            .name = .{ .short = 'n', .help = "Name" },
            .count = .{ .short = 'c', .help = "Count" },
            .verbose = .{ .short = 'v', .help = "Verbose" },
        };
    };

    var opts = Opts{};
    _ = try parse(Opts, &opts, &.{ "-n", "foo", "-c", "42", "-v" });

    try std.testing.expectEqualStrings("foo", opts.name);
    try std.testing.expectEqual(@as(u32, 42), opts.count);
    try std.testing.expect(opts.verbose);
}

test "parse long options" {
    const Opts = struct {
        input_port: u16 = 5600,
        output_addr: []const u8 = "127.0.0.1",
    };

    var opts = Opts{};
    _ = try parse(Opts, &opts, &.{ "--input-port", "1234", "--output-addr=192.168.1.1" });

    try std.testing.expectEqual(@as(u16, 1234), opts.input_port);
    try std.testing.expectEqualStrings("192.168.1.1", opts.output_addr);
}

test "parse returns positional args" {
    const Opts = struct {
        verbose: bool = false,

        pub const meta = .{ .verbose = .{ .short = 'v' } };
    };

    var opts = Opts{};
    const rest = try parse(Opts, &opts, &.{ "-v", "file1", "file2" });

    try std.testing.expect(opts.verbose);
    try std.testing.expectEqual(@as(usize, 2), rest.len);
    try std.testing.expectEqualStrings("file1", rest[0]);
}

test "help flag returns error" {
    const Opts = struct {
        name: []const u8 = "x",
    };

    var opts = Opts{};
    const result = parse(Opts, &opts, &.{"--help"});
    try std.testing.expectError(ParseError.Help, result);
}

test "printUsage output" {
    const Opts = struct {
        replace: []const u8 = "",
        context: u8 = 2,
        dry_run: bool = false,

        pub const meta = .{
            .replace = .{ .short = 'r', .help = "Replacement string" },
            .context = .{ .short = 'C', .help = "Lines of context" },
            .dry_run = .{ .short = 'n', .help = "Preview changes" },
        };
        pub const about = .{ .name = "zg", .desc = "Fast search and replace" };
    };

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    printUsage(Opts, fbs.writer());
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "zg - Fast search and replace") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-r, --replace") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(default: 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--dry-run") != null);
}

test "optional field" {
    const Opts = struct {
        config: ?[]const u8 = null,
        limit: ?u32 = null,
    };

    var opts = Opts{};
    _ = try parse(Opts, &opts, &.{ "--config", "foo.toml", "--limit", "100" });

    try std.testing.expectEqualStrings("foo.toml", opts.config.?);
    try std.testing.expectEqual(@as(u32, 100), opts.limit.?);
}

test "enum field" {
    const Mode = enum { fast, slow, auto };
    const Opts = struct {
        mode: Mode = .auto,
    };

    var opts = Opts{};
    _ = try parse(Opts, &opts, &.{ "--mode", "fast" });

    try std.testing.expectEqual(Mode.fast, opts.mode);
}

test "findSubcmd" {
    const Cmd = enum { tx, rx, drone, gs };

    try std.testing.expectEqual(Cmd.tx, findSubcmd(Cmd, &.{ "-v", "tx", "-i", "wlan0" }));
    try std.testing.expectEqual(Cmd.rx, findSubcmd(Cmd, &.{"rx"}));
    try std.testing.expectEqual(null, findSubcmd(Cmd, &.{ "-v", "--quiet" }));
    try std.testing.expectEqual(null, findSubcmd(Cmd, &.{"unknown"}));
}

test "parseMerged global opts anywhere" {
    const Global = struct {
        verbose: bool = false,
        quiet: bool = false,

        pub const meta = .{
            .verbose = .{ .short = 'v', .help = "Verbose" },
            .quiet = .{ .short = 'q', .help = "Quiet" },
        };
    };

    const TxOpts = struct {
        interface: []const u8 = "wlan0",
        port: u16 = 5600,

        pub const meta = .{
            .interface = .{ .short = 'i', .help = "Interface" },
            .port = .{ .short = 'p', .help = "Port" },
        };
    };

    // Global before subcommand
    {
        var global = Global{};
        var sub = TxOpts{};
        _ = try parseMerged(Global, TxOpts, &global, &sub, &.{ "-v", "tx", "-i", "wlan1" });
        try std.testing.expect(global.verbose);
        try std.testing.expectEqualStrings("wlan1", sub.interface);
    }

    // Global after subcommand
    {
        var global = Global{};
        var sub = TxOpts{};
        _ = try parseMerged(Global, TxOpts, &global, &sub, &.{ "tx", "-i", "wlan1", "-v" });
        try std.testing.expect(global.verbose);
        try std.testing.expectEqualStrings("wlan1", sub.interface);
    }

    // Mixed order
    {
        var global = Global{};
        var sub = TxOpts{};
        _ = try parseMerged(Global, TxOpts, &global, &sub, &.{ "tx", "-v", "-i", "wlan1", "--quiet", "-p", "1234" });
        try std.testing.expect(global.verbose);
        try std.testing.expect(global.quiet);
        try std.testing.expectEqualStrings("wlan1", sub.interface);
        try std.testing.expectEqual(@as(u16, 1234), sub.port);
    }
}

test "parseMerged returns positional after subcmd" {
    const Global = struct { verbose: bool = false };
    const Sub = struct { name: []const u8 = "x" };

    var global = Global{};
    var sub = Sub{};
    const rest = try parseMerged(Global, Sub, &global, &sub, &.{ "cmd", "--name", "foo", "pos1", "pos2" });

    try std.testing.expectEqualStrings("foo", sub.name);
    try std.testing.expectEqual(@as(usize, 2), rest.len);
    try std.testing.expectEqualStrings("pos1", rest[0]);
}

test "repeatable option appends" {
    const Opts = struct {
        exclude: Multi([]const u8, 8) = .{},

        pub const meta = .{ .exclude = .{ .short = 'x', .help = "Exclude" } };
    };

    var opts = Opts{};
    _ = try parse(Opts, &opts, &.{ "-x", "log", "-x", "pyc" });

    const got = opts.exclude.constSlice();
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("log", got[0]);
    try std.testing.expectEqualStrings("pyc", got[1]);
}

test "trailing options after positionals" {
    const Opts = struct {
        sudo: bool = false,
        restart: []const u8 = "",
    };

    var opts = Opts{};
    // ship --sudo zig-out/bin/wizig:/usr/bin/wizig ygs --restart 'sudo systemctl restart wizig'
    const rest = try parse(Opts, &opts, &.{ "--sudo", "src:dst", "ygs", "--restart", "cmd" });

    try std.testing.expect(opts.sudo);
    try std.testing.expectEqualStrings("cmd", opts.restart); // parsed even after positional
    try std.testing.expectEqual(@as(usize, 2), rest.len);
    try std.testing.expectEqualStrings("src:dst", rest[0]);
    try std.testing.expectEqualStrings("ygs", rest[1]);
}

test "double dash stops option parsing" {
    const Opts = struct {
        verbose: bool = false,
        pub const meta = .{ .verbose = .{ .short = 'v' } };
    };

    var opts = Opts{};
    const rest = try parse(Opts, &opts, &.{ "-v", "--", "-not-an-option", "file" });

    try std.testing.expect(opts.verbose);
    try std.testing.expectEqual(@as(usize, 2), rest.len);
    try std.testing.expectEqualStrings("-not-an-option", rest[0]);
    try std.testing.expectEqualStrings("file", rest[1]);
}

test "negated bool with --no-*" {
    const Opts = struct {
        verbose: bool = true,
        debug: bool = false,
    };

    var opts = Opts{};
    _ = try parse(Opts, &opts, &.{ "--no-verbose", "--debug" });

    try std.testing.expect(!opts.verbose);
    try std.testing.expect(opts.debug);
}

test "negated optional with --no-*" {
    const Opts = struct {
        config: ?[]const u8 = "default.conf",
        limit: ?u32 = 100,
    };

    var opts = Opts{};
    _ = try parse(Opts, &opts, &.{ "--no-config", "--no-limit" });

    try std.testing.expectEqual(@as(?[]const u8, null), opts.config);
    try std.testing.expectEqual(@as(?u32, null), opts.limit);
}

test "negated with no_value in meta" {
    const Compress = enum { off, on, auto };
    const Opts = struct {
        compress: Compress = .auto,

        pub const meta = .{
            .compress = .{ .no_value = .off },
        };
    };

    var opts = Opts{};
    _ = try parse(Opts, &opts, &.{"--no-compress"});

    try std.testing.expectEqual(Compress.off, opts.compress);
}

test "flag_value for value-optional flags" {
    const Compress = enum { off, on, auto };
    const Opts = struct {
        compress: Compress = .auto,

        pub const meta = .{
            .compress = .{ .flag_value = .on },
        };
    };

    // --compress alone uses flag_value
    {
        var opts = Opts{};
        _ = try parse(Opts, &opts, &.{"--compress"});
        try std.testing.expectEqual(Compress.on, opts.compress);
    }

    // --compress=auto still parses the value
    {
        var opts = Opts{};
        _ = try parse(Opts, &opts, &.{"--compress=off"});
        try std.testing.expectEqual(Compress.off, opts.compress);
    }
}

test "flag_value and no_value together" {
    const Compress = enum { off, on, auto };
    const Opts = struct {
        compress: Compress = .auto,

        pub const meta = .{
            .compress = .{ .flag_value = .on, .no_value = .off },
        };
    };

    // --compress → .on
    {
        var opts = Opts{};
        _ = try parse(Opts, &opts, &.{"--compress"});
        try std.testing.expectEqual(Compress.on, opts.compress);
    }

    // --no-compress → .off
    {
        var opts = Opts{};
        _ = try parse(Opts, &opts, &.{"--no-compress"});
        try std.testing.expectEqual(Compress.off, opts.compress);
    }

    // --compress=auto → .auto
    {
        var opts = Opts{};
        _ = try parse(Opts, &opts, &.{"--compress=auto"});
        try std.testing.expectEqual(Compress.auto, opts.compress);
    }
}

test "flag_value followed by other flags" {
    const Compress = enum { off, on, auto };
    const Opts = struct {
        compress: Compress = .auto,
        verbose: bool = false,
        level: u8 = 1,

        pub const meta = .{
            .compress = .{ .flag_value = .on },
            .verbose = .{ .short = 'v' },
        };
    };

    // --compress followed by --verbose (not consumed as value)
    {
        var opts = Opts{};
        _ = try parse(Opts, &opts, &.{ "--compress", "--verbose" });
        try std.testing.expectEqual(Compress.on, opts.compress);
        try std.testing.expect(opts.verbose);
    }

    // --compress followed by -v (not consumed as value)
    {
        var opts = Opts{};
        _ = try parse(Opts, &opts, &.{ "--compress", "-v" });
        try std.testing.expectEqual(Compress.on, opts.compress);
        try std.testing.expect(opts.verbose);
    }

    // --compress at end of args
    {
        var opts = Opts{};
        _ = try parse(Opts, &opts, &.{"--compress"});
        try std.testing.expectEqual(Compress.on, opts.compress);
    }

    // --level still requires value (no flag_value)
    {
        var opts = Opts{};
        const result = parse(Opts, &opts, &.{"--level"});
        try std.testing.expectError(ParseError.MissingValue, result);
    }
}

test "custom parse function" {
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

    // Valid octal
    {
        var opts = Opts{};
        _ = try parse(Opts, &opts, &.{ "--chmod", "644" });
        try std.testing.expectEqual(@as(?u16, 0o644), opts.chmod);
    }

    // Another valid octal
    {
        var opts = Opts{};
        _ = try parse(Opts, &opts, &.{ "--chmod", "755" });
        try std.testing.expectEqual(@as(?u16, 0o755), opts.chmod);
    }

    // Invalid octal (has 8 and 9)
    {
        var opts = Opts{};
        const result = parse(Opts, &opts, &.{ "--chmod", "899" });
        try std.testing.expectError(ParseError.InvalidValue, result);
    }
}

test "custom parse function returning error union" {
    const Opts = struct {
        port: u16 = 8080,

        pub const meta = .{
            .port = .{
                .parse = struct {
                    fn p(val: []const u8) error{InvalidPort}!u16 {
                        const n = std.fmt.parseInt(u16, val, 10) catch return error.InvalidPort;
                        if (n < 1024) return error.InvalidPort; // reject privileged ports
                        return n;
                    }
                }.p,
            },
        };
    };

    // Valid port
    {
        var opts = Opts{};
        _ = try parse(Opts, &opts, &.{ "--port", "3000" });
        try std.testing.expectEqual(@as(u16, 3000), opts.port);
    }

    // Invalid (privileged port)
    {
        var opts = Opts{};
        const result = parse(Opts, &opts, &.{ "--port", "80" });
        try std.testing.expectError(ParseError.InvalidValue, result);
    }
}

test "custom parse with --no-* still works" {
    const Opts = struct {
        chmod: ?u16 = 0o755,

        pub const meta = .{
            .chmod = .{
                .parse = struct {
                    fn p(val: []const u8) ?u16 {
                        return std.fmt.parseInt(u16, val, 8) catch null;
                    }
                }.p,
            },
        };
    };

    var opts = Opts{};
    _ = try parse(Opts, &opts, &.{"--no-chmod"});
    try std.testing.expectEqual(@as(?u16, null), opts.chmod);
}
