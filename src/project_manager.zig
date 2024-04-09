const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const tracy = @import("tracy");
const FileType = @import("syntax").FileType;

const Project = @import("Project.zig");

pid: tp.pid_ref,

const Self = @This();
const module_name = @typeName(Self);

pub fn get() error{Exit}!Self {
    const pid = tp.env.get().proc(module_name);
    return if (pid.expired()) create() else .{ .pid = pid };
}

fn create() error{Exit}!Self {
    const pid = Process.create() catch |e| return tp.exit_error(e);
    defer pid.deinit();
    tp.env.get().proc_set(module_name, pid.ref());
    return .{ .pid = tp.env.get().proc(module_name) };
}

pub fn shutdown() void {
    const pid = tp.env.get().proc(module_name);
    if (pid.expired()) {
        tp.self_pid().send(.{ "project_manager", "shutdown" }) catch {};
        return;
    }
    pid.send(.{"shutdown"}) catch {};
}

pub fn open_cwd() tp.result {
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch "(none)";
    return open(cwd);
}

pub fn open(project_directory: []const u8) tp.result {
    tp.env.get().str_set("project", project_directory);
    return (try get()).pid.send(.{ "open", project_directory });
}

pub fn request_recent_files(max: usize) tp.result {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "request_recent_files", project, max });
}

pub fn query_recent_files(max: usize, query: []const u8) tp.result {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "query_recent_files", project, max, query });
}

pub fn did_open(file_path: []const u8, file_type: *const FileType, version: usize, text: []const u8) tp.result {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    const text_ptr: usize = if (text.len > 0) @intFromPtr(text.ptr) else 0;
    return (try get()).pid.send(.{ "did_open", project, file_path, file_type.name, file_type.language_server, version, text_ptr, text.len });
}

pub fn goto_definition(file_path: []const u8, row: usize, col: usize) tp.result {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "goto_definition", project, file_path, row, col });
}

pub fn update_mru(file_path: []const u8, row: usize, col: usize) tp.result {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "update_mru", project, file_path, row, col });
}

pub fn get_mru_position(file_path: []const u8) tp.result {
    const project = tp.env.get().str("project");
    if (project.len == 0)
        return tp.exit("No project");
    return (try get()).pid.send(.{ "get_mru_position", project, file_path });
}

