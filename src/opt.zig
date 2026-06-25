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
//!   var positionals_buf: [256][]const u8 = undefined;
//!   const positionals = opt.parse(Options, &opts, args, &positionals_buf) catch |e| {
//!       if (e == error.Help) opt.printUsage(Options, stdout);
//!       return e;
//!   };

const std = @import("std");
const scanner = @import("scanner.zig");
const options = @import("options.zig");
const errors = @import("errors.zig");

pub const ParseError = errors.ParseError;

pub fn Multi(comptime Elem: type, comptime capacity: usize) type {
    return options.Multi(Elem, capacity);
}

/// Parse args into opts struct. Returns remaining positional args in positionals_buf.
pub fn parse(comptime T: type, opts: *T, args: []const []const u8, positionals_buf: [][]const u8) errors.ParseError![]const []const u8 {
    comptime options.validateOptionStruct(T);

    const fields = @typeInfo(T).@"struct".fields;
    const has_meta = @hasDecl(T, "meta");

    var pos_idx: usize = 0;
    var arg_scanner = scanner.ArgScanner.init(args, 0);
    const resolver = options.OptionStructResolver(T){};
    while (arg_scanner.next(resolver)) |token| {
        switch (token) {
            .help => return errors.ParseError.Help,
            .end_options => {},
            .positional => |pos| try appendPositional(positionals_buf, &pos_idx, pos.value),
            .option => |opt| {
                const result = switch (opt.key) {
                    .long => |name| if (opt.negated)
                        options.setFieldNegated(T, fields, has_meta, opts, name)
                    else
                        options.setField(T, fields, has_meta, opts, name, opt.value),
                    .short => |short| options.setFieldByShort(T, fields, has_meta, opts, short, opt.value),
                };
                switch (result) {
                    .ok => {},
                    .missing_value => return errors.ParseError.MissingValue,
                    .invalid_value => return errors.ParseError.InvalidValue,
                    .not_found => return errors.ParseError.UnknownOption,
                }
            },
        }
    }

    return positionals_buf[0..pos_idx];
}

fn appendPositional(positionals_buf: [][]const u8, pos_idx: *usize, arg: []const u8) errors.ParseError!void {
    if (pos_idx.* >= positionals_buf.len) return errors.ParseError.TooManyPositionals;
    positionals_buf[pos_idx.*] = arg;
    pos_idx.* += 1;
}

const spaces = "                        "; // 24 spaces

/// Print usage/help for opts struct
pub fn printUsage(comptime T: type, writer: anytype) void {
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
    printFields(T, writer);
    writer.writeAll("  -h, --help                  Show this help\n") catch return;
}

fn typeName(comptime T: type) [:0]const u8 {
    if (T == []const u8) return "str";
    if (@typeInfo(T) == .optional) return typeName(@typeInfo(T).optional.child);
    if (options.listElemType(T)) |Elem| return typeName(Elem);
    if (@typeInfo(T) == .int) return @typeName(T);
    if (@typeInfo(T) == .@"enum") return "enum";
    return "?";
}

fn commandPayloadType(comptime command_spec: anytype) type {
    if (comptime @TypeOf(command_spec) == type) return command_spec;
    return struct {
        options: command_spec.options,
        command_name: []const u8,
        command_index: usize,
        command: commandUnion(@field(command_spec, "commands")),
    };
}

fn commandUnion(comptime commands: anytype) type {
    const fields_info = @typeInfo(@TypeOf(commands)).@"struct".fields;
    comptime var enum_fields: [fields_info.len]std.builtin.Type.EnumField = undefined;
    comptime var union_fields: [fields_info.len]std.builtin.Type.UnionField = undefined;

    inline for (fields_info, 0..) |field, idx| {
        const command_spec = @field(commands, field.name);
        enum_fields[idx] = .{ .name = field.name, .value = idx };
        union_fields[idx] = .{
            .name = field.name,
            .type = commandPayloadType(command_spec),
            .alignment = @alignOf(commandPayloadType(command_spec)),
        };
    }

    const Tag = @Type(.{ .@"enum" = .{
        .tag_type = std.math.IntFittingRange(0, fields_info.len - 1),
        .fields = &enum_fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });

    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = Tag,
        .fields = &union_fields,
        .decls = &.{},
    } });
}

fn commandFound(comptime commands: anytype) type {
    return struct {
        command: commandUnion(commands),
        command_name: []const u8,
        command_index: usize,
    };
}

fn commandNameMatches(field_name: []const u8, arg: []const u8) bool {
    if (field_name.len != arg.len) return false;
    for (field_name, arg) |f, a| {
        const normalized = if (f == '_') '-' else f;
        if (normalized != a) return false;
    }
    return true;
}

fn commandSpecIsBranch(comptime command_spec: anytype) bool {
    return @TypeOf(command_spec) != type;
}

fn commandSpecOptions(comptime command_spec: anytype) type {
    return if (commandSpecIsBranch(command_spec)) command_spec.options else command_spec;
}

