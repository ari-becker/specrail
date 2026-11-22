//! `specrail fmt`: puts spec files into canonical form. It renumbers sections
//! by position, and rewrites the references and dependency entries that name
//! them so that they keep naming the same sections. It never edits prose.

const std = @import("std");
const Allocator = std.mem.Allocator;

const changes = @import("changes.zig");
const cli = @import("cli.zig");
const diag = @import("diag.zig");
const project = @import("project.zig");
const refs = @import("refs.zig");
const rewrite = @import("rewrite.zig");
const spec = @import("spec.zig");
const toml = @import("toml.zig");

/// Help text for `specrail fmt --help`.
pub const usage =
    \\Usage: specrail fmt [--check [--json]] [<spec file or directory>...]
    \\
    \\Put spec files into canonical form: number sections by position, normalize
    \\headings and metadata blocks, and rewrite the references and dependency
    \\entries that name renumbered sections, anywhere in the project. Given paths,
    \\format only those spec files.
    \\
    \\Options:
    \\  --check   Write nothing; report each file that would change, and fail
    \\  --json    With --check, print one JSON object instead of diagnostic lines
    \\  --help    Show this help
    \\
;

/// Command-line options for `specrail fmt`.
pub const Options = struct {
    check: bool = false,
    json: bool = false,
    paths: []const []const u8 = &.{},
};

/// A file whose content fmt changes.
pub const Change = struct {
    path: []const u8,
    before: []const u8,
    after: []const u8,
};

/// Everything fmt would do, worked out before anything is written.
pub const Outcome = struct {
    changes: []const Change,
    /// The errors of the spec files fmt leaves alone.
    diagnostics: []const diag.Diagnostic,
};

/// How the sections of a spec file that fmt formats are renumbered.
const Plan = struct {
    file: *const spec.SpecFile,
    /// The new number of each section, by index.
    numbers: []const []const u8,
};

/// Works out what references and dependency entries should say.
const Renamer = struct {
    /// The spec files fmt formats, by path.
    plans: std.StringHashMapUnmanaged(Plan) = .empty,

    /// The number `form` should carry; null when it names no formatted file.
    /// A form that matches a heading exactly follows it; a stale one whose
    /// title matches exactly one section follows that section.
    fn number(r: *const Renamer, form: refs.Form) ?[]const u8 {
        const target = r.plans.get(form.path) orelse return null;
        const secs = target.file.sections;
        for (secs, 0..) |s, i| {
            const same_number = std.mem.eql(u8, s.number, form.number);
            if (same_number and std.mem.eql(u8, s.title, form.title)) return target.numbers[i];
        }
        var only: ?usize = null;
        for (secs, 0..) |s, i| {
            if (!std.mem.eql(u8, s.title, form.title)) continue;
            if (only != null) return form.number;
            only = i;
        }
        return if (only) |i| target.numbers[i] else form.number;
    }

    /// What `form` should say: the number its section now has.
    fn replace(context: *const anyopaque, form: refs.Form) ?rewrite.Replacement {
        const r: *const Renamer = @ptrCast(@alignCast(context));
        return .{ .number = r.number(form) orelse return null };
    }

    fn rewriter(r: *const Renamer) rewrite.Rewriter {
        return .{ .context = r, .replaceFn = replace };
    }
};

fn allBlank(lines: []const []const u8) bool {
    for (lines) |l| {
        if (std.mem.trim(u8, l, " \t\r\n").len > 0) return false;
    }
    return true;
}

/// Whether `lines`, as `SpecFile.lines` holds them, hold anything but blank
/// lines and the `---` lines fmt drops.
fn contentBefore(lines: []const []const u8, dropped: Dropped) bool {
    for (lines, 0..) |l, i| {
        const gone = i >= dropped.start and i < dropped.end and spec.isSeparator(l);
        if (!gone and !allBlank(lines[i .. i + 1])) return true;
    }
    return false;
}

/// A run of lines, by index, from `start` up to `end`.
const Dropped = struct {
    start: usize,
    end: usize,
};

/// The lines whose `---` lines fmt drops: none, or, when the separator has
/// nothing but blank lines before it, the separator and every `---` line
/// after it up to the first other content. Dropping only the separator would
/// make the next `---` line the separator, with nothing before it either, and
/// fmt would not be idempotent. `lines` are as `SpecFile.lines` holds them,
/// so that a `---` line is judged as the parser judged it, without the
/// carriage returns it takes off.
fn droppedSeparators(lines: []const []const u8, separator: ?usize) Dropped {
    const sep = separator orelse return .{ .start = 0, .end = 0 };
    if (!allBlank(lines[0..sep])) return .{ .start = 0, .end = 0 };
    var end = sep;
    while (end < lines.len) : (end += 1) {
        if (!allBlank(lines[end .. end + 1]) and !spec.isSeparator(lines[end])) break;
    }
    return .{ .start = sep, .end = end };
}

/// The number each section gets from its position.
fn positions(arena: Allocator, file: *const spec.SpecFile) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, file.sections.len);
    errdefer arena.free(out);
    var numbering: spec.Numbering = .{};
    for (file.sections, out) |s, *n| n.* = try numbering.next(arena, s.level);
    return out;
}

/// Keys whose values fmt rewrites, in the order fmt writes them. Any other key
/// keeps its value as written.
pub const known_keys = [_][]const u8{
    "status",
    "due",
    "assigned",
    "assigned-until",
    "dependencies",
};