const Process = struct {
    a: std.mem.Allocator,
    parent: tp.pid,
    logger: log.Logger,
    receiver: Receiver,
    projects: ProjectsMap,
    walker: ?tp.pid = null,

    const Receiver = tp.Receiver(*Process);
    const ProjectsMap = std.StringHashMap(*Project);

    fn create() !tp.pid {
        const a = std.heap.c_allocator;
        const self = try a.create(Process);
        self.* = .{
            .a = a,
            .parent = tp.self_pid().clone(),
            .logger = log.logger(module_name),
            .receiver = Receiver.init(Process.receive, self),
            .projects = ProjectsMap.init(a),
        };
        return tp.spawn_link(self.a, self, Process.start, module_name) catch |e| tp.exit_error(e);
    }

    fn deinit(self: *Process) void {
        var i = self.projects.iterator();
        while (i.next()) |p| {
            self.a.free(p.key_ptr.*);
            p.value_ptr.*.deinit();
            self.a.destroy(p.value_ptr.*);
        }
        self.projects.deinit();
        self.parent.deinit();
        self.logger.deinit();
        self.a.destroy(self);
    }

    fn start(self: *Process) tp.result {
        _ = tp.set_trap(true);
        tp.receive(&self.receiver);
    }

    fn receive(self: *Process, from: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();
        var project_directory: []const u8 = undefined;
        var path: []const u8 = undefined;
        var query: []const u8 = undefined;
        var file_type: []const u8 = undefined;
        var language_server: []const u8 = undefined;
        var high: i64 = 0;
        var low: i64 = 0;
        var max: usize = 0;
        var row: usize = 0;
        var col: usize = 0;
        var version: usize = 0;
        var text_ptr: usize = 0;
        var text_len: usize = 0;

        if (try m.match(.{ "walk_tree_entry", tp.extract(&project_directory), tp.extract(&path), tp.extract(&high), tp.extract(&low) })) {
            const mtime = (@as(i128, @intCast(high)) << 64) | @as(i128, @intCast(low));
            if (self.projects.get(project_directory)) |project|
                project.add_file(path, mtime) catch |e| self.logger.err("walk_tree_entry", e);
            // self.logger.print("file: {s}", .{path});
        } else if (try m.match(.{ "walk_tree_done", tp.extract(&project_directory) })) {
            if (self.walker) |pid| pid.deinit();
            self.walker = null;
            const project = self.projects.get(project_directory) orelse return;
            project.sort_files_by_mtime();
            self.logger.print("opened: {s} with {d} files in {d} ms", .{
                project_directory,
                project.files.items.len,
                std.time.milliTimestamp() - project.open_time,
            });
        } else if (try m.match(.{ "update_mru", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.update_mru(project_directory, path, row, col) catch |e| return from.forward_error(e);
        } else if (try m.match(.{ "open", tp.extract(&project_directory) })) {
            self.open(project_directory) catch |e| return from.forward_error(e);
        } else if (try m.match(.{ "request_recent_files", tp.extract(&project_directory), tp.extract(&max) })) {
            self.request_recent_files(from, project_directory, max) catch |e| return from.forward_error(e);
        } else if (try m.match(.{ "query_recent_files", tp.extract(&project_directory), tp.extract(&max), tp.extract(&query) })) {
            self.query_recent_files(from, project_directory, max, query) catch |e| return from.forward_error(e);
        } else if (try m.match(.{ "did_open", tp.extract(&project_directory), tp.extract(&path), tp.extract(&file_type), tp.extract_cbor(&language_server), tp.extract(&version), tp.extract(&text_ptr), tp.extract(&text_len) })) {
            const text = if (text_len > 0) @as([*]const u8, @ptrFromInt(text_ptr))[0..text_len] else "";
            self.did_open(from, project_directory, path, file_type, language_server, version, text) catch |e| return from.forward_error(e);
        } else if (try m.match(.{ "goto_definition", tp.extract(&project_directory), tp.extract(&path), tp.extract(&row), tp.extract(&col) })) {
            self.goto_definition(from, project_directory, path, row, col) catch |e| return from.forward_error(e);
        } else if (try m.match(.{ "get_mru_position", tp.extract(&project_directory), tp.extract(&path) })) {
            self.get_mru_position(from, project_directory, path) catch |e| return from.forward_error(e);
        } else if (try m.match(.{"shutdown"})) {
            if (self.walker) |pid| pid.send(.{"stop"}) catch {};
            try from.send(.{ "project_manager", "shutdown" });
            return tp.exit_normal();
        } else if (try m.match(.{ "exit", "normal" })) {
            return;
        } else {
            self.logger.err("receive", tp.unexpected(m));
        }
    }

    fn open(self: *Process, project_directory: []const u8) error{ OutOfMemory, Exit }!void {
        self.logger.print("opening: {s}", .{project_directory});
        if (self.projects.get(project_directory) == null) {
            const project = try self.a.create(Project);
            project.* = try Project.init(self.a, project_directory);
            try self.projects.put(try self.a.dupe(u8, project_directory), project);
            self.walker = try walk_tree_async(self.a, project_directory);
        }
    }

    fn request_recent_files(self: *Process, from: tp.pid_ref, project_directory: []const u8, max: usize) error{ OutOfMemory, Exit }!void {
        const project = if (self.projects.get(project_directory)) |p| p else return tp.exit("No project");
        project.sort_files_by_mtime();
        return project.request_recent_files(from, max);
    }

    fn query_recent_files(self: *Process, from: tp.pid_ref, project_directory: []const u8, max: usize, query: []const u8) error{ OutOfMemory, Exit }!void {
        const project = if (self.projects.get(project_directory)) |p| p else return tp.exit("No project");
        // const start_time = std.time.milliTimestamp();
        // project.sort_files_by_mtime();
        const matched = try project.query_recent_files(from, max, query);
        _ = matched;
        // self.logger.print("queried: {s} for {s} match {d} in {d} ms", .{ project_directory, query, matched, std.time.milliTimestamp() - start_time });
    }

    fn did_open(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, file_type: []const u8, language_server: []const u8, version: usize, text: []const u8) tp.result {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".did_open" });
        defer frame.deinit();
        const project = if (self.projects.get(project_directory)) |p| p else return tp.exit("No project");
        return project.did_open(from, file_path, file_type, language_server, version, text);
    }

    fn goto_definition(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) tp.result {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".goto_definition" });
        defer frame.deinit();
        const project = if (self.projects.get(project_directory)) |p| p else return tp.exit("No project");
        return project.goto_definition(from, file_path, row, col) catch |e| tp.exit_error(e);
    }

    fn get_mru_position(self: *Process, from: tp.pid_ref, project_directory: []const u8, file_path: []const u8) tp.result {
        const frame = tracy.initZone(@src(), .{ .name = module_name ++ ".get_mru_position" });
        defer frame.deinit();
        const project = if (self.projects.get(project_directory)) |p| p else return tp.exit("No project");
        return project.get_mru_position(from, file_path) catch |e| tp.exit_error(e);
    }

    fn update_mru(self: *Process, project_directory: []const u8, file_path: []const u8, row: usize, col: usize) tp.result {
        const project = if (self.projects.get(project_directory)) |p| p else return tp.exit("No project");
        return project.update_mru(file_path, row, col) catch |e| tp.exit_error(e);
    }
};