fn validateNoDuplicateOptionsBetween(comptime A: type, comptime B: type) void {
    const a_fields = @typeInfo(A).@"struct".fields;
    const b_fields = @typeInfo(B).@"struct".fields;

    inline for (a_fields) |a_field| {
        inline for (b_fields) |b_field| {
            if (std.mem.eql(u8, a_field.name, b_field.name)) {
                @compileError("duplicate long option in visible command path: " ++ @typeName(A) ++ "." ++ a_field.name ++ " and " ++ @typeName(B) ++ "." ++ b_field.name);
            }
        }

        if (options.optionShort(A, a_field)) |a_short| {
            inline for (b_fields) |b_field| {
                if (options.optionShort(B, b_field)) |b_short| {
                    if (a_short == b_short) {
                        @compileError("duplicate short option in visible command path between " ++ @typeName(A) ++ " and " ++ @typeName(B));
                    }
                }
            }
        }
    }
}

fn validateCommandsAgainstScope(comptime commands: anytype, comptime Scope: type) void {
    inline for (@typeInfo(@TypeOf(commands)).@"struct".fields) |field| {
        const command_spec = @field(commands, field.name);
        const Opts = commandSpecOptions(command_spec);
        validateNoDuplicateOptionsBetween(Scope, Opts);
        if (comptime commandSpecIsBranch(command_spec)) {
            validateCommandsAgainstScope(command_spec.commands, Scope);
        }
    }
}

fn validateNoArityConflictBetween(comptime A: type, comptime B: type) void {
    const a_fields = @typeInfo(A).@"struct".fields;
    const b_fields = @typeInfo(B).@"struct".fields;

    inline for (a_fields) |a_field| {
        inline for (b_fields) |b_field| {
            if (std.mem.eql(u8, a_field.name, b_field.name) and options.fieldArity(a_field) != options.fieldArity(b_field)) {
                @compileError("option has conflicting arity in command tree: " ++ @typeName(A) ++ "." ++ a_field.name ++ " and " ++ @typeName(B) ++ "." ++ b_field.name);
            }
        }

        if (options.optionShort(A, a_field)) |a_short| {
            inline for (b_fields) |b_field| {
                if (options.optionShort(B, b_field)) |b_short| {
                    if (a_short == b_short and options.fieldArity(a_field) != options.fieldArity(b_field)) {
                        @compileError("short option has conflicting arity in command tree between " ++ @typeName(A) ++ " and " ++ @typeName(B));
                    }
                }
            }
        }
    }
}

fn validateCommandTreeArityAgainstScope(comptime commands: anytype, comptime Scope: type) void {
    inline for (@typeInfo(@TypeOf(commands)).@"struct".fields) |field| {
        const command_spec = @field(commands, field.name);
        const Opts = commandSpecOptions(command_spec);
        validateNoArityConflictBetween(Scope, Opts);
        if (comptime commandSpecIsBranch(command_spec)) {
            validateCommandTreeArityAgainstScope(command_spec.commands, Scope);
        }
    }
}

fn validateCommandTreeArityBetweenTrees(comptime left_commands: anytype, comptime right_commands: anytype) void {
    inline for (@typeInfo(@TypeOf(left_commands)).@"struct".fields) |field| {
        const command_spec = @field(left_commands, field.name);
        const Opts = commandSpecOptions(command_spec);
        validateCommandTreeArityAgainstScope(right_commands, Opts);
        if (comptime commandSpecIsBranch(command_spec)) {
            validateCommandTreeArityBetweenTrees(command_spec.commands, right_commands);
        }
    }
}

fn validateCommandTreeArityConflicts(comptime commands: anytype) void {
    const fields = @typeInfo(@TypeOf(commands)).@"struct".fields;
    inline for (fields, 0..) |left_field, left_idx| {
        const left_spec = @field(commands, left_field.name);
        const LeftOpts = commandSpecOptions(left_spec);

        inline for (fields[left_idx + 1 ..]) |right_field| {
            const right_spec = @field(commands, right_field.name);
            const RightOpts = commandSpecOptions(right_spec);

            validateNoArityConflictBetween(LeftOpts, RightOpts);
            if (comptime commandSpecIsBranch(left_spec)) {
                validateCommandTreeArityAgainstScope(left_spec.commands, RightOpts);
            }
            if (comptime commandSpecIsBranch(right_spec)) {
                validateCommandTreeArityAgainstScope(right_spec.commands, LeftOpts);
            }
            if (comptime commandSpecIsBranch(left_spec) and commandSpecIsBranch(right_spec)) {
                validateCommandTreeArityBetweenTrees(left_spec.commands, right_spec.commands);
            }
        }

        if (comptime commandSpecIsBranch(left_spec)) {
            validateCommandTreeArityConflicts(left_spec.commands);
        }
    }
}