/// Whether fmt knows `key`, rather than it being an extension key.
pub fn isKnown(key: []const u8) bool {
    for (known_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

/// Writes one spec file in canonical form.
const Formatter = struct {
    arena: Allocator,
    rewriter: rewrite.Rewriter,
    plan: Plan,
    /// The line ending the file uses.
    newline: []const u8,
    out: std.ArrayList(u8) = .empty,

    fn file(f: *const Formatter) *const spec.SpecFile {
        return f.plan.file;
    }

    /// The whole file, from its lines.
    fn format(f: *Formatter, raw: []const []const u8) Allocator.Error![]const u8 {
        const secs = f.file().sections;
        // The lines as the parser read them, to judge them as it did.
        const texts = f.file().lines;
        const heading_of = try f.arena.alloc(?usize, raw.len);
        defer f.arena.free(heading_of);
        @memset(heading_of, null);
        for (secs, 0..) |s, i| heading_of[s.line - 1] = i;
        const first: ?usize = if (secs.len > 0) secs[0].line - 1 else null;
        const separator = f.file().separator;
        var dropped = droppedSeparators(texts, separator);
        if (try f.promotesSeparator(raw, dropped)) dropped = .{ .start = 0, .end = 0 };
        // Whether a separator is missing is decided after dropping one, which
        // can leave content before the first section.
        const kept = separator != null and dropped.start == dropped.end;
        const add_separator = !kept and first != null and
            contentBefore(texts[0..first.?], dropped);
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (i >= dropped.start and i < dropped.end and spec.isSeparator(texts[i])) continue;
            const si = heading_of[i] orelse {
                try f.out.appendSlice(f.arena, raw[i]);
                continue;
            };
            if (add_separator and i == first.?) try f.out.print(
                f.arena,
                "{s}---{s}",
                .{ f.newline, f.newline },
            );
            const s = secs[si];
            try f.out.appendNTimes(f.arena, '#', s.level);
            try f.out.print(
                f.arena,
                " § {s} {s}{s}",
                .{ f.plan.numbers[si], s.title, rewrite.ending(raw[i]) },
            );
            const m = s.metadata orelse continue;
            // The block starts on the line after its opening fence; blank lines
            // between the heading and the block are dropped with it.
            const close = m.close_line - 1;
            try f.block(si, raw[m.line - 1 .. close + 1], raw[close + 1 ..]);
            i = close;
        }
        return f.out.toOwnedSlice(f.arena);
    }

    /// Whether dropping the `---` lines in `dropped` would make a later `---`
    /// line the separator, and so turn the sections above it into context.
    fn promotesSeparator(
        f: *Formatter,
        raw: []const []const u8,
        dropped: Dropped,
    ) Allocator.Error!bool {
        if (dropped.start == dropped.end) return false;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(f.arena);
        for (raw, f.file().lines, 0..) |l, t, i| {
            const gone = i >= dropped.start and i < dropped.end and spec.isSeparator(t);
            if (!gone) try text.appendSlice(f.arena, l);
        }
        var found: diag.List = .empty;
        defer found.deinit(f.arena);
        const without = try spec.parse(f.arena, f.file().path, text.items, &found);
        return without.separator != null;
    }

    /// Writes a section's metadata block in canonical form. `fences` are the
    /// block's lines, fences included, and `rest` the lines after them. A
    /// block left with no keys goes, unless another `toml` block follows it,
    /// which would take its place; then it stays, empty.
    fn block(
        f: *Formatter,
        si: usize,
        fences: []const []const u8,
        rest: []const []const u8,
    ) Allocator.Error!void {
        const m = f.file().sections[si].metadata.?;
        // The lines between the fences as the parser reads them: a carriage
        // return it drops from the end of a line, if kept in a value, would
        // join the line ending once written, and change the value.
        const lines = f.file().lines[m.line .. m.close_line - 1];
        const last_ending = rewrite.ending(fences[fences.len - 1]);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(f.arena);
        for (lines, 0..) |l, k| {
            if (k > 0) try text.appendSlice(f.arena, f.newline);
            try text.appendSlice(f.arena, l);
        }
        const doc = switch (try toml.parse(f.arena, text.items)) {
            .ok => |d| d,
            // Not expected, since the file is not broken; the block stays as written.
            .err => {
                for (fences) |l| try f.out.appendSlice(f.arena, l);
                return;
            },
        };
        var keys: std.ArrayList(toml.Entry) = .empty;
        defer keys.deinit(f.arena);
        for (known_keys) |k| {
            if (doc.get(k)) |e| try keys.append(f.arena, e);
        }
        for (doc.entries) |e| {
            if (!isKnown(e.key)) try keys.append(f.arena, e);
        }
        if (f.redundantStatus(si, doc)) _ = keys.orderedRemove(0);
        if (keys.items.len == 0) {
            // Removing the block would make the next one the metadata block.
            if (spec.tomlBlockFollows(rest)) {
                try f.out.print(f.arena, "```toml{s}```{s}", .{ f.newline, last_ending });
            }
            return;
        }
        var width: usize = 0;
        for (keys.items) |e| width = @max(width, e.key.len);
        try f.out.print(f.arena, "```toml{s}", .{f.newline});
        for (keys.items) |e| {
            try f.out.appendSlice(f.arena, e.key);
            try f.out.appendNTimes(f.arena, ' ', width - e.key.len);
            try f.out.print(f.arena, " = {s}{s}", .{ try f.value(e), f.newline });
        }
        try f.out.print(f.arena, "```{s}", .{last_ending});
    }

    /// Whether the section's `status = "done"` changes nothing, because it
    /// would be done without it.
    fn redundantStatus(f: *const Formatter, si: usize, doc: toml.Document) bool {
        const e = doc.get("status") orelse return false;
        if (e.value != .string or !std.mem.eql(u8, e.value.string, "done")) return false;
        const s = f.file().sections[si];
        const inherited: spec.Status = if (s.parent) |p| f.file().sections[p].effective else .done;
        return inherited == .done;
    }

    fn value(f: *const Formatter, e: toml.Entry) Allocator.Error![]const u8 {
        if (std.mem.eql(u8, e.key, "dependencies") and e.value == .array) {
            return f.dependencies(e.value.array);
        }
        if (isKnown(e.key) and e.value == .string) {
            return rewrite.basicString(f.arena, e.value.string);
        }
        return e.text;
    }

    fn dependencies(f: *const Formatter, items: []const toml.Item) Allocator.Error![]const u8 {
        if (items.len == 0) return "[]";
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(f.arena);
        try out.print(f.arena, "[{s}", .{f.newline});
        for (items) |item| {
            const text = if (item.value == .string)
                try f.dependency(item.value.string)
            else
                item.text;
            try out.print(f.arena, "  {s},{s}", .{ text, f.newline });
        }
        try out.append(f.arena, ']');
        return out.toOwnedSlice(f.arena);
    }

    fn dependency(f: *const Formatter, entry: []const u8) Allocator.Error![]const u8 {
        const rewritten = switch (refs.parseForm(entry, .required)) {
            .ok => |form| (try f.rewriter.rewrite(f.arena, entry, form)) orelse entry,
            .err => entry,
        };
        return rewrite.basicString(f.arena, rewritten);
    }
};

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, item)) return true;
    }
    return false;
}