fn walk_tree_async(a_: std.mem.Allocator, root_path_: []const u8) error{Exit}!tp.pid {
    return struct {
        a: std.mem.Allocator,
        root_path: []const u8,
        parent: tp.pid,
        receiver: Receiver,
        dir: std.fs.Dir,
        walker: FilteredWalker,

        const tree_walker = @This();
        const Receiver = tp.Receiver(*tree_walker);

        fn spawn_link(a: std.mem.Allocator, root_path: []const u8) error{Exit}!tp.pid {
            const self = a.create(tree_walker) catch |e| return tp.exit_error(e);
            self.* = .{
                .a = a,
                .root_path = a.dupe(u8, root_path) catch |e| return tp.exit_error(e),
                .parent = tp.self_pid().clone(),
                .receiver = Receiver.init(tree_walker.receive, self),
                .dir = std.fs.cwd().openDir(self.root_path, .{ .iterate = true }) catch |e| return tp.exit_error(e),
                .walker = walk_filtered(self.dir, self.a) catch |e| return tp.exit_error(e),
            };
            return tp.spawn_link(a, self, tree_walker.start, module_name ++ ".tree_walker") catch |e| return tp.exit_error(e);
        }

        fn start(self: *tree_walker) tp.result {
            errdefer self.deinit();
            const frame = tracy.initZone(@src(), .{ .name = "project scan" });
            defer frame.deinit();
            tp.receive(&self.receiver);
            self.next() catch |e| return tp.exit_error(e);
        }

        fn deinit(self: *tree_walker) void {
            self.walker.deinit();
            self.dir.close();
            self.a.free(self.root_path);
            self.parent.deinit();
        }

        fn receive(self: *tree_walker, _: tp.pid_ref, m: tp.message) tp.result {
            errdefer self.deinit();
            const frame = tracy.initZone(@src(), .{ .name = "project scan" });
            defer frame.deinit();

            if (try m.match(.{"next"})) {
                self.next() catch |e| return tp.exit_error(e);
            } else if (try m.match(.{"stop"})) {
                return tp.exit_normal();
            } else {
                return tp.unexpected(m);
            }
        }

        fn next(self: *tree_walker) !void {
            if (try self.walker.next()) |path| {
                const stat = self.dir.statFile(path) catch return tp.self_pid().send(.{"next"});
                const mtime = stat.mtime;
                const high: i64 = @intCast(mtime >> 64);
                const low: i64 = @truncate(mtime);
                std.debug.assert(mtime == (@as(i128, @intCast(high)) << 64) | @as(i128, @intCast(low)));
                try self.parent.send(.{ "walk_tree_entry", self.root_path, path, high, low });
                return tp.self_pid().send(.{"next"});
            } else {
                self.parent.send(.{ "walk_tree_done", self.root_path }) catch {};
                return tp.exit_normal();
            }
        }
    }.spawn_link(a_, root_path_);
}

