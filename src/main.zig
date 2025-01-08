const std = @import("std");
const tui = @import("tui");
const thespian = @import("thespian");
const flags = @import("flags");
const builtin = @import("builtin");

const bin_path = @import("bin_path.zig");
const list_languages = @import("list_languages.zig");

const c = @cImport({
    @cInclude("locale.h");
});

const build_options = @import("build_options");
const log = @import("log");

pub var max_diff_lines: usize = 50000;
pub var max_syntax_lines: usize = 50000;

pub const application_name = "flow";
pub const application_title = "Flow Control";
pub const application_subtext = "a programmer's text editor";
pub const application_description = application_title ++ ": " ++ application_subtext;

pub const std_options = .{
    // .log_level = if (builtin.mode == .Debug) .debug else .warn,
    .log_level = if (builtin.mode == .Debug) .info else .warn,
    .logFn = log.std_log_function,
};

const renderer = @import("renderer");

pub const panic = if (@hasDecl(renderer, "panic")) renderer.panic else std.builtin.default_panic;

pub fn main() anyerror!void {
    if (builtin.os.tag == .linux) {
        // drain stdin so we don't pickup junk from previous application/shell
        _ = std.os.linux.syscall3(.ioctl, @as(usize, @bitCast(@as(isize, std.posix.STDIN_FILENO))), std.os.linux.T.CFLSH, 0);
    }

    const a = std.heap.c_allocator;

    const Flags = struct {
        pub const description =
            application_title ++ ": " ++ application_subtext ++
            \\
            \\
            \\Pass in file names to be opened with an optional :LINE or :LINE:COL appended to the
            \\file name to specify a specific location, or pass +<LINE> separately to set the line.
        ;

        pub const descriptions = .{
            .frame_rate = "Set target frame rate (default: 60)",
            .debug_wait = "Wait for key press before starting UI",
            .debug_dump_on_error = "Dump stack traces on errors",
            .no_sleep = "Do not sleep the main loop when idle",
            .no_alternate = "Do not use the alternate terminal screen",
            .trace_level = "Enable internal tracing (level of detail from 1-5)",
            .no_trace = "Do not enable internal tracing",
            .restore_session = "Restore restart session",
            .show_input = "Open the input view on start",
            .show_log = "Open the log view on start",
            .language = "Force the language of the file to be opened",
            .list_languages = "Show available languages",
            .no_syntax = "Disable syntax highlighting",
            .syntax_report_timing = "Report syntax highlighting time",
            .exec = "Execute a command on startup",
            .literal = "Disable :LINE and +LINE syntax",
            .version = "Show build version and exit",
        };

        pub const formats = .{ .frame_rate = "num", .trace_level = "num", .exec = "cmds" };

        pub const switches = .{
            .frame_rate = 'f',
            .trace_level = 't',
            .language = 'l',
            .exec = 'e',
            .literal = 'L',
            .version = 'v',
        };

        frame_rate: ?usize,
        debug_wait: bool,
        debug_dump_on_error: bool,
        no_sleep: bool,
        no_alternate: bool,
        trace_level: u8 = 0,
        no_trace: bool,
        restore_session: bool,
        show_input: bool,
        show_log: bool,
        language: ?[]const u8,
        list_languages: bool,
        no_syntax: bool,
        syntax_report_timing: bool,
        exec: ?[]const u8,
        literal: bool,
        version: bool,
    };

    var arg_iter = try std.process.argsWithAllocator(a);
    defer arg_iter.deinit();

    var diag: flags.Diagnostics = undefined;
    var positional_args = std.ArrayList([]const u8).init(a);
    defer positional_args.deinit();

    const args = flags.parse(&arg_iter, "flow", Flags, .{
        .diagnostics = &diag,
        .trailing_list = &positional_args,
    }) catch |err| {
        if (err == error.PrintedHelp) exit(0);
        diag.help.generated.render(std.io.getStdOut(), flags.ColorScheme.default) catch {};
        exit(1);
        return err;
    };

    if (args.version)
        return std.io.getStdOut().writeAll(@embedFile("version_info"));

    if (args.list_languages) {
        const stdout = std.io.getStdOut();
        const tty_config = std.io.tty.detectConfig(stdout);
        return list_languages.list(a, stdout.writer(), tty_config);
    }

    if (builtin.os.tag != .windows)
        if (std.posix.getenv("JITDEBUG")) |_| thespian.install_debugger();

    if (args.debug_wait) {
        std.debug.print("press return to start", .{});
        var buf: [1]u8 = undefined;
        _ = try std.io.getStdIn().read(&buf);
    }

    if (c.setlocale(c.LC_ALL, "") == null) {
        try std.io.getStdErr().writer().print("Failed to set locale. Is your locale valid?\n", .{});
        exit(1);
    }

    thespian.stack_trace_on_errors = args.debug_dump_on_error;

    var ctx = try thespian.context.init(a);
    defer ctx.deinit();

    const env = thespian.env.init();
    defer env.deinit();
    if (build_options.enable_tracy) {
        if (!args.no_trace) {
            env.enable_all_channels();
            env.on_trace(trace);
        }
    } else {
        if (args.trace_level != 0) {
            env.enable_all_channels();
            var threshold: usize = 1;
            if (args.trace_level < threshold) {
                env.disable(thespian.channel.widget);
            }
            threshold += 1;
            if (args.trace_level < threshold) {
                env.disable(thespian.channel.receive);
            }
            threshold += 1;
            if (args.trace_level < threshold) {
                env.disable(thespian.channel.event);
            }
            threshold += 1;
            if (args.trace_level < threshold) {
                env.disable(thespian.channel.metronome);
                env.disable(thespian.channel.execute);
                env.disable(thespian.channel.link);
            }
            threshold += 1;
            if (args.trace_level < threshold) {
                env.disable(thespian.channel.input);
                env.disable(thespian.channel.send);
            }
            env.on_trace(trace_to_file);
        }
    }

    const log_proc = try log.spawn(&ctx, a, &env);
    defer log_proc.deinit();
    log.set_std_log_pid(log_proc.ref());
    defer log.set_std_log_pid(null);

    env.set("restore-session", args.restore_session);
    env.set("no-alternate", args.no_alternate);
    env.set("show-input", args.show_input);
    env.set("show-log", args.show_log);
    env.set("no-sleep", args.no_sleep);
    env.set("no-syntax", args.no_syntax);
    env.set("syntax-report-timing", args.syntax_report_timing);
    env.set("dump-stack-trace", args.debug_dump_on_error);
    if (args.frame_rate) |s| env.num_set("frame-rate", @intCast(s));
    env.proc_set("log", log_proc.ref());
    if (args.language) |s| env.str_set("language", s);

    var eh = thespian.make_exit_handler({}, print_exit_status);
    const tui_proc = try tui.spawn(a, &ctx, &eh, &env);
    defer tui_proc.deinit();

    const Dest = struct {
        file: []const u8 = "",
        line: ?usize = null,
        column: ?usize = null,
        end_column: ?usize = null,
    };
    var dests = std.ArrayList(Dest).init(a);
    defer dests.deinit();
    var prev: ?*Dest = null;
    var line_next: ?usize = null;
    for (positional_args.items) |arg| {
        if (arg.len == 0) continue;

        if (!args.literal and arg[0] == '+') {
            const line = try std.fmt.parseInt(usize, arg[1..], 10);
            if (prev) |p| {
                p.line = line;
            } else {
                line_next = line;
            }
            continue;
        }

        const curr = try dests.addOne();
        curr.* = .{};
        prev = curr;
        if (line_next) |line| {
            curr.line = line;
            line_next = null;
        }
        if (!args.literal) {
            var it = std.mem.splitScalar(u8, arg, ':');
            curr.file = it.first();
            if (it.next()) |line_|
                curr.line = std.fmt.parseInt(usize, line_, 10) catch blk: {
                    curr.file = arg;
                    break :blk null;
                };
            if (curr.line) |_| {
                if (it.next()) |col_|
                    curr.column = std.fmt.parseInt(usize, col_, 10) catch null;
                if (it.next()) |col_|
                    curr.end_column = std.fmt.parseInt(usize, col_, 10) catch null;
            }
        } else {
            curr.file = arg;
        }
    }

    var have_project = false;
    var files = std.ArrayList(Dest).init(a);
    defer files.deinit();
    for (dests.items) |dest| {
        if (dest.file.len == 0) continue;
        if (is_directory(dest.file)) {
            if (have_project) {
                std.debug.print("more than one directory is not allowed\n", .{});
                exit(1);
            }
            try tui_proc.send(.{ "cmd", "open_project_dir", .{dest.file} });

            have_project = true;
        } else {
            const curr = try files.addOne();
            curr.* = dest;
        }
    }

    for (files.items) |dest| {
        if (dest.file.len == 0) continue;

        if (dest.line) |l| {
            if (dest.column) |col| {
                try tui_proc.send(.{ "cmd", "navigate", .{ .file = dest.file, .line = l, .column = col } });
                if (dest.end_column) |end|
                    try tui_proc.send(.{ "A", l, col - 1, end - 1 });
            } else {
                try tui_proc.send(.{ "cmd", "navigate", .{ .file = dest.file, .line = l } });
            }
        } else {
            try tui_proc.send(.{ "cmd", "navigate", .{ .file = dest.file } });
        }
    } else {
        if (!have_project)
            try tui_proc.send(.{ "cmd", "open_project_cwd" });
        try tui_proc.send(.{ "cmd", "show_home" });
    }

    if (args.exec) |exec_str| {
        var cmds = std.mem.splitScalar(u8, exec_str, ';');
        while (cmds.next()) |cmd| try tui_proc.send(.{ "cmd", cmd, .{} });
    }

    ctx.run();

    if (want_restart) restart();
    exit(final_exit_status);
}