/// Works out every change fmt makes, without writing anything. `selected`
/// lists the spec files to format; null formats all of them.
pub fn plan(
    arena: Allocator,
    spec_files: []const project.SourceFile,
    source_files: []const project.SourceFile,
    selected: ?[]const []const u8,
) Allocator.Error!Outcome {
    var problems: diag.List = .empty;
    errdefer problems.deinit(arena);
    var renamer: Renamer = .{};
    const parsed = try arena.alloc(spec.SpecFile, spec_files.len);
    for (spec_files, 0..) |f, i| {
        var found: diag.List = .empty;
        defer found.deinit(arena);
        parsed[i] = try spec.parse(arena, f.path, f.content, &found);
        const chosen = if (selected) |sel| contains(sel, f.path) else true;
        if (!chosen) continue;
        if (parsed[i].broken or parsed[i].duplicate) {
            for (found.items) |d| {
                if (d.severity == .err) try problems.append(arena, d);
            }
            continue;
        }
        const numbers = try positions(arena, &parsed[i]);
        try renamer.plans.put(arena, f.path, .{ .file = &parsed[i], .numbers = numbers });
    }

    const rewriter = renamer.rewriter();
    var planned: std.ArrayList(Change) = .empty;
    errdefer planned.deinit(arena);
    for (spec_files, 0..) |f, i| {
        if (parsed[i].broken or parsed[i].duplicate) continue;
        const raw = try rewrite.splitLines(arena, f.content);
        const after = if (renamer.plans.get(f.path)) |pl| formatted: {
            var formatter: Formatter = .{
                .arena = arena,
                .rewriter = rewriter,
                .plan = pl,
                .newline = rewrite.fileEnding(raw),
            };
            break :formatted try formatter.format(raw);
        } else (try rewrite.rewriteDependencies(arena, rewriter, &parsed[i], raw)) orelse continue;
        if (std.mem.eql(u8, after, f.content)) continue;
        try planned.append(arena, .{ .path = f.path, .before = f.content, .after = after });
    }
    for (source_files) |f| {
        const after = (try rewrite.rewriteReferences(arena, rewriter, f.content)) orelse continue;
        try planned.append(arena, .{ .path = f.path, .before = f.content, .after = after });
    }
    return .{
        .changes = try planned.toOwnedSlice(arena),
        .diagnostics = try problems.toOwnedSlice(arena),
    };
}

/// `content`, the text `file` was parsed from, as fmt would write it, but
/// with every section keeping its number: an editor's document formatting
/// changes one file, and renumbering changes the references in others too.
/// Null when the file has errors that keep fmt from rewriting it.
pub fn formatKeepingNumbers(
    arena: Allocator,
    file: *const spec.SpecFile,
    content: []const u8,
) Allocator.Error!?[]const u8 {
    if (file.broken or file.duplicate) return null;
    const numbers = try arena.alloc([]const u8, file.sections.len);
    for (file.sections, numbers) |s, *n| n.* = s.number;
    var renamer: Renamer = .{};
    const kept: Plan = .{ .file = file, .numbers = numbers };
    try renamer.plans.put(arena, file.path, kept);
    const raw = try rewrite.splitLines(arena, content);
    var formatter: Formatter = .{
        .arena = arena,
        .rewriter = renamer.rewriter(),
        .plan = kept,
        .newline = rewrite.fileEnding(raw),
    };
    return try formatter.format(raw);
}

/// Whether any section of `file` has a number other than the one its
/// position gives it, which `specrail fmt` would change.
pub fn outOfOrder(arena: Allocator, file: *const spec.SpecFile) Allocator.Error!bool {
    for (file.sections, try positions(arena, file)) |s, n| {
        if (!std.mem.eql(u8, s.number, n)) return true;
    }
    return false;
}

/// The 1-based line on which `after` first differs from `before`.
fn firstDifference(before: []const u8, after: []const u8) u32 {
    const n = @min(before.len, after.len);
    const at = for (0..n) |k| {
        if (before[k] != after[k]) break k;
    } else n;
    return @intCast(std.mem.count(u8, before[0..at], "\n") + 1);
}