const filtered_dirs = [_][]const u8{
    ".git",
    ".cache",
    ".var",
    "zig-out",
    "zig-cache",
    ".rustup",
    ".npm",
    ".cargo",
    "node_modules",
};

fn is_filtered_dir(dirname: []const u8) bool {
    for (filtered_dirs) |filter|
        if (std.mem.eql(u8, filter, dirname))
            return true;
    return false;
}

const FilteredWalker = struct {
    stack: std.ArrayList(StackItem),
    name_buffer: std.ArrayList(u8),

    const Path = []const u8;

    const StackItem = struct {
        iter: std.fs.Dir.Iterator,
        dirname_len: usize,
    };

    pub fn next(self: *FilteredWalker) error{OutOfMemory}!?Path {
        while (self.stack.items.len != 0) {
            var top = &self.stack.items[self.stack.items.len - 1];
            var containing = top;
            var dirname_len = top.dirname_len;
            if (top.iter.next() catch {
                var item = self.stack.pop();
                if (self.stack.items.len != 0) {
                    item.iter.dir.close();
                }
                continue;
            }) |base| {
                self.name_buffer.shrinkRetainingCapacity(dirname_len);
                if (self.name_buffer.items.len != 0) {
                    try self.name_buffer.append(std.fs.path.sep);
                    dirname_len += 1;
                }
                try self.name_buffer.appendSlice(base.name);
                switch (base.kind) {
                    .directory => {
                        if (is_filtered_dir(base.name))
                            continue;
                        var new_dir = top.iter.dir.openDir(base.name, .{ .iterate = true }) catch |err| switch (err) {
                            error.NameTooLong => @panic("unexpected error.NameTooLong"), // no path sep in base.name
                            else => continue,
                        };
                        {
                            errdefer new_dir.close();
                            try self.stack.append(StackItem{
                                .iter = new_dir.iterateAssumeFirstIteration(),
                                .dirname_len = self.name_buffer.items.len,
                            });
                            top = &self.stack.items[self.stack.items.len - 1];
                            containing = &self.stack.items[self.stack.items.len - 2];
                        }
                    },
                    .file => return self.name_buffer.items,
                    else => continue,
                }
            } else {
                var item = self.stack.pop();
                if (self.stack.items.len != 0) {
                    item.iter.dir.close();
                }
            }
        }
        return null;
    }

    pub fn deinit(self: *FilteredWalker) void {
        // Close any remaining directories except the initial one (which is always at index 0)
        if (self.stack.items.len > 1) {
            for (self.stack.items[1..]) |*item| {
                item.iter.dir.close();
            }
        }
        self.stack.deinit();
        self.name_buffer.deinit();
    }
};

fn walk_filtered(dir: std.fs.Dir, allocator: std.mem.Allocator) !FilteredWalker {
    var name_buffer = std.ArrayList(u8).init(allocator);
    errdefer name_buffer.deinit();

    var stack = std.ArrayList(FilteredWalker.StackItem).init(allocator);
    errdefer stack.deinit();

    try stack.append(FilteredWalker.StackItem{
        .iter = dir.iterate(),
        .dirname_len = 0,
    });

    return FilteredWalker{
        .stack = stack,
        .name_buffer = name_buffer,
    };
}