var final_exit_status: u8 = 0;
var want_restart: bool = false;

pub fn print_exit_status(_: void, msg: []const u8) void {
    if (std.mem.eql(u8, msg, "normal")) {
        return;
    } else if (std.mem.eql(u8, msg, "restart")) {
        want_restart = true;
    } else {
        std.io.getStdErr().writer().print("\n" ++ application_name ++ " ERROR: {s}\n", .{msg}) catch {};
        final_exit_status = 1;
    }
}

fn count_args() usize {
    var args = std.process.args();
    _ = args.next();
    var count: usize = 0;
    while (args.next()) |_| {
        count += 1;
    }
    return count;
}

fn trace(m: thespian.message.c_buffer_type) callconv(.C) void {
    thespian.message.from(m).to_json_cb(trace_json);
}

fn trace_json(json: thespian.message.json_string_view) callconv(.C) void {
    const callstack_depth = 10;
    ___tracy_emit_message(json.base, json.len, callstack_depth);
}
extern fn ___tracy_emit_message(txt: [*]const u8, size: usize, callstack: c_int) void;

fn trace_to_file(m: thespian.message.c_buffer_type) callconv(.C) void {
    const cbor = @import("cbor");
    const State = struct {
        file: std.fs.File,
        last_time: i64,
        var state: ?@This() = null;

        fn write_tdiff(writer: anytype, tdiff: i64) !void {
            const msi = @divFloor(tdiff, std.time.us_per_ms);
            if (msi < 10) {
                const d: f64 = @floatFromInt(tdiff);
                const ms = d / std.time.us_per_ms;
                _ = try writer.print("{d:6.2} ", .{ms});
            } else {
                const ms: u64 = @intCast(msi);
                _ = try writer.print("{d:6} ", .{ms});
            }
        }
    };
    var state: *State = &(State.state orelse init: {
        const a = std.heap.c_allocator;
        var path = std.ArrayList(u8).init(a);
        defer path.deinit();
        path.writer().print("{s}/trace.log", .{get_state_dir() catch return}) catch return;
        const file = std.fs.createFileAbsolute(path.items, .{ .truncate = true }) catch return;
        State.state = .{
            .file = file,
            .last_time = std.time.microTimestamp(),
        };
        break :init State.state.?;
    });
    const file_writer = state.file.writer();
    var buffer = std.io.bufferedWriter(file_writer);
    const writer = buffer.writer();

    const ts = std.time.microTimestamp();
    State.write_tdiff(writer, ts - state.last_time) catch {};
    state.last_time = ts;

    var stream = std.json.writeStream(writer, .{});
    var iter: []const u8 = m.base[0..m.len];
    cbor.JsonStream(@TypeOf(buffer)).jsonWriteValue(&stream, &iter) catch {};
    _ = writer.write("\n") catch {};
    buffer.flush() catch {};
}