/// Runs `specrail fmt` and returns its exit status.
pub fn run(ctx: *cli.Ctx, opts: Options) cli.Error!u8 {
    const p = (try project.open(ctx)) orelse return 2;
    const selected: ?[]const []const u8 = switch (try project.selectSpecs(
        ctx,
        p,
        opts.paths,
        "fmt",
    )) {
        .refused => return 2,
        .all => null,
        .some => |paths| paths,
    };
    const outcome = try plan(ctx.arena, p.spec_files, p.source_files, selected);
    if (!opts.check) {
        var pending: changes.Changes = .{ .ctx = ctx, .root = p.root, .command = "fmt" };
        for (outcome.changes) |c| {
            const w: changes.Write = .{ .origin = c.path, .path = c.path, .content = c.after };
            try pending.writes.append(ctx.arena, w);
        }
        const status = try pending.make();
        if (status != 0) return status;
    }
    var report: std.ArrayList(diag.Diagnostic) = .empty;
    defer report.deinit(ctx.arena);
    try report.appendSlice(ctx.arena, outcome.diagnostics);
    for (outcome.changes) |c| {
        try report.append(ctx.arena, .{
            .path = c.path,
            .line = firstDifference(c.before, c.after),
            .column = 1,
            .severity = if (opts.check) .err else .note,
            .message = if (opts.check) "not formatted; run specrail fmt" else "formatted",
        });
    }
    diag.sort(report.items);
    var errors: u32 = 0;
    for (report.items) |d| {
        if (d.severity == .err) errors += 1;
    }
    if (opts.json) {
        try ctx.stdout.writeAll("{\"diagnostics\":[");
        for (report.items, 0..) |d, i| {
            if (i > 0) try ctx.stdout.writeAll(",");
            try diag.writeJson(ctx.stdout, d);
        }
        try ctx.stdout.print("],\"summary\":{{\"files\":{d}}}}}\n", .{outcome.changes.len});
    } else {
        for (report.items) |d| try diag.write(ctx.stdout, d, ctx.color);
    }
    return if (errors > 0) 1 else 0;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const sandbox = @import("sandbox.zig");

/// The outcome of formatting files in memory.
const Formatted = struct {
    arena: std.heap.ArenaAllocator,
    outcome: Outcome,

    fn deinit(self: *Formatted) void {
        self.arena.deinit();
    }

    /// The content of `path` after formatting; null when fmt leaves it alone.
    fn after(self: *const Formatted, path: []const u8) ?[]const u8 {
        for (self.outcome.changes) |c| {
            if (std.mem.eql(u8, c.path, path)) return c.after;
        }
        return null;
    }

    fn expectAfter(self: *const Formatted, path: []const u8, expected: []const u8) !void {
        const got = self.after(path) orelse {
            std.debug.print("fmt left {s} unchanged\n", .{path});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings(expected, got);
    }

    fn expectUnchanged(self: *const Formatted, path: []const u8) !void {
        if (self.after(path)) |got| {
            std.debug.print("fmt changed {s} to:\n{s}\n", .{ path, got });
            return error.TestUnexpectedResult;
        }
    }

    fn expectProblem(self: *const Formatted, needle: []const u8) !void {
        for (self.outcome.diagnostics) |d| {
            if (std.mem.find(u8, d.message, needle) != null) return;
        }
        std.debug.print("no problem says '{s}'\n", .{needle});
        return error.TestUnexpectedResult;
    }
};

fn formatTest(
    spec_files: []const project.SourceFile,
    source_files: []const project.SourceFile,
    selected: ?[]const []const u8,
) !Formatted {
    var f: Formatted = .{ .arena = .init(testing.allocator), .outcome = undefined };
    f.outcome = try plan(f.arena.allocator(), spec_files, source_files, selected);
    return f;
}

/// One spec file, `specs/t.spec.md`, returned by value so that it outlives the call.
fn one(content: []const u8) [1]project.SourceFile {
    return .{.{ .path = "specs/t.spec.md", .content = content }};
}

// specrail: specs/cli/fmt.spec.md § 1.1 Heading spacing
test "headings get single spaces and no trailing whitespace" {
    var f = try formatTest(
        &.{.{ .path = "specs/t.spec.md", .content = "#   §  1   Title   \n\nIt MUST work.\n" }},
        &.{},
        null,
    );
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md", "# § 1 Title\n\nIt MUST work.\n");
}

// specrail: specs/cli/fmt.spec.md § 1.2 Missing separator
test "content before the first section gets a separator" {
    var f = try formatTest(
        &.{.{ .path = "specs/t.spec.md", .content = "Intro.\n# § 1 One\n\nIt MUST work.\n" }},
        &.{},
        null,
    );
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md", "Intro.\n\n---\n# § 1 One\n\nIt MUST work.\n");
}

// specrail: specs/cli/fmt.spec.md § 1.2 Missing separator
// specrail: specs/cli/fmt.spec.md § 1.3 Empty context
// specrail: specs/cli/fmt.spec.md § 4.4 Idempotence
test "a separator that separates nothing moves below the content after it" {
    // Found by fuzzing: dropping the separator left content before the first
    // section, and the next run added a separator back.
    var f = try formatTest(&one("\n---\nIntro.\n# § 1 One\n\nIt MUST work.\n"), &.{}, null);
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md", "\nIntro.\n\n---\n# § 1 One\n\nIt MUST work.\n");
}

// specrail: specs/cli/fmt.spec.md § 1.3 Empty context
// specrail: specs/cli/fmt.spec.md § 4.4 Idempotence
test "every --- line that would separate nothing goes at once" {
    // Found by fuzzing: dropping only the first, the separator, made the
    // second the separator for the next run to drop.
    var f = try formatTest(&one("\r\n---\r\n---\r\n\r\n---\r\nText.\r\n---\r\n"), &.{}, null);
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md", "\r\n\r\nText.\r\n---\r\n");
}

// specrail: specs/cli/fmt.spec.md § 1.3 Empty context
// specrail: specs/cli/fmt.spec.md § 4.4 Idempotence
test "a separator stays when removing it would make a later --- the separator" {
    // Found by fuzzing: the later --- became the separator, the sections
    // above it context, and the next run renumbered the rest.
    const content = "\n---\n# § 1 One\n\nIt MUST work.\n\n---\n\n# § 2 Two\n\nIt MUST work.\n";
    var f = try formatTest(&one(content), &.{}, null);
    defer f.deinit();
    try testing.expectEqual(@as(?[]const u8, null), f.after("specs/t.spec.md"));
}

// specrail: specs/cli/fmt.spec.md § 1.3 Empty context
test "a separator with nothing before it is removed" {
    var f = try formatTest(
        &.{.{ .path = "specs/t.spec.md", .content = "\n---\n\n# § 1 One\n\nIt MUST work.\n" }},
        &.{},
        null,
    );
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md", "\n\n# § 1 One\n\nIt MUST work.\n");
}

// specrail: specs/cli/fmt.spec.md § 1.3 Empty context
test "a separator ending in carriage returns, with nothing before it, is removed" {
    // The parser takes every carriage return off the end of a line, so it
    // reads ---\r\r as a --- line, and fmt must too.
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "\n---\r\r\n\n# § 1 One\n\nIt MUST work.\n", "\n\n# § 1 One\n\nIt MUST work.\n" },
        .{ "\n---\n---\r\r\n\n# § 1 One\n\nIt MUST work.\n", "\n\n# § 1 One\n\nIt MUST work.\n" },
    };
    for (cases) |c| {
        var f = try formatTest(&one(c[0]), &.{}, null);
        defer f.deinit();
        try f.expectAfter("specs/t.spec.md", c[1]);
    }
}