fn validateCommandTree(comptime commands: anytype) void {
    inline for (@typeInfo(@TypeOf(commands)).@"struct".fields) |field| {
        const command_spec = @field(commands, field.name);
        const Opts = commandSpecOptions(command_spec);
        options.validateOptionStruct(Opts);
        if (comptime commandSpecIsBranch(command_spec)) {
            validateCommandsAgainstScope(command_spec.commands, Opts);
            validateCommandTree(command_spec.commands);
        }
    }
}

fn validateCommandParserSpec(comptime spec: anytype) void {
    options.validateOptionStruct(spec.global);
    validateCommandsAgainstScope(spec.commands, spec.global);
    validateCommandTree(spec.commands);
    validateCommandTreeArityConflicts(spec.commands);
}

fn longArityInCommandTree(comptime commands: anytype, name: []const u8) ?scanner.OptionArity {
    var arity: ?scanner.OptionArity = null;
    inline for (@typeInfo(@TypeOf(commands)).@"struct".fields) |field| {
        const command_spec = @field(commands, field.name);
        const Opts = commandSpecOptions(command_spec);
        const opt_fields = @typeInfo(Opts).@"struct".fields;
        const has_meta = @hasDecl(Opts, "meta");
        arity = options.combineArity(arity, options.longOptionArity(Opts, opt_fields, has_meta, name));
        if (arity == .value) return .value;
        if (comptime commandSpecIsBranch(command_spec)) {
            arity = options.combineArity(arity, longArityInCommandTree(command_spec.commands, name));
            if (arity == .value) return .value;
        }
    }
    return arity;
}

fn shortArityInCommandTree(comptime commands: anytype, short: u8) ?scanner.OptionArity {
    var arity: ?scanner.OptionArity = null;
    inline for (@typeInfo(@TypeOf(commands)).@"struct".fields) |field| {
        const command_spec = @field(commands, field.name);
        const Opts = commandSpecOptions(command_spec);
        const opt_fields = @typeInfo(Opts).@"struct".fields;
        const has_meta = @hasDecl(Opts, "meta");
        arity = options.combineArity(arity, options.shortOptionArity(Opts, opt_fields, has_meta, short));
        if (arity == .value) return .value;
        if (comptime commandSpecIsBranch(command_spec)) {
            arity = options.combineArity(arity, shortArityInCommandTree(command_spec.commands, short));
            if (arity == .value) return .value;
        }
    }
    return arity;
}

fn longArityInSelectedCommand(comptime commands: anytype, command: *const commandUnion(commands), name: []const u8) ?scanner.OptionArity {
    switch (command.*) {
        inline else => |*payload, tag| {
            const command_spec = @field(commands, @tagName(tag));
            const Opts = commandSpecOptions(command_spec);
            const opt_fields = @typeInfo(Opts).@"struct".fields;
            const has_meta = @hasDecl(Opts, "meta");
            var arity = options.longOptionArity(Opts, opt_fields, has_meta, name);
            if (comptime commandSpecIsBranch(command_spec)) {
                arity = options.combineArity(arity, longArityInSelectedCommand(command_spec.commands, &payload.command, name));
            }
            return arity;
        },
    }
}

fn shortArityInSelectedCommand(comptime commands: anytype, command: *const commandUnion(commands), short: u8) ?scanner.OptionArity {
    switch (command.*) {
        inline else => |*payload, tag| {
            const command_spec = @field(commands, @tagName(tag));
            const Opts = commandSpecOptions(command_spec);
            const opt_fields = @typeInfo(Opts).@"struct".fields;
            const has_meta = @hasDecl(Opts, "meta");
            var arity = options.shortOptionArity(Opts, opt_fields, has_meta, short);
            if (comptime commandSpecIsBranch(command_spec)) {
                arity = options.combineArity(arity, shortArityInSelectedCommand(command_spec.commands, &payload.command, short));
            }
            return arity;
        },
    }
}

fn CommandDiscoveryResolver(comptime G: type, comptime Scope: type, comptime commands: anytype) type {
    return struct {
        const g_fields = @typeInfo(G).@"struct".fields;
        const g_has_meta = @hasDecl(G, "meta");
        const scope_fields = if (Scope != void) @typeInfo(Scope).@"struct".fields else &[_]std.builtin.Type.StructField{};
        const scope_has_meta = if (Scope != void) @hasDecl(Scope, "meta") else false;

        pub fn longArity(_: @This(), name: []const u8) ?scanner.OptionArity {
            return options.combineArity(
                options.combineArity(options.longOptionArity(G, g_fields, g_has_meta, name), if (Scope != void) options.longOptionArity(Scope, scope_fields, scope_has_meta, name) else null),
                longArityInCommandTree(commands, name),
            );
        }

        pub fn shortArity(_: @This(), short: u8) ?scanner.OptionArity {
            return options.combineArity(
                options.combineArity(options.shortOptionArity(G, g_fields, g_has_meta, short), if (Scope != void) options.shortOptionArity(Scope, scope_fields, scope_has_meta, short) else null),
                shortArityInCommandTree(commands, short),
            );
        }
    };
}

