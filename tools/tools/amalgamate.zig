//! Amalgamates a multi-file Zig library into one generated file in which `pub`
//! means exactly "part of the consumer surface", with no tests in it.
//!
//! Zig has one visibility level, so in a multi-file library every declaration
//! another file calls is `pub`, whether or not a consumer should see it. Inside one
//! file, though, sibling containers reach each other's non-`pub` members freely —
//! `pub` only gates access from *other files*. So the library's files, inlined as
//! namespaces into one file, need `pub` only on what the root reaches through its
//! own `pub` aliases. Everything else becomes a plain declaration: a consumer
//! cannot name it, and the docs do not index it.
//!
//! Layout of the output: the root file's body at the top level (its `pub` is the
//! consumer surface, untouched), then every other file as
//! `const <stem>_module = struct { … }`. `@import("x.zig")` becomes `x_module`, and
//! an alias `const x_module = @import("x.zig")` is dropped as redundant.
//!
//! Two Zig rules shape the rest. A name declared in two enclosing container scopes
//! is an "ambiguous reference" wherever it is used, so a namespace whose top level
//! declares something the root also declares — `Request` in the router, `std` in
//! every file when the root has one — has every bare use of that name qualified as
//! `x_module.Request`, or, when the two declarations are identical imports, the
//! nested one is simply dropped. A parameter or local may not shadow an enclosing
//! declaration at all. The two cases this tool cannot rewrite safely — a nested
//! container declaring a root name and using it bare, and a parameter or local
//! named like one — it reports with a location, and the fix is in the source.
//!
//! Tests are not shipped: every `test` block goes, and then every declaration that
//! nothing live references goes too (the test harness, a fuzz helper, `std` in a
//! file that only tested with it), iterated to a fixpoint from the public surface.
//!
//! Usage: amalgamate <root.zig> <module-name> <out-dir> [depfile]

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4 and args.len != 5) {
        std.log.err("usage: {s} <root.zig> <module-name> <out-dir> [depfile]", .{args[0]});
        return error.InvalidUsage;
    }
    const root_path = args[1];
    const module_name = args[2];
    const out_dir_path = args[3];

    var lib: Library = .{ .arena = arena, .io = io, .module_name = module_name };
    try lib.discover(root_path);
    try lib.markReachable();
    try lib.markLive();
    try lib.checkCollisions();

    const source = try lib.emit();

    const out_name = try std.mem.concat(arena, u8, &.{ module_name, ".zig" });
    try writeFile(io, out_dir_path, out_name, source);

    // Every file read is an input the build must watch; the depfile says so.
    if (args.len == 5) {
        var deps: std.Io.Writer.Allocating = .init(arena);
        try deps.writer.print("{s}/{s}:", .{ out_dir_path, out_name });
        for (lib.files.items) |file| {
            const abs = try std.fs.path.join(arena, &.{ lib.root_dir, file.rel });
            try deps.writer.writeByte(' ');
            for (abs) |byte| {
                if (byte == ' ') try deps.writer.writeByte('\\');
                try deps.writer.writeByte(byte);
            }
        }
        try deps.writer.writeByte('\n');
        const file = try std.Io.Dir.cwd().createFile(io, args[4], .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(deps.written());
        try writer.interface.flush();
    }
}

fn writeFile(io: std.Io, dir: []const u8, name: []const u8, bytes: []const u8) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ dir, name });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

/// One source file of the library.
const File = struct {
    /// Path relative to the root's directory, '/'-separated: "http/router.zig".
    rel: []const u8,
    /// The namespace name, `<basename>_module`; unused for the root.
    stem: []const u8,
    source: [:0]const u8,
    ast: Ast,
    is_root: bool,
    /// Top-level var and fn declarations by name.
    decls: std.StringArrayHashMapUnmanaged(Node.Index) = .empty,
    /// Top-level `const x = @import("y.zig")` aliases: name -> file index.
    import_aliases: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// The `@import(...)` nodes that are those aliases' initializers: a handle,
    /// not a use of the whole namespace.
    alias_inits: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Byte ranges of every `test` block.
    tests: []const Range = &.{},
    /// Top-level declarations something live references (or the surface).
    live: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Whether any live code in this file references the root file.
    imports_root: bool = false,
};

/// A declaration, or (with `node` null) a whole file used as a namespace.
const Target = struct { file: u32, node: ?Node.Index };

const Mark = struct { file: u32, node: u32 };
const Range = struct { start: u32, end: u32 };
const Edit = struct { start: u32, end: u32, text: []const u8 };

