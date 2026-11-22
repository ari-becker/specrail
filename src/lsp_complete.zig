//! Completion for the language server: spec file paths, and then the headings
//! of the file named, wherever a section is written in reference form: on a
//! reference line, after `specrail:`, and inside a `dependencies` entry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const nav = @import("lsp_nav.zig");
const refs = @import("refs.zig");
const rewrite = @import("rewrite.zig");
const text = @import("lsp_text.zig");

/// LSP's kinds for the two sorts of completion.
const file_kind = 17;
const reference_kind = 18;

/// One completion: what to show, and the edit that inserts it.
pub const Item = struct {
    label: []const u8,
    kind: u8,
    /// What the editor filters by, which is what was typed as written.
    filter: []const u8,
    range: nav.Range,
    insert: []const u8,

    /// Writes the item with the names LSP gives these fields.
    pub fn jsonStringify(item: Item, w: *json.Stringify) json.Stringify.Error!void {
        try w.write(.{
            .label = item.label,
            .kind = item.kind,
            .filterText = item.filter,
            .textEdit = .{ .range = item.range, .newText = item.insert },
        });
    }
};

/// Characters that may come before `specrail:` on a reference line.
const prefix_chars = " \t/*#-;%!<({";

/// Where the reference form starts on a reference line, given the line up to
/// the cursor; null when the line is not a reference line there.
fn referenceStart(before: []const u8) ?usize {
    const at = std.mem.find(u8, before, refs.marker) orelse return null;
    for (before[0..at]) |c| {
        if (std.mem.findScalar(u8, prefix_chars, c) == null) return null;
    }
    var start = at + refs.marker.len;
    while (start < before.len and (before[start] == ' ' or before[start] == '\t')) start += 1;
    return start;
}

/// The key of a `key = value` line, when the line is one.
fn keyOf(line: []const u8) ?[]const u8 {
    const eq = std.mem.findScalar(u8, line, '=') orelse return null;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    if (key.len == 0) return null;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;
    }
    return key;
}

fn isHeading(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " ");
    const signed = std.mem.find(u8, t, refs.section_sign) != null or
        std.mem.findScalar(u8, t, '%') != null;
    return t.len > 0 and t[0] == '#' and signed;
}

/// `line`, with its ending, without the blanks around it, and without every
/// carriage return at its end, which the parser takes off too.
fn trimmed(line: []const u8) []const u8 {
    return std.mem.trim(u8, std.mem.trimEnd(u8, line, "\r\n"), " \t");
}

/// Whether line `index` of `lines` lies in the `dependencies` value of a
/// metadata block. The lines are read as written, since a block being edited
/// may not parse.
fn inDependencies(lines: []const []const u8, index: usize) bool {
    var dependencies: ?bool = null;
    var i = index + 1;
    // Each step moves one line up, so the loop ends at the top of the file.
    while (i > 0) {
        i -= 1;
        const l = trimmed(lines[i]);
        if (std.mem.startsWith(u8, l, "```")) {
            if (!std.mem.eql(u8, l, "```toml") or dependencies != true) return false;
            // The block is a metadata block: the first thing after a heading.
            var above = i;
            while (above > 0) {
                above -= 1;
                const prev = trimmed(lines[above]);
                if (prev.len > 0) return isHeading(prev);
            }
            return false;
        }
        if (dependencies == null) {
            if (keyOf(l)) |key| dependencies = std.mem.eql(u8, key, "dependencies");
        }
    }
    return false;
}

/// Where the reference form starts in a dependency entry, given the line up
/// to the cursor: just after the quote that opens the string the cursor is
/// in. Null when the cursor is not in a string.
fn entryStart(before: []const u8) ?usize {
    var open: ?usize = null;
    for (before, 0..) |c, i| {
        if (c != '"' and c != '\'') continue;
        open = if (open == null) i + 1 else null;
    }
    return open;
}

/// The completions at byte `byte` of line `index`, counted from 0, of the
/// file at `path`.
pub fn complete(
    ix: *const nav.Index,
    arena: Allocator,
    path: []const u8,
    index: u32,
    byte: usize,
) Allocator.Error![]const Item {
    const content = ix.contents.get(path) orelse return &.{};
    const line = text.lineAt(content, index);
    const before = line[0..@min(byte, line.len)];
    const start = if (ix.analysis.file(path) != null) spec: {
        const lines = try rewrite.splitLines(arena, content);
        if (index >= lines.len or !inDependencies(lines, index)) return &.{};
        break :spec entryStart(before);
    } else referenceStart(before);
    const from = start orelse return &.{};
    return forms(ix, arena, line, index, .{ .start = from, .end = before.len });
}

/// The part of a line being completed, in bytes.
const Span = struct {
    start: usize,
    end: usize,
};