pub fn exit(status: u8) noreturn {
    if (builtin.os.tag == .linux) {
        // drain stdin so we don't leave junk at the next prompt
        _ = std.os.linux.syscall3(.ioctl, @as(usize, @bitCast(@as(isize, std.posix.STDIN_FILENO))), std.os.linux.T.CFLSH, 0);
    }
    std.posix.exit(status);
}

pub fn free_config(Config: type, allocator: std.mem.Allocator, conf: *Config) void {
    const FieldEnum = std.meta.FieldEnum(Config);
    inline for (std.meta.fields(Config)) |field| {
        free_config_value(Config, allocator, conf, @field(FieldEnum, field.name));
    }
}

pub fn free_config_value(
    Config: type,
    allocator: std.mem.Allocator,
    conf: *Config,
    comptime field_enum: std.meta.FieldEnum(Config),
) void {
    const field = std.meta.fieldInfo(Config, field_enum);
    const default = get_field_default(field);
    if (config_eql(field.type, default, @field(conf, field.name))) return;
    defer @field(conf, field.name) = default;
    switch (field.type) {
        []const u8 => return allocator.free(@field(conf, field.name)),
        else => {},
    }
    switch (@typeInfo(field.type)) {
        .Bool, .Int => return,
        else => {},
    }
    @compileError("unsupported config type " ++ @typeName(field.type));
}