fn SelectedCommandResolver(comptime G: type, comptime commands: anytype) type {
    return struct {
        command: *const commandUnion(commands),

        const g_fields = @typeInfo(G).@"struct".fields;
        const g_has_meta = @hasDecl(G, "meta");

        pub fn longArity(self: @This(), name: []const u8) ?scanner.OptionArity {
            return options.combineArity(options.longOptionArity(G, g_fields, g_has_meta, name), longArityInSelectedCommand(commands, self.command, name));
        }

        pub fn shortArity(self: @This(), short: u8) ?scanner.OptionArity {
            return options.combineArity(options.shortOptionArity(G, g_fields, g_has_meta, short), shortArityInSelectedCommand(commands, self.command, short));
        }
    };
}

fn selectedCommandIndex(comptime commands: anytype, command: *const commandUnion(commands), root_index: usize, idx: usize) bool {
    if (idx == root_index) return true;
    switch (command.*) {
        inline else => |*payload, tag| {
            const command_spec = @field(commands, @tagName(tag));
            if (comptime commandSpecIsBranch(command_spec)) {
                if (idx == payload.command_index) return true;
                return selectedCommandIndex(command_spec.commands, &payload.command, payload.command_index, idx);
            }
            return false;
        },
    }
}

fn setLongInSelectedCommand(
    comptime commands: anytype,
    command: *commandUnion(commands),
    name: []const u8,
    is_negated: bool,
    value: ?[]const u8,
) options.FieldResult {
    switch (command.*) {
        inline else => |*payload, tag| {
            const command_spec = @field(commands, @tagName(tag));
            const Opts = commandSpecOptions(command_spec);
            const fields = @typeInfo(Opts).@"struct".fields;
            const has_meta = @hasDecl(Opts, "meta");
            const result = if (is_negated)
                options.setFieldNegated(Opts, fields, has_meta, if (comptime commandSpecIsBranch(command_spec)) &payload.options else payload, name)
            else
                options.setField(Opts, fields, has_meta, if (comptime commandSpecIsBranch(command_spec)) &payload.options else payload, name, value);
            switch (result) {
                .ok, .missing_value, .invalid_value => return result,
                .not_found => {},
            }
            if (comptime commandSpecIsBranch(command_spec)) {
                return setLongInSelectedCommand(command_spec.commands, &payload.command, name, is_negated, value);
            }
            return .not_found;
        },
    }
}

fn setShortInSelectedCommand(
    comptime commands: anytype,
    command: *commandUnion(commands),
    short: u8,
    value: ?[]const u8,
) options.FieldResult {
    switch (command.*) {
        inline else => |*payload, tag| {
            const command_spec = @field(commands, @tagName(tag));
            const Opts = commandSpecOptions(command_spec);
            const fields = @typeInfo(Opts).@"struct".fields;
            const has_meta = @hasDecl(Opts, "meta");
            const result = options.setFieldByShort(Opts, fields, has_meta, if (comptime commandSpecIsBranch(command_spec)) &payload.options else payload, short, value);
            switch (result) {
                .ok, .missing_value, .invalid_value => return result,
                .not_found => {},
            }
            if (comptime commandSpecIsBranch(command_spec)) {
                return setShortInSelectedCommand(command_spec.commands, &payload.command, short, value);
            }
            return .not_found;
        },
    }
}

fn discoverCommand(
    comptime G: type,
    comptime Scope: type,
    comptime commands: anytype,
    args: []const []const u8,
    start_index: usize,
) errors.ParseError!commandFound(commands) {
    const command_fields = @typeInfo(@TypeOf(commands)).@"struct".fields;

    var arg_scanner = scanner.ArgScanner.init(args, start_index);
    const resolver = CommandDiscoveryResolver(G, Scope, commands){};
    while (arg_scanner.next(resolver)) |token| {
        switch (token) {
            .help => return errors.ParseError.Help,
            .end_options => return errors.ParseError.MissingCommand,
            .option => {},
            .positional => |pos| {
                inline for (command_fields) |field| {
                    if (commandNameMatches(field.name, pos.value)) {
                        const command_spec = @field(commands, field.name);
                        if (comptime commandSpecIsBranch(command_spec)) {
                            const child = try discoverCommand(G, command_spec.options, command_spec.commands, args, pos.index + 1);
                            const payload: commandPayloadType(command_spec) = .{
                                .options = command_spec.options{},
                                .command_name = child.command_name,
                                .command_index = child.command_index,
                                .command = child.command,
                            };
                            return .{
                                .command = @unionInit(commandUnion(commands), field.name, payload),
                                .command_name = pos.value,
                                .command_index = pos.index,
                            };
                        } else {
                            return .{
                                .command = @unionInit(commandUnion(commands), field.name, command_spec{}),
                                .command_name = pos.value,
                                .command_index = pos.index,
                            };
                        }
                    }
                }
                return errors.ParseError.UnknownCommand;
            },
        }
    }

    return errors.ParseError.MissingCommand;
}