const Library = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    module_name: []const u8,
    root_dir: []const u8 = "",
    files: std.ArrayList(File) = .empty,
    /// Declarations that keep `pub` in the output.
    marked: std.AutoHashMapUnmanaged(Mark, void) = .empty,

    // ----------------------------------------------------------------------
    // Discovery
    // ----------------------------------------------------------------------

    fn discover(lib: *Library, root_path: []const u8) !void {
        lib.root_dir = std.fs.path.dirname(root_path) orelse ".";
        _ = try lib.addFile(std.fs.path.basename(root_path), true);

        // Breadth-first over `@import("…zig")` anywhere in each file, tests
        // included — a test-only file is discovered here and pruned later.
        var next: usize = 0;
        while (next < lib.files.items.len) : (next += 1) {
            // By value: `addFile` below appends to the list and may move it.
            const file = lib.files.items[next];
            for (0..file.ast.nodes.len) |i| {
                const node: Node.Index = @enumFromInt(i);
                const rel = lib.importPath(&file, node) orelse continue;
                _ = try lib.addFile(rel, false);
            }
        }

        for (lib.files.items) |*file| try lib.indexFile(file);
    }

    fn addFile(lib: *Library, rel: []const u8, is_root: bool) !u32 {
        for (lib.files.items, 0..) |file, index| {
            if (std.mem.eql(u8, file.rel, rel)) return @intCast(index);
        }

        // Namespaces are `<file>_module`, never the bare stem: Zig forbids a
        // parameter or local shadowing an enclosing declaration, and names like
        // `server` and `engine` are parameters all over an engine. The suffix
        // also matches the `const engine_module = @import(...)` convention, so
        // those aliases become self-references and are simply dropped.
        const stem = try std.mem.concat(lib.arena, u8, &.{ std.fs.path.stem(rel), "_module" });
        for (lib.files.items) |file| {
            if (std.mem.eql(u8, file.stem, stem)) {
                std.log.err("two files share the namespace name '{s}': {s} and {s}", .{ stem, file.rel, rel });
                return error.StemCollision;
            }
        }

        const abs = try std.fs.path.join(lib.arena, &.{ lib.root_dir, rel });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(lib.io, abs, lib.arena, .limited(1 << 26));
        const source = try lib.arena.dupeZ(u8, bytes);
        const ast = try Ast.parse(lib.arena, source, .zig);
        if (ast.errors.len != 0) {
            std.log.err("{s} does not parse", .{rel});
            return error.ParseFailed;
        }

        try lib.files.append(lib.arena, .{
            .rel = try lib.arena.dupe(u8, rel),
            .stem = stem,
            .source = source,
            .ast = ast,
            .is_root = is_root,
        });
        return @intCast(lib.files.items.len - 1);
    }

    fn indexFile(lib: *Library, file: *File) !void {
        const ast = &file.ast;
        var tests: std.ArrayList(Range) = .empty;
        for (0..ast.nodes.len) |i| {
            const node: Node.Index = @enumFromInt(i);
            if (ast.nodeTag(node) != .test_decl) continue;
            const start, const end = nodeRange(ast, node);
            try tests.append(lib.arena, .{ .start = start, .end = end });
        }
        file.tests = tests.items;

        for (ast.rootDecls()) |node| {
            if (declName(ast, node)) |name| try file.decls.put(lib.arena, name, node);
            const var_decl = ast.fullVarDecl(node) orelse continue;
            const init_node = var_decl.ast.init_node.unwrap() orelse continue;
            if (lib.importPath(file, init_node)) |rel| {
                const target = lib.fileIndex(rel).?;
                try file.import_aliases.put(lib.arena, ast.tokenSlice(var_decl.ast.mut_token + 1), target);
                try file.alias_inits.put(lib.arena, @intFromEnum(init_node), {});
            }
        }
    }

    fn fileIndex(lib: *Library, rel: []const u8) ?u32 {
        for (lib.files.items, 0..) |file, index| {
            if (std.mem.eql(u8, file.rel, rel)) return @intCast(index);
        }
        return null;
    }

    /// If `node` is `@import("…zig")`, the imported file's path relative to the
    /// root directory; null for anything else, module imports included.
    fn importPath(lib: *Library, file: *const File, node: Node.Index) ?[]const u8 {
        const ast = &file.ast;
        switch (ast.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
            else => return null,
        }
        if (!std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), "@import")) return null;

        var buffer: [2]Node.Index = undefined;
        const params = ast.builtinCallParams(&buffer, node) orelse return null;
        if (params.len != 1 or ast.nodeTag(params[0]) != .string_literal) return null;

        const quoted = ast.tokenSlice(ast.nodeMainToken(params[0]));
        const relative = std.zig.string_literal.parseAlloc(lib.arena, quoted) catch return null;
        if (!std.mem.endsWith(u8, relative, ".zig")) return null;

        const dir = std.fs.path.dirname(file.rel) orelse "";
        return std.fs.path.resolvePosix(lib.arena, &.{ dir, relative }) catch null;
    }

    // ----------------------------------------------------------------------
    // Reachability: what keeps `pub`
    // ----------------------------------------------------------------------

    fn markReachable(lib: *Library) !void {
        const root = &lib.files.items[0];
        for (root.ast.rootDecls()) |node| {
            if (!isPub(&root.ast, node)) continue;
            if (try lib.resolveDecl(0, node)) |target| try lib.mark(target);
        }
    }

    fn markDecl(lib: *Library, file: u32, node: Node.Index) !void {
        try lib.marked.put(lib.arena, .{ .file = file, .node = @intFromEnum(node) }, {});
    }

    fn isMarked(lib: *Library, file: u32, node: Node.Index) bool {
        return lib.marked.contains(.{ .file = file, .node = @intFromEnum(node) });
    }

    /// Marks a target and, for anything with members, its `pub` members.
    fn mark(lib: *Library, target: Target) std.mem.Allocator.Error!void {
        const file = &lib.files.items[target.file];
        const ast = &file.ast;

        const key = target.node orelse Node.Index.root;
        if (lib.isMarked(target.file, key)) return;
        try lib.markDecl(target.file, key);

        var buffer: [2]Node.Index = undefined;
        const member_nodes = lib.members(file, target.node, &buffer) orelse return;
        for (member_nodes) |member| {
            if (!isPub(ast, member)) continue;
            // Resolve first: a container resolves to itself, and marking it
            // before the recursive call would make that call return early
            // without visiting its members.
            if (try lib.resolveDecl(target.file, member)) |resolved| try lib.mark(resolved);
            // The member itself keeps `pub` too — an alias like `App.Handler`
            // is what the consumer names, whatever it resolves to.
            try lib.markDecl(target.file, member);
        }
    }

    /// The member declarations of a target: a file's top level, a container's
    /// members, or the members of the struct a type function returns.
    fn members(lib: *Library, file: *File, node: ?Node.Index, buffer: *[2]Node.Index) ?[]const Node.Index {
        _ = lib;
        const ast = &file.ast;
        const decl = node orelse return ast.rootDecls();

        switch (ast.nodeTag(decl)) {
            .fn_decl => {
                const fn_body = ast.nodeData(decl).node_and_node[1];
                var block_buffer: [2]Node.Index = undefined;
                const statements = ast.blockStatements(&block_buffer, fn_body) orelse return null;
                for (statements) |statement| {
                    if (ast.nodeTag(statement) != .@"return") continue;
                    const returned = ast.nodeData(statement).opt_node.unwrap() orelse return null;
                    const container = ast.fullContainerDecl(buffer, returned) orelse return null;
                    return container.ast.members;
                }
                return null;
            },
            else => {
                const var_decl = ast.fullVarDecl(decl) orelse return null;
                const init_node = var_decl.ast.init_node.unwrap() orelse return null;
                const container = ast.fullContainerDecl(buffer, init_node) orelse return null;
                return container.ast.members;
            },
        }
    }

    /// Follows a declaration's alias chain to what it ultimately names. Null when
    /// the chain leaves the library (a module import, a call, a value).
    fn resolveDecl(lib: *Library, file_index: u32, node: Node.Index) std.mem.Allocator.Error!?Target {
        const file = &lib.files.items[file_index];
        const ast = &file.ast;

        const var_decl = ast.fullVarDecl(node) orelse return .{ .file = file_index, .node = node };
        const init_node = var_decl.ast.init_node.unwrap() orelse return .{ .file = file_index, .node = node };

        // Peel `.a.b.c` off the initializer, innermost first. An alias to a
        // type-function call — `const Schema = OrderedMap(PropSchema)` — names
        // the struct that function returns, so resolve through its callee.
        var path: std.ArrayList([]const u8) = .empty;
        var base = init_node;
        var call_buffer: [1]Node.Index = undefined;
        if (ast.fullCall(&call_buffer, base)) |call| base = call.ast.fn_expr;
        while (ast.nodeTag(base) == .field_access) {
            const object, const field = ast.nodeData(base).node_and_token;
            try path.insert(lib.arena, 0, ast.tokenSlice(field));
            base = object;
        }

        if (lib.importPath(file, base)) |rel| {
            const target = lib.fileIndex(rel).?;
            return lib.resolveMember(.{ .file = target, .node = null }, path.items);
        }

        if (ast.nodeTag(base) == .identifier) {
            const name = ast.tokenSlice(ast.nodeMainToken(base));
            if (file.import_aliases.get(name)) |target| {
                return lib.resolveMember(.{ .file = target, .node = null }, path.items);
            }
            if (file.decls.get(name)) |decl| {
                if (decl == node) return .{ .file = file_index, .node = node };
                const resolved = (try lib.resolveDecl(file_index, decl)) orelse return null;
                return lib.resolveMember(resolved, path.items);
            }
            return null;
        }

        return .{ .file = file_index, .node = node };
    }

    fn resolveMember(lib: *Library, target: Target, path: []const []const u8) std.mem.Allocator.Error!?Target {
        if (path.len == 0) return target;
        const file = &lib.files.items[target.file];
        var buffer: [2]Node.Index = undefined;
        const candidates = lib.members(file, target.node, &buffer) orelse return null;
        for (candidates) |member| {
            const name = declName(&file.ast, member) orelse continue;
            if (!std.mem.eql(u8, name, path[0])) continue;
            const resolved = (try lib.resolveDecl(target.file, member)) orelse return null;
            return lib.resolveMember(resolved, path[1..]);
        }
        return null;
    }

    // ----------------------------------------------------------------------
    // Liveness: what survives test stripping
    // ----------------------------------------------------------------------

    /// Starts from the root's top-level declarations and every marked
    /// declaration, follows references (bare identifiers within a file,
    /// `alias.name` and `@import("x.zig").name` across files), and keeps going
    /// until nothing new is live. Tests are never a source of references.
    fn markLive(lib: *Library) !void {
        var work: std.ArrayList(Mark) = .empty;

        const root = &lib.files.items[0];
        for (root.ast.rootDecls()) |node| {
            if (root.ast.nodeTag(node) == .test_decl) continue;
            if (declName(&root.ast, node) == null and !isComptimeBlock(&root.ast, node)) continue;
            try lib.setLive(&work, 0, node);
        }
        var it = lib.marked.keyIterator();
        while (it.next()) |mark_key| {
            if (mark_key.node == @intFromEnum(Node.Index.root)) continue;
            const node: Node.Index = @enumFromInt(mark_key.node);
            const top = lib.topLevelOwner(mark_key.file, node) orelse continue;
            try lib.setLive(&work, mark_key.file, top);
        }

        while (work.pop()) |item| {
            try lib.referencesOf(&work, item.file, @enumFromInt(item.node));
        }
    }

    fn setLive(lib: *Library, work: *std.ArrayList(Mark), file: u32, node: Node.Index) !void {
        const entry = try lib.files.items[file].live.getOrPut(lib.arena, @intFromEnum(node));
        if (entry.found_existing) return;
        try work.append(lib.arena, .{ .file = file, .node = @intFromEnum(node) });
    }

    /// The top-level declaration of `file` that contains `node`.
    fn topLevelOwner(lib: *Library, file_index: u32, node: Node.Index) ?Node.Index {
        const ast = &lib.files.items[file_index].ast;
        const start = ast.tokenStart(ast.firstToken(node));
        for (ast.rootDecls()) |decl| {
            const range_start, const range_end = nodeRange(ast, decl);
            if (start >= range_start and start < range_end) return decl;
        }
        return null;
    }

    /// Everything the top-level declaration `decl` references, marked live.
    fn referencesOf(lib: *Library, work: *std.ArrayList(Mark), file_index: u32, decl: Node.Index) !void {
        const file = &lib.files.items[file_index];
        const ast = &file.ast;
        const first = ast.firstToken(decl);
        const last = ast.lastToken(decl);

        // An `@import("x.zig")` that is the object of a field access names one
        // member; one used as a value — `switch (os) { .windows => @import(…) }`
        // — uses the whole namespace, and every top-level declaration of that
        // file has to survive.
        var accessed: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (0..ast.nodes.len) |i| {
            const node: Node.Index = @enumFromInt(i);
            if (ast.nodeTag(node) != .field_access) continue;
            try accessed.put(lib.arena, @intFromEnum(ast.nodeData(node).node_and_token[0]), {});
        }

        for (0..ast.nodes.len) |i| {
            const node: Node.Index = @enumFromInt(i);
            const token = ast.firstToken(node);
            if (token < first or token > last) continue;

            switch (ast.nodeTag(node)) {
                .identifier => {
                    const name = ast.tokenSlice(ast.nodeMainToken(node));
                    if (file.decls.get(name)) |target| try lib.setLive(work, file_index, target);
                    // An import alias used as a value rather than through
                    // `.member` needs the whole namespace it names.
                    if (file.import_aliases.get(name)) |target_file| {
                        if (accessed.contains(@intFromEnum(node))) continue;
                        try lib.setWholeFileLive(work, target_file);
                    }
                },
                .field_access => {
                    const object, const field = ast.nodeData(node).node_and_token;
                    const target_file = lib.fileOfExpr(file, object) orelse continue;
                    const target = &lib.files.items[target_file];
                    if (target.is_root) file.imports_root = true;
                    if (target.decls.get(ast.tokenSlice(field))) |member| {
                        try lib.setLive(work, target_file, member);
                    }
                },
                else => {
                    const rel = lib.importPath(file, node) orelse continue;
                    const target_file = lib.fileIndex(rel).?;
                    if (lib.files.items[target_file].is_root) file.imports_root = true;
                    if (accessed.contains(@intFromEnum(node))) continue;
                    if (file.alias_inits.contains(@intFromEnum(node))) continue;
                    try lib.setWholeFileLive(work, target_file);
                },
            }
        }
    }

    fn setWholeFileLive(lib: *Library, work: *std.ArrayList(Mark), file_index: u32) !void {
        const target = &lib.files.items[file_index];
        for (target.ast.rootDecls()) |member| {
            if (declName(&target.ast, member) != null) try lib.setLive(work, file_index, member);
        }
    }

    /// The file an expression names, when it is `@import("x.zig")` or a
    /// top-level alias of one.
    fn fileOfExpr(lib: *Library, file: *const File, node: Node.Index) ?u32 {
        if (lib.importPath(file, node)) |rel| return lib.fileIndex(rel);
        if (file.ast.nodeTag(node) != .identifier) return null;
        return file.import_aliases.get(file.ast.tokenSlice(file.ast.nodeMainToken(node)));
    }

    fn isLive(lib: *Library, file_index: u32, node: Node.Index) bool {
        return lib.files.items[file_index].live.contains(@intFromEnum(node));
    }

    // ----------------------------------------------------------------------
    // Collisions with the root's names
    // ----------------------------------------------------------------------

    /// Names declared at the root's top level, which enclose every namespace.
    fn rootNames(lib: *Library) !std.StringArrayHashMapUnmanaged(void) {
        var names: std.StringArrayHashMapUnmanaged(void) = .empty;
        const root = &lib.files.items[0];
        for (root.ast.rootDecls()) |node| {
            if (!lib.isLive(0, node)) continue;
            if (declName(&root.ast, node)) |name| try names.put(lib.arena, name, {});
        }
        for (lib.files.items) |file| {
            if (!file.is_root) try names.put(lib.arena, file.stem, {});
        }
        if (lib.rootIsImported()) try names.put(lib.arena, lib.module_name, {});
        return names;
    }

    fn rootIsImported(lib: *Library) bool {
        for (lib.files.items) |file| {
            if (!file.is_root and file.imports_root) return true;
        }
        return false;
    }

    /// Reports what cannot be rewritten: a nested container declaring a root
    /// name and using it bare, or a parameter or local named like one.
    fn checkCollisions(lib: *Library) !void {
        const names = try lib.rootNames();
        var failed = false;

        for (lib.files.items, 0..) |*file, file_index| {
            if (file.is_root) continue;
            const ast = &file.ast;

            // Top-level declarations: their bare uses are qualified at emit time.
            // Member declarations of nested containers are the hard case.
            var member_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
            for (ast.rootDecls()) |node| try member_nodes.put(lib.arena, @intFromEnum(node), {});

            for (0..ast.nodes.len) |i| {
                const node: Node.Index = @enumFromInt(i);
                if (inRanges(ast.tokenStart(ast.firstToken(node)), file.tests)) continue;

                var buffer: [2]Node.Index = undefined;
                const container = ast.fullContainerDecl(&buffer, node) orelse continue;
                const top = lib.topLevelOwner(@intCast(file_index), node) orelse continue;
                if (!lib.isLive(@intCast(file_index), top)) continue;

                for (container.ast.members) |member| {
                    try member_nodes.put(lib.arena, @intFromEnum(member), {});
                    const name = declName(ast, member) orelse continue;
                    if (!names.contains(name)) continue;
                    if (!lib.usedBareWithin(file, node, name)) continue;
                    const loc = ast.tokenLocation(0, ast.nodeMainToken(member));
                    std.log.err(
                        "{s}:{d}: `{s}` is declared inside a nested container and the root also declares `{s}`; " ++
                            "refer to it through the container's Self alias (`App.{s}`) so the reference is not ambiguous",
                        .{ file.rel, loc.line + 1, name, name, name },
                    );
                    failed = true;
                }
            }

            // Parameters and locals: no rewrite makes these legal.
            for (0..ast.nodes.len) |i| {
                const node: Node.Index = @enumFromInt(i);
                if (inRanges(ast.tokenStart(ast.firstToken(node)), file.tests)) continue;
                const top = lib.topLevelOwner(@intCast(file_index), node) orelse continue;
                if (!lib.isLive(@intCast(file_index), top)) continue;

                var proto_buffer: [1]Node.Index = undefined;
                if (ast.fullFnProto(&proto_buffer, node)) |proto| {
                    var it = proto.iterate(ast);
                    while (it.next()) |param| {
                        const token = param.name_token orelse continue;
                        const name = ast.tokenSlice(token);
                        if (!names.contains(name)) continue;
                        const loc = ast.tokenLocation(0, token);
                        std.log.err(
                            "{s}:{d}: parameter `{s}` would shadow the root's `{s}` once inlined; rename it",
                            .{ file.rel, loc.line + 1, name, name },
                        );
                        failed = true;
                    }
                }
                if (member_nodes.contains(@intFromEnum(node))) continue;
                if (ast.fullVarDecl(node)) |var_decl| {
                    const name = ast.tokenSlice(var_decl.ast.mut_token + 1);
                    if (!names.contains(name)) continue;
                    const loc = ast.tokenLocation(0, var_decl.ast.mut_token);
                    std.log.err(
                        "{s}:{d}: local `{s}` would shadow the root's `{s}` once inlined; rename it",
                        .{ file.rel, loc.line + 1, name, name },
                    );
                    failed = true;
                }
            }
        }

        if (failed) return error.NameCollision;
    }

    fn usedBareWithin(lib: *Library, file: *const File, container: Node.Index, name: []const u8) bool {
        _ = lib;
        const ast = &file.ast;
        const first = ast.firstToken(container);
        const last = ast.lastToken(container);
        for (0..ast.nodes.len) |i| {
            const node: Node.Index = @enumFromInt(i);
            if (ast.nodeTag(node) != .identifier) continue;
            const token = ast.nodeMainToken(node);
            if (token < first or token > last) continue;
            if (std.mem.eql(u8, ast.tokenSlice(token), name)) return true;
        }
        return false;
    }

    // ----------------------------------------------------------------------
    // Emission
    // ----------------------------------------------------------------------

    fn emit(lib: *Library) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(lib.arena);
        const w = &out.writer;
        const root = &lib.files.items[0];
        const root_names = try lib.rootNames();

        try w.print("// Generated by publr_tools from the sources of `{s}`. Do not edit.\n", .{lib.module_name});
        if (docCommentText(&root.ast, root.source)) |doc| try w.writeAll(doc);
        try w.writeAll("\n");

        if (lib.rootIsImported()) {
            try w.print("/// This file, for the namespaces that imported the root.\nconst {s} = @This();\n\n", .{lib.module_name});
        }

        try w.writeAll(try lib.body(0, &root_names));
        try w.writeAll("\n\n");

        for (lib.files.items, 0..) |*file, index| {
            if (file.is_root or file.live.count() == 0) continue;

            if (docCommentText(&file.ast, file.source)) |doc| {
                var lines = std.mem.splitScalar(u8, doc, '\n');
                while (lines.next()) |line| {
                    if (line.len == 0) continue;
                    try w.print("///{s}\n", .{line[3..]});
                }
            }
            try w.print("const {s} = struct {{\n{s}\n}};\n\n", .{
                file.stem,
                try lib.body(@intCast(index), &root_names),
            });
        }

        return lib.format(out.written());
    }

    /// A file's source, rewritten for the single file: tests and dead
    /// declarations gone, imports pointing at namespaces, redundant and
    /// identical aliases dropped, `pub` stripped from the unreachable, and bare
    /// uses of a name the root also declares qualified with the namespace.
    fn body(lib: *Library, file_index: u32, root_names: *const std.StringArrayHashMapUnmanaged(void)) ![]const u8 {
        const file = &lib.files.items[file_index];
        const ast = &file.ast;
        const root = &lib.files.items[0];
        var edits: std.ArrayList(Edit) = .empty;
        var deleted: std.ArrayList(Range) = .empty;

        if (docCommentText(ast, file.source)) |doc| {
            const start: u32 = @intCast(@intFromPtr(doc.ptr) - @intFromPtr(file.source.ptr));
            try deleted.append(lib.arena, .{ .start = start, .end = start + @as(u32, @intCast(doc.len)) });
        }
        for (file.tests) |range| try deleted.append(lib.arena, range);

        // Names this namespace declares at its top level that the root also
        // declares: bare uses become `x_module.name`, unless the declaration is
        // an identical import alias, which is dropped instead.
        var qualified: std.StringArrayHashMapUnmanaged(void) = .empty;

        for (ast.rootDecls()) |node| {
            if (ast.nodeTag(node) == .test_decl) continue;
            const start, var end = nodeRange(ast, node);
            // The terminating `;` is not part of the node. It may sit past a
            // newline when the initializer ends in a multiline string literal.
            var after = end;
            while (after < file.source.len and std.ascii.isWhitespace(file.source[after])) after += 1;
            if (after < file.source.len and file.source[after] == ';') end = after + 1;

            // Dead after test stripping.
            if (!lib.isLive(file_index, node) and !isComptimeBlock(ast, node)) {
                try deleted.append(lib.arena, .{ .start = start, .end = end });
                continue;
            }

            const name = declName(ast, node) orelse continue;
            const var_decl = ast.fullVarDecl(node);

            // `const x_module = @import("x.zig")`: redundant, and an ambiguous
            // redeclaration of the namespace. Drop it.
            if (var_decl) |vd| if (vd.ast.init_node.unwrap()) |init_node| {
                if (lib.importPath(file, init_node)) |rel| {
                    const target = &lib.files.items[lib.fileIndex(rel).?];
                    if (!target.is_root and std.mem.eql(u8, name, target.stem)) {
                        try deleted.append(lib.arena, .{ .start = start, .end = end });
                        continue;
                    }
                }
            };

            if (file.is_root or !root_names.contains(name)) continue;

            // The same alias at the root (`const std = @import("std")`): drop
            // this one and let the root's serve.
            if (var_decl) |vd| if (root.decls.get(name)) |root_decl| {
                if (root.ast.fullVarDecl(root_decl)) |root_vd| {
                    const mine = vd.ast.init_node.unwrap();
                    const theirs = root_vd.ast.init_node.unwrap();
                    if (mine != null and theirs != null and
                        std.mem.eql(u8, ast.getNodeSource(mine.?), root.ast.getNodeSource(theirs.?)))
                    {
                        try deleted.append(lib.arena, .{ .start = start, .end = end });
                        continue;
                    }
                }
            };

            try qualified.put(lib.arena, name, {});
        }

        for (deleted.items) |range| try edits.append(lib.arena, .{ .start = range.start, .end = range.end, .text = "" });

        for (0..ast.nodes.len) |i| {
            const node: Node.Index = @enumFromInt(i);
            const at = ast.tokenStart(ast.firstToken(node));
            if (inRanges(at, deleted.items)) continue;

            // `@import("x.zig")` → `x_module`; an import of the root → the
            // root's Self alias.
            if (lib.importPath(file, node)) |rel| {
                const target = &lib.files.items[lib.fileIndex(rel).?];
                const start, const end = nodeRange(ast, node);
                const text = if (target.is_root) lib.module_name else target.stem;
                try edits.append(lib.arena, .{ .start = start, .end = end, .text = text });
                continue;
            }

            // Bare use of a qualified name → `x_module.name`.
            if (!file.is_root and ast.nodeTag(node) == .identifier) {
                const name = ast.tokenSlice(ast.nodeMainToken(node));
                if (qualified.contains(name)) {
                    const start, const end = nodeRange(ast, node);
                    try edits.append(lib.arena, .{
                        .start = start,
                        .end = end,
                        .text = try std.fmt.allocPrint(lib.arena, "{s}.{s}", .{ file.stem, name }),
                    });
                }
            }
        }

        // `pub` survives only on reachable declarations; the root keeps its own.
        if (!file.is_root) {
            var visib_tokens: std.AutoHashMapUnmanaged(Ast.TokenIndex, void) = .empty;
            for (0..ast.nodes.len) |i| {
                const node: Node.Index = @enumFromInt(i);
                const token = visibToken(ast, node) orelse continue;
                if (lib.isMarked(file_index, node)) continue;
                if (ast.nodeTag(node) != .fn_decl and lib.fnProtoOfMarkedDecl(file_index, ast, node)) continue;
                try visib_tokens.put(lib.arena, token, {});
            }
            var it = visib_tokens.keyIterator();
            while (it.next()) |token| {
                const start = ast.tokenStart(token.*);
                if (inRanges(start, deleted.items)) continue;
                var end = start + 3;
                if (end < file.source.len and file.source[end] == ' ') end += 1;
                try edits.append(lib.arena, .{ .start = start, .end = end, .text = "" });
            }
        }

        const spliced = try applyEdits(lib.arena, file.source, edits.items);
        return std.mem.trim(u8, spliced, "\n");
    }

    /// Whether a fn_proto node belongs to a marked fn_decl.
    fn fnProtoOfMarkedDecl(lib: *Library, file_index: u32, ast: *const Ast, proto: Node.Index) bool {
        for (0..ast.nodes.len) |i| {
            const node: Node.Index = @enumFromInt(i);
            if (ast.nodeTag(node) != .fn_decl) continue;
            if (ast.nodeData(node).node_and_node[0] != proto) continue;
            return lib.isMarked(file_index, node);
        }
        return false;
    }

    fn format(lib: *Library, source: []const u8) ![]const u8 {
        const z = try lib.arena.dupeZ(u8, source);
        var ast = try Ast.parse(lib.arena, z, .zig);
        if (ast.errors.len != 0) {
            var buffer: [1024]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buffer);
            ast.renderError(ast.errors[0], &w) catch {};
            const loc = ast.tokenLocation(0, ast.errors[0].token);
            std.log.err("generated file does not parse: line {d}: {s}", .{ loc.line + 1, w.buffered() });
            return error.GeneratedSourceInvalid;
        }
        return ast.renderAlloc(lib.arena);
    }
};