// specrail: specs/cli/fmt.spec.md § 1.4 Section sign
test "percent becomes the section sign in headings, references and dependencies" {
    var f = try formatTest(&.{
        .{ .path = "specs/t.spec.md", .content = "# % 1 One\n\nIt MUST work.\n" },
        .{ .path = "specs/d.spec.md", .content =
        \\# § 1 Waits
        \\```toml
        \\dependencies = ["specs/t.spec.md % 1 One"]
        \\```
        \\It MUST wait.
        \\
        },
    }, &.{.{ .path = "src/a.zig", .content = "x\n// specrail: specs/t.spec.md % 1 One\n" }}, null);
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md", "# § 1 One\n\nIt MUST work.\n");
    try f.expectAfter("specs/d.spec.md",
        \\# § 1 Waits
        \\```toml
        \\dependencies = [
        \\  "specs/t.spec.md § 1 One",
        \\]
        \\```
        \\It MUST wait.
        \\
    );
    try f.expectAfter("src/a.zig", "x\n// specrail: specs/t.spec.md § 1 One\n");
}

const lettered =
    \\# § 1 A
    \\
    \\It MUST a.
    \\
    \\# § 3 B
    \\## § 3.5 C
    \\
    \\It MUST c.
    \\
;

// specrail: specs/cli/fmt.spec.md § 2.1 Renumber by position
// specrail: specs/cli/fmt.spec.md § 2.2 Rewrite references
test "sections are renumbered, and what named them follows" {
    var f = try formatTest(&.{
        .{ .path = "specs/t.spec.md", .content = lettered },
        .{ .path = "specs/d.spec.md", .content =
        \\# § 1 Waits
        \\```toml
        \\dependencies = [
        \\  "specs/t.spec.md § 3 B",
        \\]
        \\```
        \\It MUST wait.
        \\
        },
    }, &.{.{ .path = "src/a.zig", .content =
        \\/* specrail: specs/t.spec.md § 3.5 C */
        \\// specrail: specs/t.spec.md  §  3.5  C
        \\// specrail: specs/t.spec.md § 1 A
        \\
    }}, null);
    defer f.deinit();
    try f.expectAfter(
        "specs/t.spec.md",
        "# § 1 A\n\nIt MUST a.\n\n# § 2 B\n## § 2.1 C\n\nIt MUST c.\n",
    );
    try f.expectAfter("specs/d.spec.md",
        \\# § 1 Waits
        \\```toml
        \\dependencies = [
        \\  "specs/t.spec.md § 2 B",
        \\]
        \\```
        \\It MUST wait.
        \\
    );
    try f.expectAfter("src/a.zig",
        \\/* specrail: specs/t.spec.md § 2.1 C */
        \\// specrail: specs/t.spec.md  §  2.1  C
        \\// specrail: specs/t.spec.md § 1 A
        \\
    );
}

// specrail: specs/cli/fmt.spec.md § 2.3 Repair number drift
test "a stale reference follows its title when the title is unique" {
    var f = try formatTest(&.{
        .{ .path = "specs/t.spec.md", .content = lettered },
        .{
            .path = "specs/u.spec.md",
            .content = "# § 1 Same\n\nIt MUST one.\n\n# § 2 Same\n\nIt MUST two.\n",
        },
    }, &.{
        .{ .path = "src/a.zig", .content = "// specrail: specs/t.spec.md § 9 C\n" },
        .{ .path = "src/b.zig", .content = "// specrail: specs/u.spec.md § 7 Same\n" },
    }, null);
    defer f.deinit();
    try f.expectAfter("src/a.zig", "// specrail: specs/t.spec.md § 2.1 C\n");
    try f.expectUnchanged("src/b.zig");
}

// specrail: specs/cli/fmt.spec.md § 2.4 Ambiguous headings
test "a file with duplicate headings is left alone, and so are references to it" {
    var f = try formatTest(
        &one("# § 2 One\n\nIt MUST work.\n\n# § 2 One\n\nIt MUST work.\n"),
        &.{.{ .path = "src/a.zig", .content = "// specrail: specs/t.spec.md § 2 One\n" }},
        null,
    );
    defer f.deinit();
    try f.expectUnchanged("specs/t.spec.md");
    try f.expectUnchanged("src/a.zig");
    try f.expectProblem("duplicate section § 2 One");
}