var config_mutex: std.Thread.Mutex = .{};

fn config_value_fmt(comptime T: type) []const u8 {
    switch (T) {
        []const u8 => return "s",
        else => {},
    }
    switch (@typeInfo(T)) {
        .Bool, .Int => return "",
        else => {},
    }
    @compileError("unsupported config type " ++ @typeName(T));
}

pub fn read_config(T: type, allocator: std.mem.Allocator) T {
    config_mutex.lock();
    defer config_mutex.unlock();
    const file_name = get_app_config_file_name(application_name, @typeName(T)) catch return .{};
    var conf: T = .{};
    read_config_file(T, allocator, &conf, file_name);
    read_nested_include_files(T, allocator, &conf);
    return conf;
}

fn read_config_file(Config: type, allocator: std.mem.Allocator, conf: *Config, file_name: []const u8) void {
    const FieldEnum = std.meta.FieldEnum(Config);
    var file = std.fs.openFileAbsolute(file_name, .{ .mode = .read_only }) catch |e| return std.log.err(
        "open config file '{s}' failed with {s}",
        .{ file_name, @errorName(e) },
    );
    defer file.close();
    std.log.info("loading config '{s}'", .{file_name});
    const content = file.readToEndAlloc(allocator, 64 * 1024) catch |e| return std.log.err(
        "read config file '{s}' failed with {s}",
        .{ file_name, @errorName(e) },
    );
    defer allocator.free(content);

    var line_it = std.mem.splitScalar(u8, content, '\n');
    var lineno: u32 = 0;
    while (line_it.next()) |line_full| {
        lineno += 1;
        const line = std.mem.trim(u8, line_full, &std.ascii.whitespace);
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;
        const name = line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse line.len];
        const value_str = std.mem.trim(u8, line[name.len..], &std.ascii.whitespace);

        var known_config = false;
        inline for (std.meta.fields(Config)) |field| {
            const field_enum = @field(FieldEnum, field.name);
            if (std.mem.eql(u8, field.name, name)) {
                if (parse_config_value(Config, allocator, field_enum, value_str)) |value| {
                    free_config_value(Config, allocator, conf, field_enum);
                    @field(conf, field.name) = value;
                    std.log.info(
                        "config {s} {" ++ config_value_fmt(field.type) ++ "}",
                        .{ name, value },
                    );
                } else |err| switch (err) {
                    error.InvalidConfigValue => {
                        std.log.err(
                            "{s}:{}: config {s} has invalid value '{s}'",
                            .{ file_name, lineno, field.name, value_str },
                        );
                    },
                }
                known_config = true;
                break;
            }
        }
        if (!known_config) {
            std.log.err("{s}:{}: unknown config: {s}", .{ file_name, lineno, line });
        }
    }
}

pub fn get_config_default(
    comptime Config: type,
    field: std.meta.FieldEnum(Config),
) std.meta.fieldInfo(Config, field).type {
    return get_field_default(std.meta.fieldInfo(Config, field));
}