/// Spec file paths, or, once a section sign follows the path, the headings
/// of that spec file.
fn forms(
    ix: *const nav.Index,
    arena: Allocator,
    line: []const u8,
    index: u32,
    span: Span,
) Allocator.Error![]const Item {
    const typed = line[span.start..span.end];
    var out: std.ArrayList(Item) = .empty;
    errdefer out.deinit(arena);
    const sign = std.mem.find(u8, typed, refs.section_sign) orelse
        std.mem.findScalar(u8, typed, '%');
    if (sign) |at| {
        const file = ix.analysis.file(std.mem.trim(u8, typed[0..at], " \t")) orelse return &.{};
        const written = if (typed[at] == '%') "%" else refs.section_sign;
        const range = rangeOf(ix, line, index, .{ .start = span.start + at, .end = span.end });
        for (file.sections) |s| {
            try out.append(arena, .{
                .label = try arena.print("{s} {s} {s}", .{ refs.section_sign, s.number, s.title }),
                .kind = reference_kind,
                .filter = try arena.print("{s} {s} {s}", .{ written, s.number, s.title }),
                .range = range,
                .insert = try arena.print("{s} {s} {s}", .{ refs.section_sign, s.number, s.title }),
            });
        }
        return out.toOwnedSlice(arena);
    }
    const range = rangeOf(ix, line, index, span);
    for (ix.analysis.specs) |file| {
        const item: Item = .{
            .label = file.path,
            .kind = file_kind,
            .filter = file.path,
            .range = range,
            .insert = file.path,
        };
        try out.append(arena, item);
    }
    return out.toOwnedSlice(arena);
}

fn rangeOf(ix: *const nav.Index, line: []const u8, index: u32, span: Span) nav.Range {
    return .{
        .start = .{ .line = index, .character = text.column(line, span.start, ix.encoding) },
        .end = .{ .line = index, .character = text.column(line, span.end, ix.encoding) },
    };
}

test "a reference form starts after specrail: and blanks, behind comment markers only" {
    try std.testing.expectEqual(@as(?usize, 13), referenceStart("// specrail: specs/a"));
    try std.testing.expectEqual(@as(?usize, 15), referenceStart("<!-- specrail: "));
    try std.testing.expectEqual(@as(?usize, null), referenceStart("const x = \"specrail: "));
    try std.testing.expectEqual(@as(?usize, null), referenceStart("// a note"));
}

test "a dependency entry is found by the lines above it, even unparsed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const content =
        \\## § 1.1 Waits
        \\```toml
        \\status       = "planned"
        \\dependencies = [
        \\  "specs/a.spec.md § 1
        \\x-note = "specs
        \\```
        \\```toml
        \\dependencies = ["specs
    ;
    const lines = try rewrite.splitLines(arena_state.allocator(), content);
    try std.testing.expect(inDependencies(lines, 3));
    try std.testing.expect(inDependencies(lines, 4));
    try std.testing.expect(!inDependencies(lines, 5));
    try std.testing.expect(!inDependencies(lines, 2));
    // A toml block that does not follow a heading is not metadata.
    try std.testing.expect(!inDependencies(lines, 8));
    try std.testing.expectEqual(@as(?usize, 3), entryStart("  \"spe"));
    try std.testing.expectEqual(@as(?usize, null), entryStart("  \"specs/a.spec.md § 1 One\","));
}

test "a dependency entry is found past lines that end in carriage returns" {
    // The parser takes every carriage return off the end of a line, so to it
    // ```toml\r\r opens a metadata block, and \r\r is a blank line.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { []const u8, usize }{
        .{ "# § 1 Waits\n```toml\r\r\ndependencies = [\n  \"specs/a.spec.md § 1\n", 3 },
        .{ "# § 1 Waits\n\r\r\n```toml\ndependencies = [\n  \"specs/a.spec.md § 1\n", 4 },
    };
    for (cases) |c| {
        const whole = try std.mem.concat(arena, u8, &.{ c[0], "\",\n]\n```\nIt MUST wait.\n" });
        var found: diag.List = .empty;
        const file = try spec.parse(arena, "specs/b.spec.md", whole, &found);
        try std.testing.expect(file.sections[0].metadata != null);
        const lines = try rewrite.splitLines(arena, c[0]);
        try std.testing.expect(inDependencies(lines, c[1]));
    }
}

// ---------------------------------------------------------------- fuzz tests

const testing = std.testing;

const diag = @import("diag.zig");
const edit = @import("edit.zig");
const fuzzing = @import("fuzzing.zig");
const project = @import("project.zig");
const spec = @import("spec.zig");

const fuzzed = edit.fuzzed;