// specrail: specs/cli/fmt.spec.md § 3.1 Placement
test "blank lines between a heading and its metadata block are removed" {
    var f = try formatTest(
        &one("# § 1 One\n\n```toml\nstatus = \"planned\"\n```\nIt MUST work.\n"),
        &.{},
        null,
    );
    defer f.deinit();
    try f.expectAfter(
        "specs/t.spec.md",
        "# § 1 One\n```toml\nstatus = \"planned\"\n```\nIt MUST work.\n",
    );
}

// specrail: specs/cli/fmt.spec.md § 3.2 Key order
// specrail: specs/cli/fmt.spec.md § 3.3 Alignment
// specrail: specs/cli/fmt.spec.md § 3.4 Values
test "metadata keys are ordered, aligned, and written canonically" {
    var f = try formatTest(&one(
        \\# § 1 One
        \\```toml
        \\x-b          = 'kept as written'
        \\dependencies = ['specs/t.spec.md § 2 Two']
        \\assigned = 'someone'
        \\x-a = [1,2]
        \\status = 'planned'
        \\```
        \\It MUST work.
        \\
        \\# § 2 Two
        \\
        \\It MUST work.
        \\
    ), &.{}, null);
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md",
        \\# § 1 One
        \\```toml
        \\status       = "planned"
        \\assigned     = "someone"
        \\dependencies = [
        \\  "specs/t.spec.md § 2 Two",
        \\]
        \\x-b          = 'kept as written'
        \\x-a          = [1,2]
        \\```
        \\It MUST work.
        \\
        \\# § 2 Two
        \\
        \\It MUST work.
        \\
    );
}

// specrail: specs/cli/fmt.spec.md § 3.5 Redundant metadata
test "an empty block stays when the next block would take its place" {
    // Found by fuzzing: without it, the code block below became metadata.
    const prose = "\n```toml\nx = 1\n```\nIt MUST work.\n";
    const content = "# § 1 One\n```toml\nstatus = \"done\"\n```\n" ++ prose;
    var f = try formatTest(&one(content), &.{}, null);
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md", "# § 1 One\n```toml\n```\n" ++ prose);
}

// specrail: specs/cli/fmt.spec.md § 3.5 Redundant metadata
test "a done status that changes nothing is removed, and so is an empty block" {
    var f = try formatTest(&one(
        \\# § 1 Done already
        \\```toml
        \\status = "done"
        \\```
        \\It MUST work.
        \\
        \\# § 2 Planned
        \\```toml
        \\status = "planned"
        \\```
        \\## § 2.1 Finished early
        \\```toml
        \\status = "done"
        \\```
        \\It MUST work.
        \\
        \\# § 3 Extension only
        \\```toml
        \\status = "done"
        \\x-note = "kept"
        \\```
        \\It MUST work.
        \\
    ), &.{}, null);
    defer f.deinit();
    try f.expectAfter("specs/t.spec.md",
        \\# § 1 Done already
        \\It MUST work.
        \\
        \\# § 2 Planned
        \\```toml
        \\status = "planned"
        \\```
        \\## § 2.1 Finished early
        \\```toml
        \\status = "done"
        \\```
        \\It MUST work.
        \\
        \\# § 3 Extension only
        \\```toml
        \\x-note = "kept"
        \\```
        \\It MUST work.
        \\
    );
}

// specrail: specs/cli/fmt.spec.md § 4.1 Scope
test "given paths, only those files are formatted, but what names them follows" {
    var f = try formatTest(&.{
        .{ .path = "specs/a.spec.md", .content = "# § 3 A\n\nIt MUST a.\n" },
        .{ .path = "specs/b.spec.md", .content =
        \\#  § 1  B
        \\```toml
        \\dependencies = ["specs/a.spec.md § 3 A"]
        \\```
        \\It MUST b.
        \\
        },
    }, &.{
        .{ .path = "src/a.zig", .content = "// specrail: specs/a.spec.md § 3 A\n" },
    }, &.{"specs/a.spec.md"});
    defer f.deinit();
    try f.expectAfter("specs/a.spec.md", "# § 1 A\n\nIt MUST a.\n");
    try f.expectAfter("specs/b.spec.md",
        \\#  § 1  B
        \\```toml
        \\dependencies = ["specs/a.spec.md § 1 A"]
        \\```
        \\It MUST b.
        \\
    );
    try f.expectAfter("src/a.zig", "// specrail: specs/a.spec.md § 1 A\n");
}

// specrail: specs/cli/fmt.spec.md § 4.3 Untouched lines
test "lines fmt does not rewrite keep their bytes and line endings" {
    var f = try formatTest(&.{
        .{ .path = "specs/t.spec.md", .content = "Intro.\r\n# § 3 One\r\n\r\nIt MUST work.  \r\n" },
        .{
            .path = "specs/u.spec.md",
            .content = "Intro.\n\n---\n\n# § 1 One\n\nIt  MUST  work.\n",
        },
    }, &.{}, null);
    defer f.deinit();
    try f.expectAfter(
        "specs/t.spec.md",
        "Intro.\r\n\r\n---\r\n# § 1 One\r\n\r\nIt MUST work.  \r\n",
    );
    try f.expectUnchanged("specs/u.spec.md");
}

