//TODO figure out how keybindings should be configured

//TODO figure out how to handle bindings that can take a numerical prefix

const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const builtin = @import("builtin");

const renderer = @import("renderer");
const key = @import("renderer").input.key;
const mod = @import("renderer").input.modifier;
const event_type = @import("renderer").input.event_type;
const command = @import("command");
const EventHandler = @import("EventHandler");

pub const mode = struct {
    pub const input = struct {
        pub const flow = Handler("flow", "normal");
        pub const home = Handler("home", "normal");
        pub const vim = struct {
            pub const normal = Handler("vim", "normal");
            pub const insert = Handler("vim", "insert");
            pub const visual = Handler("vim", "visual");
        };
        pub const helix = struct {
            pub const normal = Handler("helix", "normal");
            pub const insert = Handler("helix", "insert");
            pub const visual = Handler("helix", "select");
        };
    };
    pub const overlay = struct {
        pub const palette = Handler("overlay", "palette");
    };
    pub const mini = struct {
        pub const goto = Handler("mini", "goto");
        pub const move_to_char = Handler("mini", "move_to_char");
        pub const file_browser = Handler("mini", "file_browser");
        pub const find_in_files = Handler("mini", "find_in_files");
        pub const find = Handler("mini", "find");
    };
};

fn Handler(namespace_name: []const u8, mode_name: []const u8) type {
    return struct {
        allocator: std.mem.Allocator,
        bindings: *Bindings,
        pub fn create(allocator: std.mem.Allocator, _: anytype) !EventHandler {
            const self: *@This() = try allocator.create(@This());
            self.* = .{
                .allocator = allocator,
                .bindings = try Bindings.init(allocator),
            };
            try self.bindings.loadJson(@embedFile("keybindings.json"));
            try self.bindings.selectNamespace(namespace_name);
            try self.bindings.selectMode(mode_name);
            return EventHandler.to_owned(self);
        }
        pub fn deinit(self: *@This()) void {
            self.bindings.deinit();
            self.allocator.destroy(self);
        }
        pub fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) error{Exit}!bool {
            return self.bindings.activeMode().receive(from, m);
        }
        pub const hints = KeybindHints.initComptime(.{});
    };
}

pub const Mode = struct {
    input_handler: EventHandler,
    event_handler: ?EventHandler = null,

    name: []const u8 = "",
    line_numbers: enum { absolute, relative } = .absolute,
    keybind_hints: ?*const KeybindHints = null,
    cursor_shape: renderer.CursorShape = .block,

    pub fn deinit(self: *Mode) void {
        self.input_handler.deinit();
        if (self.event_handler) |eh| eh.deinit();
    }
};

pub const KeybindHints = std.static_string_map.StaticStringMap([]const u8);

//A single key event, such as Ctrl-E
const KeyEvent = struct {
    key: u32 = 0, //keypress value
    event_type: usize = event_type.PRESS,
    modifiers: u32 = 0,

    fn eql(self: @This(), other: @This()) bool {
        return std.meta.eql(self, other);
    }

    fn toString(self: @This(), allocator: std.mem.Allocator) String {
        //TODO implement
        _ = self;
        _ = allocator;
        return "";
    }
};

fn peek(str: []const u8, i: usize) !u8 {
    if (i + 1 < str.len) {
        return str[i + 1];
    } else return error.outOfBounds;
}

const Sequence = std.ArrayList(KeyEvent);