/// The comment markers a made-up reference line starts with; the last is
/// not one, so its line is no reference line.
const line_starts = [_][]const u8{ "// ", "# ", "-- ", "<!-- ", "/* ", "  ", "x = \"" };

/// A reference form cut short: part of a spec file's path, or its whole
/// path and a section sign, then maybe part of one of its headings, or the
/// path of no spec file.
fn partialForm(smith: *testing.Smith, arena: Allocator, ix: *const nav.Index) ![]const u8 {
    const file = &ix.analysis.specs[smith.index(ix.analysis.specs.len)];
    const path = if (smith.boolWeighted(7, 1)) "specs/none.spec.md" else file.path;
    // A seed read back says no to every choice, so this one also turns on the
    // made-up file, for seeds to try both sides.
    const cut_path = smith.value(bool) != (file.sections.len % 2 == 0);
    if (cut_path) return path[0..smith.index(path.len + 1)];
    const sign = if (smith.value(bool)) "%" else refs.section_sign;
    var heading: []const u8 = "";
    if (file.sections.len > 0) {
        const s = file.sections[smith.index(file.sections.len)];
        heading = try arena.print("{s} {s}", .{ s.number, s.title });
    }
    const spaces = if (smith.value(bool)) " " else "  ";
    // An editor's text is UTF-8, so the cut falls between characters.
    var cut = smith.index(heading.len + 1);
    while (cut < heading.len and heading[cut] & 0xc0 == 0x80) cut -= 1;
    const typed = heading[0..cut];
    return arena.print("{s}{s}{s} {s}", .{ path, spaces, sign, typed });
}

/// What completion should offer for `typed`, the reference form so far.
const Expected = union(enum) {
    headings: *const spec.SpecFile,
    nothing,
    paths,
};

fn expected(ix: *const nav.Index, typed: []const u8) Expected {
    const at = std.mem.find(u8, typed, refs.section_sign) orelse
        std.mem.findScalar(u8, typed, '%') orelse return .paths;
    const file = ix.analysis.file(std.mem.trim(u8, typed[0..at], " \t")) orelse return .nothing;
    return .{ .headings = file };
}

/// `line` with `item` made, as an editor makes it.
fn applied(arena: Allocator, line: []const u8, item: Item, encoding: text.Encoding) ![]const u8 {
    const start = text.byteOffset(line, item.range.start.character, encoding);
    const end = text.byteOffset(line, item.range.end.character, encoding);
    return std.mem.concat(arena, u8, &.{ line[0..start], item.insert, line[end..] });
}

/// Whether `form` names a section of `file` exactly.
fn namesExactly(file: *const spec.SpecFile, form: refs.Form) bool {
    if (!std.mem.eql(u8, form.path, file.path)) return false;
    for (file.sections) |s| {
        if (std.mem.eql(u8, s.number, form.number) and std.mem.eql(u8, s.title, form.title)) {
            return true;
        }
    }
    return false;
}

/// Where the made-up completion is asked for: the file, its line, the text
/// of the line, and the bytes of it before the cursor.
const Ask = struct {
    path: []const u8,
    index: u32,
    line: []const u8,
    cursor: usize,
    /// The form completed lies between this byte and the cursor.
    form_start: usize,
};

/// A project with one more file, which holds a reference form cut short:
/// on a reference line, or in a dependency entry of a spec file.
fn askingProject(
    smith: *testing.Smith,
    arena: Allocator,
    before: project.Project,
    partial: []const u8,
) !struct { project.Project, Ask } {
    var proj = before;
    // A seed read back says no to every choice, so this one also turns on the
    // made-up project, for seeds to try both kinds of line.
    const on_reference_line = smith.value(bool) != (before.source_files[0].content.len % 2 == 0);
    if (on_reference_line) {
        const start = fuzzing.pick(smith, &line_starts);
        const line = try arena.print("{s}specrail: {s}", .{ start, partial });
        const sources = try std.mem.concat(arena, project.SourceFile, &.{
            before.source_files,
            &.{.{ .path = "src/asked.zig", .content = line }},
        });
        proj.source_files = sources;
        const form_start = start.len + "specrail: ".len;
        const ask: Ask = .{
            .path = "src/asked.zig",
            .index = 0,
            .line = line,
            .cursor = line.len,
            .form_start = form_start,
        };
        return .{ proj, ask };
    }
    const entry = "dependencies = [\"";
    const line = try arena.print("{s}{s}\"]", .{ entry, partial });
    const content = try arena.print("# § 1 Waits\n```toml\n{s}\n```\n\nIt MUST wait.\n", .{line});
    const specs = try std.mem.concat(arena, project.SourceFile, &.{
        before.spec_files,
        &.{.{ .path = "specs/asked.spec.md", .content = content }},
    });
    proj.spec_files = specs;
    const cursor = entry.len + partial.len;
    const ask: Ask = .{
        .path = "specs/asked.spec.md",
        .index = 2,
        .line = line,
        .cursor = cursor,
        .form_start = entry.len,
    };
    return .{ proj, ask };
}