// --------------------------------------------------------------------------
// AST helpers
// --------------------------------------------------------------------------

fn declName(ast: *const Ast, node: Node.Index) ?[]const u8 {
    if (ast.fullVarDecl(node)) |var_decl| return ast.tokenSlice(var_decl.ast.mut_token + 1);
    var buffer: [1]Node.Index = undefined;
    if (ast.fullFnProto(&buffer, node)) |proto| {
        const name = proto.name_token orelse return null;
        return ast.tokenSlice(name);
    }
    return null;
}

fn isComptimeBlock(ast: *const Ast, node: Node.Index) bool {
    return ast.nodeTag(node) == .@"comptime";
}

fn isPub(ast: *const Ast, node: Node.Index) bool {
    return visibToken(ast, node) != null;
}

fn visibToken(ast: *const Ast, node: Node.Index) ?Ast.TokenIndex {
    if (ast.fullVarDecl(node)) |var_decl| return var_decl.visib_token;
    var buffer: [1]Node.Index = undefined;
    if (ast.fullFnProto(&buffer, node)) |proto| return proto.visib_token;
    return null;
}

/// Byte range of a node's source, including a leading doc comment for
/// declarations — so deleting a declaration deletes its docs too.
fn nodeRange(ast: *const Ast, node: Node.Index) struct { u32, u32 } {
    var first = ast.firstToken(node);
    while (first > 0 and ast.tokenTag(first - 1) == .doc_comment) first -= 1;
    const last = ast.lastToken(node);
    const start = ast.tokenStart(first);
    const end = ast.tokenStart(last) + @as(u32, @intCast(ast.tokenSlice(last).len));
    return .{ start, end };
}