fn parseSelectedCommand(
    comptime G: type,
    comptime commands: anytype,
    global: *G,
    command: *commandUnion(commands),
    root_command_index: usize,
    args: []const []const u8,
    positionals_buf: [][]const u8,
) errors.ParseError![]const []const u8 {
    const g_fields = @typeInfo(G).@"struct".fields;
    const g_has_meta = @hasDecl(G, "meta");

    var pos_idx: usize = 0;
    var arg_scanner = scanner.ArgScanner.init(args, 0);
    const resolver = SelectedCommandResolver(G, commands){ .command = command };
    while (arg_scanner.next(resolver)) |token| {
        switch (token) {
            .help => return errors.ParseError.Help,
            .end_options => {},
            .positional => |pos| {
                if (selectedCommandIndex(commands, command, root_command_index, pos.index)) continue;
                try appendPositional(positionals_buf, &pos_idx, pos.value);
            },
            .option => |opt| {
                const g_result = switch (opt.key) {
                    .long => |name| if (opt.negated)
                        options.setFieldNegated(G, g_fields, g_has_meta, global, name)
                    else
                        options.setField(G, g_fields, g_has_meta, global, name, opt.value),
                    .short => |short| options.setFieldByShort(G, g_fields, g_has_meta, global, short, opt.value),
                };
                switch (g_result) {
                    .ok => continue,
                    .missing_value => return errors.ParseError.MissingValue,
                    .invalid_value => return errors.ParseError.InvalidValue,
                    .not_found => {},
                }

                const c_result = switch (opt.key) {
                    .long => |name| setLongInSelectedCommand(commands, command, name, opt.negated, opt.value),
                    .short => |short| setShortInSelectedCommand(commands, command, short, opt.value),
                };
                switch (c_result) {
                    .ok => {},
                    .missing_value => return errors.ParseError.MissingValue,
                    .invalid_value => return errors.ParseError.InvalidValue,
                    .not_found => return errors.ParseError.UnknownOption,
                }
            },
        }
    }

    return positionals_buf[0..pos_idx];
}

pub fn CommandParser(comptime spec: anytype) type {
    return struct {
        comptime {
            validateCommandParserSpec(spec);
        }

        const Self = @This();

        pub const Global = spec.global;
        pub const Command = commandUnion(spec.commands);

        pub const Result = struct {
            global: Global,
            command: Command,
            command_name: []const u8,
            command_index: usize,
            positionals: []const []const u8,
        };

        pub fn parse(args: []const []const u8, positionals_buf: [][]const u8) errors.ParseError!Result {
            var global = Global{};
            var found = try discoverCommand(Global, void, spec.commands, args, 0);
            const positionals = try parseSelectedCommand(Global, spec.commands, &global, &found.command, found.command_index, args, positionals_buf);
            return .{
                .global = global,
                .command = found.command,
                .command_name = found.command_name,
                .command_index = found.command_index,
                .positionals = positionals,
            };
        }

        pub fn printUsage(writer: anytype) void {
            if (@hasField(@TypeOf(spec), "name")) {
                writer.print("Usage: {s} <command> [options]\n\n", .{spec.name}) catch return;
            }
            writer.writeAll("Commands:\n") catch return;
            inline for (@typeInfo(@TypeOf(spec.commands)).@"struct".fields) |field| {
                writer.print("  {s}\n", .{field.name}) catch return;
            }
            writer.writeAll("\nGlobal options:\n") catch return;
            printFields(Global, writer);
        }

        pub fn printCommandUsage(comptime tag: std.meta.Tag(Command), writer: anytype) void {
            const command_spec = @field(spec.commands, @tagName(tag));
            if (comptime commandSpecIsBranch(command_spec)) {
                printFields(command_spec.options, writer);
            } else {
                printFields(command_spec, writer);
            }
        }
    };
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

fn parseNoPositionals(comptime T: type, opts: *T, args: []const []const u8) errors.ParseError!void {
    var positionals: [0][]const u8 = .{};
    _ = try parse(T, opts, args, &positionals);
}

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
    try parseNoPositionals(Opts, &opts, &.{ "-n", "foo", "-c", "42", "-v" });

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
    try parseNoPositionals(Opts, &opts, &.{ "--input-port", "1234", "--output-addr=192.168.1.1" });

    try std.testing.expectEqual(@as(u16, 1234), opts.input_port);
    try std.testing.expectEqualStrings("192.168.1.1", opts.output_addr);
}

test "parse returns positional args" {
    const Opts = struct {
        verbose: bool = false,

        pub const meta = .{ .verbose = .{ .short = 'v' } };
    };

    var opts = Opts{};
    var positionals: [256][]const u8 = undefined;
    const rest = try parse(Opts, &opts, &.{ "-v", "file1", "file2" }, &positionals);

    try std.testing.expect(opts.verbose);
    try std.testing.expectEqual(@as(usize, 2), rest.len);
    try std.testing.expectEqualStrings("file1", rest[0]);
}