// specrail: specs/cli/fmt.spec.md § 4.4 Idempotence
test "formatting formatted files changes nothing" {
    const messy = [_]project.SourceFile{
        .{ .path = "specs/t.spec.md", .content =
        \\Intro.
        \\#  %  4  One
        \\
        \\```toml
        \\x-z = 1
        \\status = 'planned'
        \\dependencies = ["specs/t.spec.md % 9 Two"]
        \\```
        \\## § 4.7 Two
        \\
        \\It MUST work.
        \\
        },
    };
    const sources = [_]project.SourceFile{
        .{ .path = "src/a.zig", .content = "// specrail: specs/t.spec.md § 4.7 Two\n" },
    };
    var first = try formatTest(&messy, &sources, null);
    defer first.deinit();
    const tidy = [_]project.SourceFile{
        .{ .path = "specs/t.spec.md", .content = first.after("specs/t.spec.md").? },
    };
    const tidy_sources = [_]project.SourceFile{
        .{ .path = "src/a.zig", .content = first.after("src/a.zig").? },
    };
    var second = try formatTest(&tidy, &tidy_sources, null);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 0), second.outcome.changes.len);
}

// specrail: specs/cli/fmt.spec.md § 4.4 Idempotence
test "a value whose lines end in carriage returns is formatted once" {
    // A carriage return the parser drops from the end of a line inside the
    // value, if kept, joins the line ending when written, and changes the
    // value the next run reads.
    const contents = [_][]const u8{
        "# § 1 One\n```toml\nx = [\n\r\r\n]\n```\n\nIt MUST work.\n",
        "# § 1 One\n```toml\nx = [\n  1,\r\r\r\n]\n```\n\nIt MUST work.\n",
    };
    for (contents) |content| {
        var first = try formatTest(&one(content), &.{}, null);
        defer first.deinit();
        var second = try formatTest(&one(first.after("specs/t.spec.md").?), &.{}, null);
        defer second.deinit();
        try second.expectUnchanged("specs/t.spec.md");
    }
}

// specrail: specs/cli/fmt.spec.md § 4.5 Unparseable files
test "files whose tree or metadata cannot be read are left alone and reported" {
    var f = try formatTest(&.{
        .{ .path = "specs/a.spec.md", .content = "## § 3 Starts deep\n\nIt MUST work.\n" },
        .{
            .path = "specs/b.spec.md",
            .content = "# § 3 One\n```toml\nstatus = \n```\nIt MUST work.\n",
        },
        .{
            .path = "specs/c.spec.md",
            .content = "# § 3 One\n```toml\n# why\nstatus = \"planned\"\n```\nIt MUST work.\n",
        },
    }, &.{.{ .path = "src/a.zig", .content = "// specrail: specs/b.spec.md § 3 One\n" }}, null);
    defer f.deinit();
    try f.expectUnchanged("specs/a.spec.md");
    try f.expectUnchanged("specs/b.spec.md");
    try f.expectUnchanged("specs/c.spec.md");
    try f.expectUnchanged("src/a.zig");
    try f.expectProblem("must be level 1");
    try f.expectProblem("invalid metadata");
    try f.expectProblem("comments are not allowed");
}

fn unformattedProject(s: *sandbox.Sandbox) !void {
    try s.write("specrail.toml", "spec_root = \"specs\"\n");
    try s.write("specs/a.spec.md", "# § 2 One\n\nIt MUST work.\n");
    try s.write("src/a_test.zig", "// specrail: specs/a.spec.md § 2 One\n");
}

// specrail: specs/cli/fmt.spec.md § 4.2 Check mode
// specrail: specs/cli/fmt.spec.md § 4.6 Diagnostic lines
test "fmt --check reports what would change, sorted, and writes nothing" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try unformattedProject(&s);
    const checked = try s.runAtRoot(&.{ "fmt", "--check" });
    try testing.expectEqual(@as(u8, 1), checked.code);
    try testing.expectEqualStrings(
        "specs/a.spec.md:1:1: error: not formatted; run specrail fmt\n" ++
            "src/a_test.zig:1:1: error: not formatted; run specrail fmt\n",
        checked.stdout,
    );
    try testing.expectEqualStrings("# § 2 One\n\nIt MUST work.\n", try s.read("specs/a.spec.md"));

    const written = try s.runAtRoot(&.{"fmt"});
    try testing.expectEqual(@as(u8, 0), written.code);
    try testing.expectEqualStrings("# § 1 One\n\nIt MUST work.\n", try s.read("specs/a.spec.md"));
    try testing.expectEqualStrings(
        "// specrail: specs/a.spec.md § 1 One\n",
        try s.read("src/a_test.zig"),
    );
    const clean = try s.runAtRoot(&.{ "fmt", "--check" });
    try testing.expectEqual(@as(u8, 0), clean.code);
    try testing.expectEqualStrings("", clean.stdout);
    try testing.expectEqual(@as(u8, 0), (try s.runAtRoot(&.{"check"})).code);
}

// specrail: specs/cli/fmt.spec.md § 4.7 JSON output
test "fmt --check --json prints one JSON object" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try unformattedProject(&s);
    const o = try s.runAtRoot(&.{ "fmt", "--check", "--json" });
    try testing.expectEqual(@as(u8, 1), o.code);
    try testing.expectEqualStrings(
        "{\"diagnostics\":[" ++
            "{\"path\":\"specs/a.spec.md\",\"line\":1,\"column\":1,\"severity\":\"error\"," ++
            "\"message\":\"not formatted; run specrail fmt\"}," ++
            "{\"path\":\"src/a_test.zig\",\"line\":1,\"column\":1,\"severity\":\"error\"," ++
            "\"message\":\"not formatted; run specrail fmt\"}]," ++
            "\"summary\":{\"files\":2}}\n",
        o.stdout,
    );
    try testing.expectEqual(@as(u8, 2), (try s.runAtRoot(&.{ "fmt", "--json" })).code);
}