fn inRanges(offset: u32, ranges: []const Range) bool {
    for (ranges) |range| {
        if (offset >= range.start and offset < range.end) return true;
    }
    return false;
}

/// The leading `//!` block of a file, as a slice of its source, or null.
fn docCommentText(ast: *const Ast, source: []const u8) ?[]const u8 {
    if (ast.tokens.len == 0 or ast.tokenTag(0) != .container_doc_comment) return null;
    var last: Ast.TokenIndex = 0;
    while (last + 1 < ast.tokens.len and ast.tokenTag(last + 1) == .container_doc_comment) last += 1;
    const start = ast.tokenStart(0);
    var end = ast.tokenStart(last) + @as(u32, @intCast(ast.tokenSlice(last).len));
    if (end < source.len and source[end] == '\n') end += 1;
    return source[start..end];
}

fn applyEdits(arena: std.mem.Allocator, source: []const u8, edits: []const Edit) ![]u8 {
    const sorted = try arena.dupe(Edit, edits);
    std.mem.sort(Edit, sorted, {}, struct {
        fn lessThan(_: void, a: Edit, b: Edit) bool {
            return a.start < b.start;
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    var cursor: u32 = 0;
    for (sorted) |edit| {
        // Overlapping edits would mean two rewrites of one span; that is a bug
        // in this tool, not in the input.
        std.debug.assert(edit.start >= cursor);
        try out.appendSlice(arena, source[cursor..edit.start]);
        try out.appendSlice(arena, edit.text);
        cursor = edit.end;
    }
    try out.appendSlice(arena, source[cursor..]);
    return out.items;
}