fn get_field_default(field: std.builtin.Type.StructField) field.type {
    const default = field.default_value orelse @compileError(
        "field " ++ field.name ++ " does not have a default value",
    );
    return @as(*const field.type, @alignCast(@ptrCast(default))).*;
}

fn parse_config_value(
    Config: type,
    allocator: std.mem.Allocator,
    comptime field_enum: std.meta.FieldEnum(Config),
    str: []const u8,
) error{InvalidConfigValue}!std.meta.fieldInfo(Config, field_enum).type {
    const field = std.meta.fieldInfo(Config, field_enum);
    switch (field.type) {
        []const u8 => {
            const default = get_field_default(field);
            if (std.mem.eql(u8, default, str)) return default;
            return allocator.dupe(u8, str) catch @panic("OOM:parse_config_value");
        },
        else => {},
    }
    switch (@typeInfo(field.type)) {
        .Bool => {
            if (std.mem.eql(u8, str, "true")) return true;
            if (std.mem.eql(u8, str, "false")) return false;
            return error.InvalidConfigValue;
        },
        .Int => return std.fmt.parseInt(field.type, str, 10) catch return error.InvalidConfigValue,
        else => {},
    }
    @compileError("unsupported config type " ++ @typeName(field.type));
}

fn read_nested_include_files(T: type, allocator: std.mem.Allocator, conf: *T) void {
    if (conf.include_files.len == 0) return;
    var it = std.mem.splitScalar(u8, conf.include_files, std.fs.path.delimiter);
    while (it.next()) |path| read_config_file(T, allocator, conf, path);
}

pub fn write_config(conf: anytype) !void {
    config_mutex.lock();
    defer config_mutex.unlock();
    return write_config_file(@TypeOf(conf), conf, try get_app_config_file_name(application_name, @typeName(@TypeOf(conf))));
}

fn write_config_file(comptime Config: type, conf: Config, file_name: []const u8) !void {
    var file = try std.fs.createFileAbsolute(file_name, .{ .truncate = true });
    defer file.close();

    inline for (std.meta.fields(Config)) |field| {
        const is_default = config_eql(
            field.type,
            get_field_default(field),
            @field(conf, field.name),
        );
        const comment_prefix: []const u8 = if (is_default) "# " else "";
        try file.writer().print(
            "{s}{s} {" ++ config_value_spec(field.type) ++ "}\n",
            .{ comment_prefix, field.name, @field(conf, field.name) },
        );
    }
}

fn config_eql(comptime T: type, a: T, b: T) bool {
    switch (T) {
        []const u8 => return std.mem.eql(u8, a, b),
        else => {},
    }
    switch (@typeInfo(T)) {
        .Bool, .Int => return a == b,
        else => {},
    }
    @compileError("unsupported config type " ++ @typeName(T));
}

pub fn read_keybind_namespace(allocator: std.mem.Allocator, namespace_name: []const u8) ?[]const u8 {
    const file_name = get_keybind_namespace_file_name(namespace_name) catch return null;
    var file = std.fs.openFileAbsolute(file_name, .{ .mode = .read_only }) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024) catch null;
}

pub fn write_keybind_namespace(namespace_name: []const u8, content: []const u8) !void {
    const file_name = try get_keybind_namespace_file_name(namespace_name);
    var file = try std.fs.createFileAbsolute(file_name, .{ .truncate = true });
    defer file.close();
    return file.writeAll(content);
}

pub fn list_keybind_namespaces(allocator: std.mem.Allocator) ![]const []const u8 {
    var dir = try std.fs.openDirAbsolute(try get_keybind_namespaces_directory(), .{ .iterate = true });
    defer dir.close();
    var result = std.ArrayList([]const u8).init(allocator);
    var iter = dir.iterateAssumeFirstIteration();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file, .sym_link => try result.append(try allocator.dupe(u8, std.fs.path.stem(entry.name))),
            else => continue,
        }
    }
    return result.toOwnedSlice();
}

pub fn get_config_dir() ![]const u8 {
    return get_app_config_dir(application_name);
}