/// The reference form on `line`, a reference line or a dependency entry,
/// once completed.
fn formOn(line: []const u8, ask: Ask) ?refs.Form {
    if (std.mem.endsWith(u8, ask.path, ".spec.md")) {
        const close = std.mem.findScalarPos(u8, line, ask.form_start, '"') orelse return null;
        return switch (refs.parseForm(line[ask.form_start..close], .required)) {
            .ok => |f| f,
            .err => null,
        };
    }
    const found = refs.scanLine(line) orelse return null;
    return switch (found.result) {
        .ok => |f| f,
        .err => null,
    };
}

/// Completing a reference form cut short offers every spec file path before
/// a section sign, and after one every heading of the file named, each of
/// which, once made, names its section exactly; anywhere else, nothing.
fn completeAForm(_: void, smith: *testing.Smith) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try fuzzed.madeUp(smith, arena);
    const encoding: text.Encoding = if (smith.value(bool)) .utf16 else .utf8;
    const partial = try partialForm(smith, arena, &try nav.Index.build(arena, before, encoding, 0));
    const proj, const ask = try askingProject(smith, arena, before, partial);
    const ix = try nav.Index.build(arena, proj, encoding, 0);
    const items = try complete(&ix, arena, ask.path, ask.index, ask.cursor);
    const shown = .{ ask.line, ask.cursor, items.len };
    errdefer std.debug.print("completing '{s}' at byte {d}: {d} items\n", shown);
    const reference_line = std.mem.endsWith(u8, ask.path, ".spec.md") or
        !std.mem.startsWith(u8, ask.line, "x = ");
    const want: Expected = if (reference_line) expected(&ix, partial) else .nothing;
    switch (want) {
        .nothing => try testing.expectEqual(@as(usize, 0), items.len),
        .paths => try testing.expectEqual(ix.analysis.specs.len, items.len),
        .headings => |file| try testing.expectEqual(file.sections.len, items.len),
    }
    const cursor_column = text.column(ask.line, ask.cursor, encoding);
    for (items) |item| {
        try testing.expectEqual(ask.index, item.range.start.line);
        try testing.expectEqual(ask.index, item.range.end.line);
        try testing.expectEqual(cursor_column, item.range.end.character);
        const made = try applied(arena, ask.line, item, encoding);
        switch (want) {
            .nothing => unreachable,
            .paths => {
                try testing.expect(ix.analysis.file(item.insert) != null);
                const at = text.byteOffset(ask.line, item.range.start.character, encoding);
                try testing.expectEqual(ask.form_start, at);
            },
            .headings => |file| {
                const form = formOn(made, ask) orelse return error.TestUnexpectedResult;
                try testing.expect(namesExactly(file, form));
            },
        }
    }
}

// specrail: specs/lsp.spec.md § 1.4 Position encoding
// specrail: specs/lsp.spec.md § 2.4 Completion
test "fuzz: completing a reference or dependency names a section exactly" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const corpus = try fuzzing.seeds(arena_state.allocator(), &.{});
    try testing.fuzz({}, completeAForm, .{ .corpus = corpus });
}

/// Completion anywhere in any file offers only edits that replace text on
/// the cursor's line, up to the cursor.
fn completeAnywhere(_: void, smith: *testing.Smith) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const proj = try fuzzed.madeUp(smith, arena);
    const encoding: text.Encoding = if (smith.value(bool)) .utf16 else .utf8;
    const ix = try nav.Index.build(arena, proj, encoding, 0);
    const paths = fuzzing.spec_paths ++ [_][]const u8{ "src/t.zig", "src/none.zig" };
    const path = fuzzing.pick(smith, &paths);
    const index = smith.valueRangeAtMost(u32, 0, 40);
    const byte: usize = smith.valueRangeAtMost(u8, 0, 120);
    const items = try complete(&ix, arena, path, index, byte);
    const line = text.lineAt(ix.contents.get(path) orelse "", index);
    const cursor_column = text.column(line, @min(byte, line.len), encoding);
    for (items) |item| {
        try testing.expectEqual(index, item.range.start.line);
        try testing.expectEqual(index, item.range.end.line);
        try testing.expect(item.range.start.character <= item.range.end.character);
        try testing.expectEqual(cursor_column, item.range.end.character);
    }
}

// specrail: specs/lsp.spec.md § 2.4 Completion
test "fuzz: completion anywhere edits only up to the cursor" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const corpus = try fuzzing.seeds(arena_state.allocator(), &.{});
    try testing.fuzz({}, completeAnywhere, .{ .corpus = corpus });
}