pub fn parseKeySequence(result: *Sequence, str: []const u8) !void {
    const State = enum {
        base,
        escape_sequence_start,
        escape_sequence_delimiter,
        char_or_key_or_modifier,
        modifier,
        escape_sequence_end,
        function_key,
        tab,
        space,
        del,
        cr,
        esc,
        up,
        down,
        left,
        right,
    };
    var state: State = .base;
    var function_key_number: u8 = 0;
    var modifiers: u32 = 0;

    var i: usize = 0;
    while (i < str.len) {
        switch (state) {
            .base => {
                switch (str[i]) {
                    '<' => {
                        state = .escape_sequence_start;
                        i += 1;
                    },
                    'a'...'z', ';', '0'...'9' => {
                        try result.append(.{ .key = str[i] });
                        i += 1;
                    },
                    else => {
                        return error.parseBase;
                    },
                }
            },
            .escape_sequence_start => {
                switch (str[i]) {
                    'A' => {
                        state = .modifier;
                    },
                    'C' => {
                        switch (try peek(str, i)) {
                            'R' => {
                                state = .cr;
                            },
                            '-' => {
                                state = .modifier;
                            },
                            else => {
                                return error.parseEscapeSequenceStartC;
                            },
                        }
                    },
                    'S' => {
                        switch (try peek(str, i)) {
                            '-' => {
                                state = .modifier;
                            },
                            'p' => {
                                state = .space;
                            },
                            else => return error.parseEscapeSequenceStartS,
                        }
                    },
                    'F' => {
                        state = .function_key;
                        i += 1;
                    },
                    'T' => {
                        state = .tab;
                    },
                    'U' => {
                        state = .up;
                    },
                    'L' => {
                        state = .left;
                    },
                    'R' => {
                        state = .right;
                    },
                    'E' => {
                        state = .esc;
                    },
                    'D' => {
                        switch (try peek(str, i)) {
                            'o' => {
                                state = .down;
                            },
                            '-' => {
                                state = .modifier;
                            },
                            'e' => {
                                state = .del;
                            },
                            else => return error.parseEscapeSequenceStartD,
                        }
                    },
                    else => {
                        std.debug.print("str: {s}, i: {}\n", .{ str, i });
                        return error.parseEscapeSequenceStart;
                    },
                }
            },
            .cr => {
                if (std.mem.indexOf(u8, str[i..], "CR") == 0) {
                    try result.append(.{ .key = key.ENTER, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 2;
                } else return error.parseCR;
            },
            .space => {
                if (std.mem.indexOf(u8, str[i..], "Space") == 0) {
                    try result.append(.{ .key = key.SPACE, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 5;
                } else {
                    std.debug.print("str: {s}, i: {}, char: {}\n", .{ str, i, str[i] });
                    return error.parseSpace;
                }
            },
            .del => {
                if (std.mem.indexOf(u8, str[i..], "Del") == 0) {
                    try result.append(.{ .key = key.DEL, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 3;
                } else return error.parseDel;
            },
            .tab => {
                if (std.mem.indexOf(u8, str[i..], "Tab") == 0) {
                    try result.append(.{ .key = key.TAB, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 3;
                } else return error.parseTab;
            },
            .up => {
                if (std.mem.indexOf(u8, str[i..], "Up") == 0) {
                    try result.append(.{ .key = key.UP, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 2;
                } else return error.parseSpace;
            },
            .esc => {
                if (std.mem.indexOf(u8, str[i..], "Esc") == 0) {
                    try result.append(.{ .key = key.ESC, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 3;
                } else return error.parseEsc;
            },
            .down => {
                if (std.mem.indexOf(u8, str[i..], "Down") == 0) {
                    try result.append(.{ .key = key.DOWN, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 4;
                } else return error.parseDown;
            },
            .left => {
                if (std.mem.indexOf(u8, str[i..], "Left") == 0) {
                    try result.append(.{ .key = key.LEFT, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 4;
                } else return error.parseLeft;
            },
            .right => {
                if (std.mem.indexOf(u8, str[i..], "Right") == 0) {
                    try result.append(.{ .key = key.RIGHT, .modifiers = modifiers });
                    modifiers = 0;
                    state = .escape_sequence_end;
                    i += 5;
                } else return error.parseRight;
            },
            .function_key => {
                switch (str[i]) {
                    '0'...'9' => {
                        function_key_number *= 10;
                        function_key_number += str[i] - '0';
                        if (function_key_number < 1 or function_key_number > 35) {
                            std.debug.print("function_key_number: {}\n", .{function_key_number});
                            return error.FunctionKeyNumber;
                        }
                        i += 1;
                    },
                    '>' => {
                        const function_key = key.F01 - 1 + function_key_number;
                        try result.append(.{ .key = function_key, .modifiers = modifiers });
                        modifiers = 0;
                        function_key_number = 0;
                        state = .base;
                        i += 1;
                    },
                    else => return error.parseFunctionKey,
                }
            },
            .escape_sequence_delimiter => {
                switch (str[i]) {
                    '-' => {
                        state = .char_or_key_or_modifier;
                        i += 1;
                    },
                    else => {
                        return error.parseEscapeSequenceDelimiter;
                    },
                }
            },
            .char_or_key_or_modifier => {
                switch (str[i]) {
                    'a'...'z', ';', '0'...'9' => {
                        try result.append(.{ .key = str[i], .modifiers = modifiers });
                        modifiers = 0;
                        state = .escape_sequence_end;
                        i += 1;
                    },
                    else => {
                        state = .escape_sequence_start;
                    },
                }
            },
            .modifier => {
                modifiers |= switch (str[i]) {
                    'A' => mod.ALT,
                    'C' => mod.CTRL,
                    'D' => mod.SUPER,
                    'S' => mod.SHIFT,
                    else => return error.parseModifier,
                };

                state = .escape_sequence_delimiter;
                i += 1;
            },
            .escape_sequence_end => {
                switch (str[i]) {
                    '>' => {
                        state = .base;
                        i += 1;
                    },
                    else => {
                        return error.parseEscapeSequenceEnd;
                    },
                }
            },
        }
    }
}

const String = std.ArrayList(u8);

//An association of an command with a triggering key chord
const Binding = struct {
    keys: Sequence,
    command: String,
    args: std.ArrayList(u8),

    fn len(self: Binding) usize {
        return self.keys.items.len;
    }

    fn execute(self: @This()) !void {
        try command.executeName(self.command.items, .{ .args = .{ .buf = self.args.items } });
    }

    const MatchResult = enum { match_impossible, match_possible, matched };

    fn match(self: *const @This(), keys: []const KeyEvent) MatchResult {
        return matchKeySequence(self.keys.items, keys);
    }

    fn matchKeySequence(self: []const KeyEvent, keys: []const KeyEvent) MatchResult {
        if (self.len == 0) {
            return .match_impossible;
        }
        for (keys, 0..) |key_event, i| {
            if (!key_event.eql(self[i])) {
                return .match_impossible;
            }
        }

        if (keys.len >= self.len) {
            return .matched;
        } else {
            return .match_possible;
        }
    }

    fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .keys = Sequence.init(allocator),
            .command = String.init(allocator),
            .args = std.ArrayList(u8).init(allocator),
        };
    }

    fn deinit(self: *const @This()) void {
        self.keys.deinit();
        self.command.deinit();
        self.args.deinit();
    }
};

const Hint = struct {
    keys: []const u8,
    command: []const u8,
    description: []const u8,
};

//A Collection of keybindings
const BindingSet = struct {
    allocator: std.mem.Allocator,
    bindings: std.ArrayList(Binding),
    on_match_failure: OnMatchFailure = .ignore,
    current_sequence: std.ArrayList(KeyEvent),
    current_sequence_egc: std.ArrayList(u8),
    last_key_event_timestamp_ms: i64 = 0,
    input_buffer: std.ArrayList(u8),

    const OnMatchFailure = enum { insert, ignore };

    const JsonConfig = struct {
        bindings: []const []const []const u8,
        on_match_failure: OnMatchFailure,

        fn toMode(self: *const @This(), allocator: std.mem.Allocator) !*BindingSet {
            var result = try init(allocator);
            result.on_match_failure = self.on_match_failure;
            var state: enum { key_event, command, args } = .key_event;
            for (self.bindings) |entry| {
                var binding = Binding.init(allocator);
                var args = std.ArrayList(String).init(allocator);
                defer {
                    for (args.items) |arg| arg.deinit();
                    args.deinit();
                }
                for (entry) |token| {
                    switch (state) {
                        .key_event => {
                            try parseKeySequence(&binding.keys, token);
                            state = .command;
                        },
                        .command => {
                            binding.command = String.init(allocator);
                            try binding.command.appendSlice(token);
                            state = .args;
                        },
                        .args => {
                            var arg = String.init(allocator);
                            try arg.appendSlice(token);
                            try args.append(arg);
                        },
                    }
                }
                var args_cbor = std.ArrayList(u8).init(allocator);
                defer args_cbor.deinit();
                const writer = args_cbor.writer();
                try cbor.writeArrayHeader(writer, args.items.len);
                for (args.items) |arg| try cbor.writeValue(writer, arg.items);
                try binding.args.appendSlice(args_cbor.items);
                try result.bindings.append(binding);
            }
            return result;
        }
    };

    fn hints(self: *@This()) ![]const Hint {
        if (self.hints == null) {
            self.hints = try std.ArrayList(Hint).init(self.allocator);
        }

        if (self.hints.?.len == self.bindings.items.len) {
            return self.hints.?.items;
        } else {
            self.hints.?.clearRetainingCapacity();
            for (self.bindings.items) |binding| {
                const hint: Hint = .{
                    .keys = binding.KeyEvent.toString(self.allocator),
                    .command = binding.command,
                    .description = "", //TODO lookup command description here
                };
                try self.hints.?.append(hint);
            }
            return self.hints.?.items;
        }
    }

    fn init(allocator: std.mem.Allocator) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .current_sequence = try std.ArrayList(KeyEvent).initCapacity(allocator, 16),
            .current_sequence_egc = try std.ArrayList(u8).initCapacity(allocator, 16),
            .last_key_event_timestamp_ms = std.time.milliTimestamp(),
            .input_buffer = try std.ArrayList(u8).initCapacity(allocator, 16),
            .bindings = std.ArrayList(Binding).init(allocator),
        };
        return self;
    }

    fn deinit(self: *const BindingSet) void {
        for (self.bindings.items) |binding| {
            binding.deinit();
        }
        self.bindings.deinit();
        self.current_sequence.deinit();
        self.current_sequence_egc.deinit();
        self.input_buffer.deinit();
        self.allocator.destroy(self);
    }

    //  fn parseBindingList(self: *@This(), str: []const u8) !void {
    // var iter = std.mem.tokenizeAny(u8, str, &.{'\n'});
    // while (iter.next()) |token| {
    // try self.bindings.append(try parseBinding(self.allocator, token));
    // }
    // }

    fn cmd(self: *@This(), name_: []const u8, ctx: command.Context) tp.result {
        try self.flushInputBuffer();
        self.last_cmd = name_;
        if (builtin.is_test == false) {
            try command.executeName(name_, ctx);
        }
    }

    const max_key_sequence_time_interval = 750;
    const max_input_buffer_size = 1024;

    fn insertBytes(self: *@This(), bytes: []const u8) !void {
        if (self.input_buffer.items.len + 4 > max_input_buffer_size)
            try self.flushInputBuffer();
        try self.input_buffer.appendSlice(bytes);
    }

    fn flushInputBuffer(self: *@This()) !void {
        const Static = struct {
            var insert_chars_id: ?command.ID = null;
        };
        if (self.input_buffer.items.len > 0) {
            defer self.input_buffer.clearRetainingCapacity();
            const id = Static.insert_chars_id orelse
                command.get_id_cache("insert_chars", &Static.insert_chars_id) orelse {
                return tp.exit_error(error.InputTargetNotFound, null);
            };
            if (builtin.is_test == false) {
                try command.execute(id, command.fmt(.{self.input_buffer.items}));
            }
        }
    }

    fn receive(self: *@This(), _: tp.pid_ref, m: tp.message) error{Exit}!bool {
        var evtype: u32 = 0;
        var keypress: u32 = 0;
        var egc: u32 = 0;
        var modifiers: u32 = 0;
        var text: []const u8 = "";

        if (try m.match(.{
            "I",
            tp.extract(&evtype),
            tp.extract(&keypress),
            tp.extract(&egc),
            tp.string,
            tp.extract(&modifiers),
        })) {
            self.registerKeyEvent(@intCast(egc), .{
                .event_type = evtype,
                .key = keypress,
                .modifiers = modifiers,
            }) catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{"F"})) {
            self.flushInputBuffer() catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "system_clipboard", tp.extract(&text) })) {
            self.flushInputBuffer() catch |e| return tp.exit_error(e, @errorReturnTrace());
            self.insertBytes(text) catch |e| return tp.exit_error(e, @errorReturnTrace());
            self.flushInputBuffer() catch |e| return tp.exit_error(e, @errorReturnTrace());
        }
        return false;
    }

    //register a key press and try to match it with a binding
    fn registerKeyEvent(self: *BindingSet, egc: u8, event: KeyEvent) !void {

        //clear key history if enough time has passed since last key press
        const timestamp = std.time.milliTimestamp();
        if (self.last_key_event_timestamp_ms - timestamp > max_key_sequence_time_interval) {
            try self.abortCurrentSequence(.timeout, egc, event);
        }
        self.last_key_event_timestamp_ms = timestamp;

        try self.current_sequence.append(event);
        try self.current_sequence_egc.append(egc);

        var all_matches_impossible = true;
        for (self.bindings.items) |binding| blk: {
            switch (binding.match(self.current_sequence.items)) {
                .matched => {
                    if (!builtin.is_test) {
                        try binding.execute();
                    }
                    self.current_sequence.clearRetainingCapacity();
                    self.current_sequence_egc.clearRetainingCapacity();
                    break :blk;
                },
                .match_possible => {
                    all_matches_impossible = false;
                },
                .match_impossible => {},
            }
        }
        if (all_matches_impossible) {
            try self.abortCurrentSequence(.match_impossible, egc, event);
        }
    }

    const AbortType = enum { timeout, match_impossible };
    fn abortCurrentSequence(self: *@This(), abort_type: AbortType, egc: u8, key_event: KeyEvent) anyerror!void {
        _ = egc;
        _ = key_event;
        if (abort_type == .match_impossible) {
            switch (self.on_match_failure) {
                .insert => {
                    try self.insertBytes(self.current_sequence_egc.items);
                    self.current_sequence_egc.clearRetainingCapacity();
                    self.current_sequence.clearRetainingCapacity();
                },
                .ignore => {
                    self.current_sequence.clearRetainingCapacity();
                    self.current_sequence_egc.clearRetainingCapacity();
                },
                // .fallback_mode => |fallback_mode_name| {
                // _ = fallback_mode_name;
                // @panic("This feature not supported yet");
                //const fallback_mode = self.activeNamespace().get(fallback_mode_name).?;
                //try self.registerKeyEvent(fallback_mode, egc, key_event);
                // },
            }
        } else if (abort_type == .timeout) {
            try self.insertBytes(self.current_sequence_egc.items);
            self.current_sequence_egc.clearRetainingCapacity();
            self.current_sequence.clearRetainingCapacity();
        }
    }
};

//A collection of various modes under a single namespace, such as "vim" or "emacs"
const Namespace = HashMap(*BindingSet);
const HashMap = std.StringArrayHashMap;

//Data structure for mapping key events to keybindings
const Bindings = struct {
    allocator: std.mem.Allocator,
    active_namespace: usize,
    active_mode: usize,
    namespaces: HashMap(Namespace),

    //lists namespaces
    fn listNamespaces(self: *const @This()) []const []const u8 {
        return self.namespaces.keys();
    }

    fn selectNamespace(self: *Bindings, namespace_name: []const u8) error{NotFound}!void {
        for (self.namespaces.keys(), 0..) |name, i| {
            if (std.mem.eql(u8, name, namespace_name)) {
                self.active_namespace = i;
                return;
            }
        }
        return error.NotFound;
    }

    fn activeNamespace(self: *const Bindings) Namespace {
        return self.namespaces.values()[self.active_namespace];
    }

    fn selectMode(self: *Bindings, mode_name: []const u8) error{NotFound}!void {
        const namespace = self.activeNamespace();
        for (namespace.keys(), 0..) |name, i| {
            if (std.mem.eql(u8, name, mode_name)) {
                self.active_mode = i;
                return;
            }
        }
        return error.NotFound;
    }

    fn activeMode(self: *Bindings) *BindingSet {
        return self.activeNamespace().values()[self.active_mode];
    }

    fn init(allocator: std.mem.Allocator) !*Bindings {
        const self: *@This() = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .active_namespace = 0,
            .active_mode = 0,
            .namespaces = std.StringArrayHashMap(Namespace).init(allocator),
        };
        return self;
    }

    fn addMode(self: *@This(), namespace_name: []const u8, mode_name: []const u8, mode_bindings: *BindingSet) !void {
        const namespace = self.namespaces.getPtr(namespace_name) orelse blk: {
            try self.namespaces.putNoClobber(namespace_name, Namespace.init(self.allocator));
            break :blk self.namespaces.getPtr(namespace_name).?;
        };
        try namespace.putNoClobber(mode_name, mode_bindings);
    }

    fn deinit(self: *Bindings) void {
        for (self.namespaces.values()) |*namespace| {
            for (namespace.values()) |mode_bindings| {
                mode_bindings.deinit();
            }
            namespace.deinit();
        }
        self.namespaces.deinit();
        self.allocator.destroy(self);
    }

    fn addNamespace(self: *Bindings, name: []const u8, modes: []const BindingSet) !void {
        try self.namespaces.put(name, .{ .name = name, .modes = modes });
    }

    fn loadJson(self: *@This(), json_string: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_string, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.notObject;
        for (parsed.value.object.values(), 0..) |namespace, i| {
            if (namespace != .object) return error.namespaceNotObject;
            for (namespace.object.values(), 0..) |mode_bindings, j| {
                const mode_config = try std.json.parseFromValue(BindingSet.JsonConfig, self.allocator, mode_bindings, .{});
                defer mode_config.deinit();
                const parsed_mode = try mode_config.value.toMode(self.allocator);
                try self.addMode(parsed.value.object.keys()[i], namespace.object.keys()[j], parsed_mode);
            }
        }
    }
};

const expectEqual = std.testing.expectEqual;

const parse_test_cases = .{
    //input, expected
    .{ "j", &.{KeyEvent{ .key = 'j' }} },
    .{ "jk", &.{ KeyEvent{ .key = 'j' }, KeyEvent{ .key = 'k' } } },
    .{ "<Space>", &.{KeyEvent{ .key = key.SPACE }} },
    .{ "<C-x><C-c>", &.{ KeyEvent{ .key = 'x', .modifiers = mod.CTRL }, KeyEvent{ .key = 'c', .modifiers = mod.CTRL } } },
    .{ "<A-x><Tab>", &.{ KeyEvent{ .key = 'x', .modifiers = mod.ALT }, KeyEvent{ .key = key.TAB } } },
    .{ "<S-A-x><D-Del>", &.{ KeyEvent{ .key = 'x', .modifiers = mod.ALT | mod.SHIFT }, KeyEvent{ .key = key.DEL, .modifiers = mod.SUPER } } },
};

test "parse" {
    const alloc = std.testing.allocator;
    inline for (parse_test_cases) |case| {
        var parsed = Sequence.init(alloc);
        defer parsed.deinit();
        try parseKeySequence(&parsed, case[0]);
        const expected: []const KeyEvent = case[1];
        const actual: []const KeyEvent = parsed.items;
        try expectEqual(expected.len, actual.len);
        for (expected, 0..) |expected_event, i| {
            try expectEqual(expected_event, actual[i]);
        }
    }
}

const match_test_cases = .{
    //input, binding, expected_result
    .{ "j", "j", .matched },
    .{ "j", "jk", .match_possible },
    .{ "kjk", "jk", .match_impossible },
    .{ "k<C-v>", "<C-x><C-c>", .match_impossible },
    .{ "<C-x>c", "<C-x><C-c>", .match_impossible },
    .{ "<C-x><C-c>", "<C-x><C-c>", .matched },
    .{ "<C-x><A-a>", "<C-x><A-a><Tab>", .match_possible },
    .{ "<C-o>", "<C-o>", .matched },
};

test "match" {
    const alloc = std.testing.allocator;
    inline for (match_test_cases) |case| {
        var input = Sequence.init(alloc);
        defer input.deinit();
        var binding = Sequence.init(alloc);
        defer binding.deinit();

        try parseKeySequence(&input, case[0]);
        try parseKeySequence(&binding, case[1]);
        try expectEqual(case[2], Binding.matchKeySequence(binding.items, input.items));
    }
}

test "json" {
    const alloc = std.testing.allocator;
    var bindings = try Bindings.init(alloc);
    defer bindings.deinit();
    try bindings.loadJson(@embedFile("keybindings.json"));
    const mode_binding_set = bindings.activeMode();
    try mode_binding_set.registerKeyEvent('j', .{ .key = 'j' });
    try mode_binding_set.registerKeyEvent('k', .{ .key = 'k' });
    try mode_binding_set.registerKeyEvent('g', .{ .key = 'g' });
    try mode_binding_set.registerKeyEvent('i', .{ .key = 'i' });
    try mode_binding_set.registerKeyEvent(0, .{ .key = 'i', .modifiers = mod.CTRL });
}