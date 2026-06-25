const std = @import("std");

pub const OptionArity = enum { flag, value };

pub const OptionKey = union(enum) {
    long: []const u8,
    short: u8,
};

pub const OptionToken = struct {
    index: usize,
    key: OptionKey,
    negated: bool = false,
    value: ?[]const u8 = null,
};

pub const ArgToken = union(enum) {
    help,
    end_options,
    positional: struct {
        index: usize,
        value: []const u8,
    },
    option: OptionToken,
};

/// Owns argv tokenization: dash syntax, short bundles, --, help, and value consumption.
/// Callers supply arity lookup so the scanner can stay syntax-focused while parsers
/// decide what each emitted token means.
pub const ArgScanner = struct {
    args: []const []const u8,
    i: usize = 0,
    short_i: usize = 0,
    stop_options: bool = false,
    name_buf: [64]u8 = undefined,

    pub fn init(args: []const []const u8, start_index: usize) ArgScanner {
        return .{ .args = args, .i = start_index };
    }

    fn takeNextValue(self: *ArgScanner) ?[]const u8 {
        if (self.i + 1 >= self.args.len) return null;
        const next_arg = self.args[self.i + 1];
        if (next_arg.len > 0 and next_arg[0] == '-') return null;
        self.i += 1;
        return next_arg;
    }

    pub fn next(self: *ArgScanner, resolver: anytype) ?ArgToken {
        while (self.i < self.args.len) {
            const arg = self.args[self.i];

            if (self.short_i != 0) {
                const current_index = self.i;
                const short = arg[self.short_i];
                const arity = resolver.shortArity(short);

                if (arity == .flag) {
                    self.short_i += 1;
                    if (self.short_i >= arg.len) {
                        self.short_i = 0;
                        self.i += 1;
                    }
                    return .{ .option = .{ .index = current_index, .key = .{ .short = short } } };
                }

                var value: ?[]const u8 = null;
                if (arity == .value) {
                    if (self.short_i + 1 < arg.len) {
                        value = arg[self.short_i + 1 ..];
                    } else {
                        value = self.takeNextValue();
                    }
                }

                self.short_i = 0;
                self.i += 1;
                return .{ .option = .{ .index = current_index, .key = .{ .short = short }, .value = value } };
            }

            if (arg.len == 0) {
                self.i += 1;
                continue;
            }

            const current_index = self.i;

            if (self.stop_options) {
                self.i += 1;
                return .{ .positional = .{ .index = current_index, .value = arg } };
            }

            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                self.i += 1;
                return .help;
            }

            if (std.mem.eql(u8, arg, "--")) {
                self.stop_options = true;
                self.i += 1;
                return .end_options;
            }

            if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') {
                const rest = arg[2..];
                var name: []const u8 = rest;
                var value: ?[]const u8 = null;
                var negated = false;
                var has_inline_value = false;

                if (rest.len > 3 and std.mem.startsWith(u8, rest, "no-")) {
                    negated = true;
                    name = rest[3..];
                }

                if (std.mem.indexOf(u8, name, "=")) |eq| {
                    value = name[eq + 1 ..];
                    name = name[0..eq];
                    has_inline_value = true;
                }

                const norm_name = normalizeName(name, &self.name_buf);
                if (!negated and !has_inline_value and resolver.longArity(norm_name) == .value) {
                    value = self.takeNextValue();
                }

                self.i += 1;
                return .{ .option = .{ .index = current_index, .key = .{ .long = norm_name }, .negated = negated, .value = value } };
            }

            if (arg.len >= 2 and arg[0] == '-' and arg[1] != '-') {
                self.short_i = 1;
                continue;
            }

            self.i += 1;
            return .{ .positional = .{ .index = current_index, .value = arg } };
        }

        return null;
    }
};

fn normalizeName(name: []const u8, buf: []u8) []const u8 {
    var j: usize = 0;
    for (name) |c| {
        if (j >= buf.len) break;
        buf[j] = if (c == '-') '_' else c;
        j += 1;
    }
    return buf[0..j];
}