// specrail: specs/cli/fmt.spec.md § 4.8 Symbolic links
test "fmt refuses to write through a symbolic link" {
    const reference = "// specrail: specs/a.spec.md § 2 One\n";
    var outside = try sandbox.Sandbox.init();
    defer outside.deinit();
    try outside.write("t.zig", reference);
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try s.write("specrail.toml", "spec_root = \"specs\"\n");
    const misnumbered = "# § 2 One\n\nIt MUST work.\n";
    try s.write("specs/a.spec.md", misnumbered);
    const target = try std.Io.Dir.path.join(testing.allocator, &.{ outside.root, "t.zig" });
    defer testing.allocator.free(target);
    try s.symlink(target, "src/t.zig");
    const o = try s.runAtRoot(&.{"fmt"});
    try testing.expectEqual(@as(u8, 2), o.code);
    try sandbox.expectContains(o.stderr, "src/t.zig is a symbolic link");
    try testing.expectEqualStrings(misnumbered, try s.read("specs/a.spec.md"));
    try testing.expectEqualStrings(reference, try outside.read("t.zig"));
    // With --check nothing is written, so the link is no hazard.
    try testing.expectEqual(@as(u8, 1), (try s.runAtRoot(&.{ "fmt", "--check" })).code);
}

// specrail: specs/cli/fmt.spec.md § 4.9 Failed writes
test "when a file cannot be written, fmt changes nothing and cleans up" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try s.write("specrail.toml", "spec_root = \"specs\"\n");
    const misnumbered = "# § 2 One\n\nIt MUST work.\n";
    try s.write("specs/a.spec.md", misnumbered);
    const reference = "// specrail: specs/a.spec.md § 2 One\n";
    try s.write("src/t.zig", reference);
    // The spec file is written first, and then src/t.zig. Something already
    // at src/t.zig's temporary path makes the second write fail after the
    // first is staged.
    try s.write("src/.t.zig.1.specrail-tmp/blocker", "");
    const o = try s.runAtRoot(&.{"fmt"});
    try testing.expectEqual(@as(u8, 2), o.code);
    try sandbox.expectContains(o.stderr, "cannot write src/t.zig");
    try sandbox.expectContains(o.stderr, "nothing was changed");
    try testing.expectEqualStrings(misnumbered, try s.read("specs/a.spec.md"));
    try testing.expectEqualStrings(reference, try s.read("src/t.zig"));
    try testing.expect(!s.exists("specs/.a.spec.md.0.specrail-tmp"));
    try testing.expect(s.exists("src/.t.zig.1.specrail-tmp/blocker"));
}

// specrail: specs/cli/fmt.spec.md § 4.9 Failed writes
test "fmt keeps the permissions of the files it rewrites" {
    var s = try sandbox.Sandbox.init();
    defer s.deinit();
    try s.write("specrail.toml", "spec_root = \"specs\"\n");
    try s.write("specs/a.spec.md", "# § 2 One\n\nIt MUST work.\n");
    try s.write("run.sh", "#!/bin/sh\n# specrail: specs/a.spec.md § 2 One\n");
    const executable: std.Io.File.Permissions = .fromMode(0o755);
    try s.tmp.dir.setFilePermissions(testing.io, "run.sh", executable, .{});
    try testing.expectEqual(@as(u8, 0), (try s.runAtRoot(&.{"fmt"})).code);
    try testing.expectEqualStrings(
        "#!/bin/sh\n# specrail: specs/a.spec.md § 1 One\n",
        try s.read("run.sh"),
    );
    const st = try s.tmp.dir.statFile(testing.io, "run.sh", .{});
    try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
}

// ---------------------------------------------------------------- fuzz tests

const check = @import("check.zig");
const fuzzing = @import("fuzzing.zig");

/// `files` with `made` made.
fn applied(
    arena: Allocator,
    files: []const project.SourceFile,
    made: []const Change,
) Allocator.Error![]const project.SourceFile {
    const out = try arena.dupe(project.SourceFile, files);
    for (out) |*f| {
        for (made) |c| {
            if (std.mem.eql(u8, c.path, f.path)) f.content = c.after;
        }
    }
    return out;
}

/// Shows what fmt did to one file, for a failure.
fn show(change: Change) void {
    const parts = .{ change.path, change.before, change.after };
    std.debug.print("--- {s} before\n{s}\n--- after\n{s}\n---\n", parts);
}

/// Formatting changes nothing in fmt's own output, and every reference and
/// dependency entry that named a leaf exactly still does afterwards.
fn formatTwice(_: void, smith: *testing.Smith) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const specs = [_]project.SourceFile{
        .{ .path = fuzzing.spec_paths[0], .content = try fuzzing.specText(smith, arena) },
        .{ .path = fuzzing.spec_paths[1], .content = try fuzzing.specText(smith, arena) },
    };
    const sources = [_]project.SourceFile{
        .{ .path = "src/t.zig", .content = try fuzzing.sourceText(smith, arena) },
    };
    const once = try plan(arena, &specs, &sources, null);
    const specs_after = try applied(arena, &specs, once.changes);
    const sources_after = try applied(arena, &sources, once.changes);
    const twice = try plan(arena, specs_after, sources_after, null);
    if (twice.changes.len != 0) {
        for (once.changes) |c| show(c);
        for (twice.changes) |c| show(c);
        return error.TestNotIdempotent;
    }
    const before = try check.analyze(arena, .{ .spec_files = &specs, .source_files = &sources }, 0);
    const input_after: check.Input = .{ .spec_files = specs_after, .source_files = sources_after };
    const after = try check.analyze(arena, input_after, 0);
    if (after.references.len < before.references.len) {
        for (once.changes) |c| show(c);
        return error.TestReferenceLost;
    }
}

// specrail: specs/cli/fmt.spec.md § 2.2 Rewrite references
// specrail: specs/cli/fmt.spec.md § 4.4 Idempotence
test "fuzz: fmt's output is its own, and references still match" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const corpus = try fuzzing.seeds(arena_state.allocator(), &.{});
    try testing.fuzz({}, formatTwice, .{ .corpus = corpus });
}