test "positionals use caller-owned storage" {
    const Opts = struct {
        verbose: bool = false,
    };

    var first_opts = Opts{};
    var first_buf: [2][]const u8 = undefined;
    const first = try parse(Opts, &first_opts, &.{ "one", "two" }, &first_buf);

    var second_opts = Opts{};
    var second_buf: [1][]const u8 = undefined;
    _ = try parse(Opts, &second_opts, &.{"other"}, &second_buf);

    try std.testing.expectEqualStrings("one", first[0]);
    try std.testing.expectEqualStrings("two", first[1]);

    var too_small_opts = Opts{};
    var too_small: [1][]const u8 = undefined;
    try std.testing.expectError(errors.ParseError.TooManyPositionals, parse(Opts, &too_small_opts, &.{ "one", "two" }, &too_small));
}

test "help flag returns error" {
    const Opts = struct {
        name: []const u8 = "x",
    };

    var opts = Opts{};
    const result = parseNoPositionals(Opts, &opts, &.{"--help"});
    try std.testing.expectError(errors.ParseError.Help, result);
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
    try parseNoPositionals(Opts, &opts, &.{ "--config", "foo.toml", "--limit", "100" });

    try std.testing.expectEqualStrings("foo.toml", opts.config.?);
    try std.testing.expectEqual(@as(u32, 100), opts.limit.?);
}

test "enum field" {
    const Mode = enum { fast, slow, auto };
    const Opts = struct {
        mode: Mode = .auto,
    };

    var opts = Opts{};
    try parseNoPositionals(Opts, &opts, &.{ "--mode", "fast" });

    try std.testing.expectEqual(Mode.fast, opts.mode);
}