fn get_app_config_dir(appname: []const u8) ![]const u8 {
    const a = std.heap.c_allocator;
    const local = struct {
        var config_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var config_dir: ?[]const u8 = null;
    };
    const config_dir = if (local.config_dir) |dir|
        dir
    else if (std.process.getEnvVarOwned(a, "XDG_CONFIG_HOME") catch null) |xdg| ret: {
        defer a.free(xdg);
        break :ret try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/{s}", .{ xdg, appname });
    } else if (std.process.getEnvVarOwned(a, "HOME") catch null) |home| ret: {
        defer a.free(home);
        const dir = try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/.config", .{home});
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        break :ret try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/.config/{s}", .{ home, appname });
    } else if (builtin.os.tag == .windows) ret: {
        if (std.process.getEnvVarOwned(a, "APPDATA") catch null) |appdata| {
            defer a.free(appdata);
            const dir = try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/{s}", .{ appdata, appname });
            std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
            break :ret dir;
        } else return error.AppConfigDirUnavailable;
    } else return error.AppConfigDirUnavailable;

    local.config_dir = config_dir;
    std.fs.makeDirAbsolute(config_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    var keybind_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
    std.fs.makeDirAbsolute(try std.fmt.bufPrint(&keybind_dir_buffer, "{s}/{s}", .{ config_dir, keybind_dir })) catch {};

    return config_dir;
}

pub fn get_cache_dir() ![]const u8 {
    return get_app_cache_dir(application_name);
}

fn get_app_cache_dir(appname: []const u8) ![]const u8 {
    const a = std.heap.c_allocator;
    const local = struct {
        var cache_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var cache_dir: ?[]const u8 = null;
    };
    const cache_dir = if (local.cache_dir) |dir|
        dir
    else if (std.process.getEnvVarOwned(a, "XDG_CACHE_HOME") catch null) |xdg| ret: {
        defer a.free(xdg);
        break :ret try std.fmt.bufPrint(&local.cache_dir_buffer, "{s}/{s}", .{ xdg, appname });
    } else if (std.process.getEnvVarOwned(a, "HOME") catch null) |home| ret: {
        defer a.free(home);
        const dir = try std.fmt.bufPrint(&local.cache_dir_buffer, "{s}/.cache", .{home});
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        break :ret try std.fmt.bufPrint(&local.cache_dir_buffer, "{s}/.cache/{s}", .{ home, appname });
    } else if (builtin.os.tag == .windows) ret: {
        if (std.process.getEnvVarOwned(a, "APPDATA") catch null) |appdata| {
            defer a.free(appdata);
            const dir = try std.fmt.bufPrint(&local.cache_dir_buffer, "{s}/{s}", .{ appdata, appname });
            std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
            break :ret dir;
        } else return error.AppCacheDirUnavailable;
    } else return error.AppCacheDirUnavailable;

    local.cache_dir = cache_dir;
    std.fs.makeDirAbsolute(cache_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return cache_dir;
}

pub fn get_state_dir() ![]const u8 {
    return get_app_state_dir(application_name);
}

fn get_app_state_dir(appname: []const u8) ![]const u8 {
    const a = std.heap.c_allocator;
    const local = struct {
        var state_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var state_dir: ?[]const u8 = null;
    };
    const state_dir = if (local.state_dir) |dir|
        dir
    else if (std.process.getEnvVarOwned(a, "XDG_STATE_HOME") catch null) |xdg| ret: {
        defer a.free(xdg);
        break :ret try std.fmt.bufPrint(&local.state_dir_buffer, "{s}/{s}", .{ xdg, appname });
    } else if (std.process.getEnvVarOwned(a, "HOME") catch null) |home| ret: {
        defer a.free(home);
        var dir = try std.fmt.bufPrint(&local.state_dir_buffer, "{s}/.local", .{home});
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        dir = try std.fmt.bufPrint(&local.state_dir_buffer, "{s}/.local/state", .{home});
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        break :ret try std.fmt.bufPrint(&local.state_dir_buffer, "{s}/.local/state/{s}", .{ home, appname });
    } else if (builtin.os.tag == .windows) ret: {
        if (std.process.getEnvVarOwned(a, "APPDATA") catch null) |appdata| {
            defer a.free(appdata);
            const dir = try std.fmt.bufPrint(&local.state_dir_buffer, "{s}/{s}", .{ appdata, appname });
            std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
            break :ret dir;
        } else return error.AppCacheDirUnavailable;
    } else return error.AppCacheDirUnavailable;

    local.state_dir = state_dir;
    std.fs.makeDirAbsolute(state_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return state_dir;
}

fn get_app_config_file_name(appname: []const u8, comptime base_name: []const u8) ![]const u8 {
    return get_app_config_dir_file_name(appname, base_name);
}

fn get_app_config_dir_file_name(appname: []const u8, comptime config_file_name: []const u8) ![]const u8 {
    const local = struct {
        var config_file_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    return std.fmt.bufPrint(&local.config_file_buffer, "{s}/{s}", .{ try get_app_config_dir(appname), config_file_name });
}

pub fn get_config_file_name(T: type) ![]const u8 {
    return get_app_config_file_name(application_name, @typeName(T));
}

pub fn get_restore_file_name() ![]const u8 {
    const local = struct {
        var restore_file_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var restore_file: ?[]const u8 = null;
    };
    const restore_file_name = "restore";
    const restore_file = if (local.restore_file) |file|
        file
    else
        try std.fmt.bufPrint(&local.restore_file_buffer, "{s}/{s}", .{ try get_app_cache_dir(application_name), restore_file_name });
    local.restore_file = restore_file;
    return restore_file;
}

const keybind_dir = "keys";

fn get_keybind_namespaces_directory() ![]const u8 {
    const local = struct {
        var dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    const a = std.heap.c_allocator;
    if (std.process.getEnvVarOwned(a, "FLOW_KEYS_DIR") catch null) |dir| {
        defer a.free(dir);
        return try std.fmt.bufPrint(&local.dir_buffer, "{s}", .{dir});
    }
    return try std.fmt.bufPrint(&local.dir_buffer, "{s}/{s}", .{ try get_app_config_dir(application_name), keybind_dir });
}

pub fn get_keybind_namespace_file_name(namespace_name: []const u8) ![]const u8 {
    const dir = try get_keybind_namespaces_directory();
    const local = struct {
        var file_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    return try std.fmt.bufPrint(&local.file_buffer, "{s}/{s}.json", .{ dir, namespace_name });
}

fn restart() noreturn {
    var executable: [:0]const u8 = std.mem.span(std.os.argv[0]);
    var is_basename = true;
    for (executable) |char| if (std.fs.path.isSep(char)) {
        is_basename = false;
    };
    if (is_basename) {
        const a = std.heap.c_allocator;
        executable = bin_path.find_binary_in_path(a, executable) catch executable orelse executable;
    }
    const argv = [_]?[*:0]const u8{
        executable,
        "--restore-session",
        null,
    };
    const ret = std.c.execve(executable, @ptrCast(&argv), @ptrCast(std.os.environ));
    std.io.getStdErr().writer().print("\nrestart failed: {d}", .{ret}) catch {};
    exit(234);
}

pub fn is_directory(rel_path: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = std.fs.cwd().realpath(rel_path, &path_buf) catch return false;
    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch return false;
    dir.close();
    return true;
}

pub fn shorten_path(buf: []u8, path: []const u8, removed_prefix: *usize, max_len: usize) []const u8 {
    removed_prefix.* = 0;
    if (path.len <= max_len) return path;
    const ellipsis = "…";
    const prefix = path.len - max_len;
    defer removed_prefix.* = prefix - 1;
    @memcpy(buf[0..ellipsis.len], ellipsis);
    @memcpy(buf[ellipsis.len .. max_len + ellipsis.len], path[prefix..]);
    return buf[0 .. max_len + ellipsis.len];
}

pub fn abbreviate_home(buf: []u8, path: []const u8) []const u8 {
    const a = std.heap.c_allocator;
    if (builtin.os.tag == .windows) return path;
    if (!std.fs.path.isAbsolute(path)) return path;
    const homedir = std.posix.getenv("HOME") orelse return path;
    const homerelpath = std.fs.path.relative(a, homedir, path) catch return path;
    defer a.free(homerelpath);
    if (homerelpath.len == 0) {
        return "~";
    } else if (homerelpath.len > 3 and std.mem.eql(u8, homerelpath[0..3], "../")) {
        return path;
    } else {
        buf[0] = '~';
        buf[1] = '/';
        @memcpy(buf[2 .. homerelpath.len + 2], homerelpath);
        return buf[0 .. homerelpath.len + 2];
    }
}