test "CommandParser finds command after valued global option" {
    const Global = struct {
        service: []const u8 = "default",
        verbose: bool = false,

        pub const meta = .{
            .service = .{ .short = 's', .help = "Service" },
            .verbose = .{ .short = 'v', .help = "Verbose" },
        };
    };
    const Restart = struct {
        force: bool = false,

        pub const meta = .{ .force = .{ .short = 'f', .help = "Force" } };
    };
    const Status = struct {};

    const Cli = CommandParser(.{
        .name = "zctl",
        .global = Global,
        .commands = .{
            .restart = Restart,
            .status = Status,
        },
    });

    var positionals: [256][]const u8 = undefined;
    const parsed = try Cli.parse(&.{ "--service", "cam", "restart", "--force", "pos" }, &positionals);
    try std.testing.expectEqualStrings("cam", parsed.global.service);
    try std.testing.expectEqualStrings("restart", parsed.command_name);
    try std.testing.expectEqual(@as(usize, 2), parsed.command_index);
    switch (parsed.command) {
        .restart => |restart| try std.testing.expect(restart.force),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(@as(usize, 1), parsed.positionals.len);
    try std.testing.expectEqualStrings("pos", parsed.positionals[0]);

    const combined = try Cli.parse(&.{ "restart", "-vf" }, &positionals);
    try std.testing.expect(combined.global.verbose);
    try std.testing.expect(combined.command.restart.force);

    const stopped = try Cli.parse(&.{ "restart", "--", "--force", "pos" }, &positionals);
    try std.testing.expect(!stopped.command.restart.force);
    try std.testing.expectEqual(@as(usize, 2), stopped.positionals.len);
    try std.testing.expectEqualStrings("--force", stopped.positionals[0]);
    try std.testing.expectEqualStrings("pos", stopped.positionals[1]);

    try std.testing.expectError(errors.ParseError.MissingCommand, Cli.parse(&.{ "--", "restart" }, &positionals));
    try std.testing.expectError(errors.ParseError.Help, Cli.parse(&.{"--help"}, &positionals));
}

test "CommandParser supports nested command groups" {
    const Global = struct {
        verbose: bool = false,
        pub const meta = .{ .verbose = .{ .short = 'v' } };
    };
    const Service = struct {
        name: []const u8 = "default",
        pub const meta = .{ .name = .{ .short = 'n' } };
    };
    const Restart = struct {
        force: bool = false,
        pub const meta = .{ .force = .{ .short = 'f' } };
    };
    const Status = struct {};

    const Cli = CommandParser(.{
        .name = "app",
        .global = Global,
        .commands = .{
            .service = .{
                .options = Service,
                .commands = .{
                    .restart = Restart,
                    .status = Status,
                },
            },
        },
    });

    var positionals: [256][]const u8 = undefined;
    const parsed = try Cli.parse(&.{ "--verbose", "service", "--name", "cam", "restart", "--force", "pos1" }, &positionals);
    try std.testing.expect(parsed.global.verbose);
    try std.testing.expectEqualStrings("service", parsed.command_name);
    try std.testing.expectEqual(@as(usize, 1), parsed.command_index);
    switch (parsed.command) {
        .service => |service| {
            try std.testing.expectEqualStrings("cam", service.options.name);
            try std.testing.expectEqualStrings("restart", service.command_name);
            try std.testing.expectEqual(@as(usize, 4), service.command_index);
            switch (service.command) {
                .restart => |restart| try std.testing.expect(restart.force),
                else => return error.TestExpectedEqual,
            }
        },
    }
    try std.testing.expectEqual(@as(usize, 1), parsed.positionals.len);
    try std.testing.expectEqualStrings("pos1", parsed.positionals[0]);

    try std.testing.expectError(errors.ParseError.MissingCommand, Cli.parse(&.{ "service", "--", "restart" }, &positionals));
}

test "repeatable option appends" {
    const Opts = struct {
        exclude: Multi([]const u8, 8) = .{},

        pub const meta = .{ .exclude = .{ .short = 'x', .help = "Exclude" } };
    };

    var opts = Opts{};
    try parseNoPositionals(Opts, &opts, &.{ "-x", "log", "-x", "pyc" });

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
    var positionals: [256][]const u8 = undefined;
    // ship --sudo zig-out/bin/wizig:/usr/bin/wizig ygs --restart 'sudo systemctl restart wizig'
    const rest = try parse(Opts, &opts, &.{ "--sudo", "src:dst", "ygs", "--restart", "cmd" }, &positionals);

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
    var positionals: [256][]const u8 = undefined;
    const rest = try parse(Opts, &opts, &.{ "-v", "--", "-not-an-option", "file" }, &positionals);

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
    try parseNoPositionals(Opts, &opts, &.{ "--no-verbose", "--debug" });

    try std.testing.expect(!opts.verbose);
    try std.testing.expect(opts.debug);
}

test "negated optional with --no-*" {
    const Opts = struct {
        config: ?[]const u8 = "default.conf",
        limit: ?u32 = 100,
    };

    var opts = Opts{};
    try parseNoPositionals(Opts, &opts, &.{ "--no-config", "--no-limit" });

    try std.testing.expectEqual(@as(?[]const u8, null), opts.config);
    try std.testing.expectEqual(@as(?u32, null), opts.limit);
}

test "negated options do not consume following positionals or commands" {
    const Opts = struct {
        config: ?[]const u8 = "default.conf",
    };

    var opts = Opts{};
    var positionals: [256][]const u8 = undefined;
    const rest = try parse(Opts, &opts, &.{ "--no-config", "file" }, &positionals);

    try std.testing.expectEqual(@as(?[]const u8, null), opts.config);
    try std.testing.expectEqual(@as(usize, 1), rest.len);
    try std.testing.expectEqualStrings("file", rest[0]);

    const Global = struct {
        config: ?[]const u8 = "default.conf",
    };
    const Run = struct {};
    const Cli = CommandParser(.{
        .global = Global,
        .commands = .{ .run = Run },
    });

    var command_positionals: [256][]const u8 = undefined;
    const parsed = try Cli.parse(&.{ "--no-config", "run" }, &command_positionals);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.global.config);
    try std.testing.expectEqualStrings("run", parsed.command_name);
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
    try parseNoPositionals(Opts, &opts, &.{"--no-compress"});

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
        try parseNoPositionals(Opts, &opts, &.{"--compress"});
        try std.testing.expectEqual(Compress.on, opts.compress);
    }

    // --compress=auto still parses the value
    {
        var opts = Opts{};
        try parseNoPositionals(Opts, &opts, &.{"--compress=off"});
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
        try parseNoPositionals(Opts, &opts, &.{"--compress"});
        try std.testing.expectEqual(Compress.on, opts.compress);
    }

    // --no-compress → .off
    {
        var opts = Opts{};
        try parseNoPositionals(Opts, &opts, &.{"--no-compress"});
        try std.testing.expectEqual(Compress.off, opts.compress);
    }

    // --compress=auto → .auto
    {
        var opts = Opts{};
        try parseNoPositionals(Opts, &opts, &.{"--compress=auto"});
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
        try parseNoPositionals(Opts, &opts, &.{ "--compress", "--verbose" });
        try std.testing.expectEqual(Compress.on, opts.compress);
        try std.testing.expect(opts.verbose);
    }

    // --compress followed by -v (not consumed as value)
    {
        var opts = Opts{};
        try parseNoPositionals(Opts, &opts, &.{ "--compress", "-v" });
        try std.testing.expectEqual(Compress.on, opts.compress);
        try std.testing.expect(opts.verbose);
    }

    // --compress at end of args
    {
        var opts = Opts{};
        try parseNoPositionals(Opts, &opts, &.{"--compress"});
        try std.testing.expectEqual(Compress.on, opts.compress);
    }

    // --level still requires value (no flag_value)
    {
        var opts = Opts{};
        const result = parseNoPositionals(Opts, &opts, &.{"--level"});
        try std.testing.expectError(errors.ParseError.MissingValue, result);
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
        try parseNoPositionals(Opts, &opts, &.{ "--chmod", "644" });
        try std.testing.expectEqual(@as(?u16, 0o644), opts.chmod);
    }

    // Another valid octal
    {
        var opts = Opts{};
        try parseNoPositionals(Opts, &opts, &.{ "--chmod", "755" });
        try std.testing.expectEqual(@as(?u16, 0o755), opts.chmod);
    }

    // Invalid octal (has 8 and 9)
    {
        var opts = Opts{};
        const result = parseNoPositionals(Opts, &opts, &.{ "--chmod", "899" });
        try std.testing.expectError(errors.ParseError.InvalidValue, result);
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
        try parseNoPositionals(Opts, &opts, &.{ "--port", "3000" });
        try std.testing.expectEqual(@as(u16, 3000), opts.port);
    }

    // Invalid (privileged port)
    {
        var opts = Opts{};
        const result = parseNoPositionals(Opts, &opts, &.{ "--port", "80" });
        try std.testing.expectError(errors.ParseError.InvalidValue, result);
    }
}

test "hyphenated positional not treated as option" {
    const Opts = struct {
        exclude: []const u8 = "",
        verbose: bool = false,

        pub const meta = .{
            .exclude = .{ .short = 'e', .help = "Exclude pattern" },
            .verbose = .{ .short = 'v', .help = "Verbose" },
        };
    };

    // "metabase-enterprise" contains "-e" but shouldn't trigger the -e short option
    {
        var opts = Opts{};
        var positionals: [256][]const u8 = undefined;
        const rest = try parse(Opts, &opts, &.{"metabase-enterprise"}, &positionals);
        try std.testing.expectEqualStrings("", opts.exclude); // -e not triggered
        try std.testing.expectEqual(@as(usize, 1), rest.len);
        try std.testing.expectEqualStrings("metabase-enterprise", rest[0]);
    }

    // Same with other options present
    {
        var opts = Opts{};
        var positionals: [256][]const u8 = undefined;
        const rest = try parse(Opts, &opts, &.{ "-v", "metabase-enterprise" }, &positionals);
        try std.testing.expect(opts.verbose);
        try std.testing.expectEqualStrings("", opts.exclude);
        try std.testing.expectEqual(@as(usize, 1), rest.len);
        try std.testing.expectEqualStrings("metabase-enterprise", rest[0]);
    }

    // Actual -e flag still works
    {
        var opts = Opts{};
        var positionals: [256][]const u8 = undefined;
        const rest = try parse(Opts, &opts, &.{ "-e", "pattern", "metabase-enterprise" }, &positionals);
        try std.testing.expectEqualStrings("pattern", opts.exclude);
        try std.testing.expectEqual(@as(usize, 1), rest.len);
        try std.testing.expectEqualStrings("metabase-enterprise", rest[0]);
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
    try parseNoPositionals(Opts, &opts, &.{"--no-chmod"});
    try std.testing.expectEqual(@as(?u16, null), opts.chmod);
}

test "combined short flags GNU-style" {
    const Opts = struct {
        verbose: bool = false,
        debug: bool = false,
        force: bool = false,
        name: []const u8 = "default",
        count: u32 = 0,

        pub const meta = .{
            .verbose = .{ .short = 'v' },
            .debug = .{ .short = 'd' },
            .force = .{ .short = 'f' },
            .name = .{ .short = 'n' },
            .count = .{ .short = 'c' },
        };
    };

    // Combined bool flags: -vdf
    {
        var opts = Opts{};
        try parseNoPositionals(Opts, &opts, &.{"-vdf"});
        try std.testing.expect(opts.verbose);
        try std.testing.expect(opts.debug);
        try std.testing.expect(opts.force);
    }

    // Combined bools followed by value option: -vdn hello
    {
        var opts = Opts{};
        try parseNoPositionals(Opts, &opts, &.{ "-vdn", "hello" });
        try std.testing.expect(opts.verbose);
        try std.testing.expect(opts.debug);
        try std.testing.expectEqualStrings("hello", opts.name);
    }

    // Combined bools with inline value: -vdnhello
    {
        var opts = Opts{};
        try parseNoPositionals(Opts, &opts, &.{"-vdnhello"});
        try std.testing.expect(opts.verbose);
        try std.testing.expect(opts.debug);
        try std.testing.expectEqualStrings("hello", opts.name);
    }

    // Value option first consumes rest: -nfoo (name="foo", not -n -f -o -o)
    {
        var opts = Opts{};
        try parseNoPositionals(Opts, &opts, &.{"-nfoo"});
        try std.testing.expect(!opts.force); // -f not triggered
        try std.testing.expectEqualStrings("foo", opts.name);
    }

    // Combined with positionals
    {
        var opts = Opts{};
        var positionals: [256][]const u8 = undefined;
        const rest = try parse(Opts, &opts, &.{ "-vf", "file1", "file2" }, &positionals);
        try std.testing.expect(opts.verbose);
        try std.testing.expect(opts.force);
        try std.testing.expectEqual(@as(usize, 2), rest.len);
        try std.testing.expectEqualStrings("file1", rest[0]);
    }

    // Single short flag still works
    {
        var opts = Opts{};
        try parseNoPositionals(Opts, &opts, &.{"-v"});
        try std.testing.expect(opts.verbose);
        try std.testing.expect(!opts.debug);
    }
}
