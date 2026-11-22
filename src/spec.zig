//! Spec files: context, the `---` separator, numbered sections, metadata
//! blocks, and the checks that need only one file.

const std = @import("std");
const Allocator = std.mem.Allocator;

const date = @import("date.zig");
const diag = @import("diag.zig");
const refs = @import("refs.zig");
const toml = @import("toml.zig");

/// Where a section is in its lifecycle. A section with no status is done.
pub const Status = enum {
    done,
    in_progress,
    planned,

    /// The status as written in metadata blocks.
    pub fn name(s: Status) []const u8 {
        return switch (s) {
            .done => "done",
            .in_progress => "in-progress",
            .planned => "planned",
        };
    }

    /// Reads a status as written in metadata blocks; null for anything else.
    pub fn parse(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "planned")) return .planned;
        if (std.mem.eql(u8, s, "in-progress")) return .in_progress;
        if (std.mem.eql(u8, s, "done")) return .done;
        return null;
    }
};

/// One entry of a section's `dependencies`.
pub const Dependency = struct {
    form: refs.Form,
    line: u32,
    column: u32,
};

/// The contents of a section's metadata block.
pub const Metadata = struct {
    /// Line of the opening fence.
    line: u32,
    /// Line of the closing fence; 0 when the block is never closed.
    close_line: u32 = 0,
    status: ?Status = null,
    due: ?date.Date = null,
    assigned: ?[]const u8 = null,
    assigned_until: ?toml.DateTime = null,
    dependencies: []const Dependency = &.{},
};

/// A numbered section of a spec file.
pub const Section = struct {
    number: []const u8,
    title: []const u8,
    level: u8,
    /// 1-based line of the heading.
    line: u32,
    parent: ?usize = null,
    is_leaf: bool = true,
    metadata: ?Metadata = null,
    /// Own prose holds at least one requirement keyword.
    has_keyword: bool = false,
    effective: Status = .done,
    /// Number of references naming this section; filled in by `check`.
    references: u32 = 0,
    /// 0-based index of the line after the section's own text: its heading,
    /// metadata block and own prose.
    own_end: u32 = 0,
    /// 0-based index of the line after the section and all its descendants.
    subtree_end: u32 = 0,
};

/// A parsed spec file.
pub const SpecFile = struct {
    path: []const u8,
    sections: []Section,
    /// The file's lines, without line endings.
    lines: []const []const u8,
    /// The lines of the file's context.
    context: Range,
    /// 0-based index of the `---` separator, if the file has one.
    separator: ?usize,
    /// The file has a problem that keeps `specrail fmt` from rewriting it
    /// safely: its section tree cannot be built, or a metadata block cannot
    /// be read, or holds comments that rewriting would lose.
    broken: bool,
    /// Two sections share a number and a title.
    duplicate: bool,
    /// The 0-based index of the opening line of a fenced code block that is
    /// never closed, and so runs to the end of the file.
    open_fence: ?usize = null,

    /// Whether `specrail mv`, `specrail swap` and the language server's
    /// rename may rewrite the file. Not when it is broken or has a duplicate
    /// heading, nor when it ends inside an unclosed code block: a section
    /// moved out of it would carry the block along, and one moved in after
    /// it would be buried in it.
    pub fn rewritable(file: *const SpecFile) bool {
        return !file.broken and !file.duplicate and file.open_fence == null;
    }

    /// Whether a section other than the one at `index` has `number` and
    /// `title`, which retitling that one to `title` would duplicate.
    pub fn titleTaken(
        file: *const SpecFile,
        index: usize,
        number: []const u8,
        title: []const u8,
    ) bool {
        for (file.sections, 0..) |s, i| {
            if (i == index or !std.mem.eql(u8, s.number, number)) continue;
            if (std.mem.eql(u8, s.title, title)) return true;
        }
        return false;
    }
};

/// Numbers sections by position. Each call to `next` takes the heading level
/// of the next section in the file and returns the number its position
/// implies.
pub const Numbering = struct {
    counters: [7]u32 = @splat(0),

    /// The number of the next section, which has heading level `level`.
    pub fn next(n: *Numbering, arena: Allocator, level: u8) Allocator.Error![]const u8 {
        n.counters[level] += 1;
        for (level + 1..7) |d| n.counters[d] = 0;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(arena);
        for (n.counters[1 .. level + 1], 0..) |c, k| {
            if (k > 0) try buf.append(arena, '.');
            try buf.print(arena, "{d}", .{c});
        }
        return buf.toOwnedSlice(arena);
    }
};

/// Parses a spec file and reports into `out` every problem that can be found
/// in that file alone.
pub fn parse(
    arena: Allocator,
    path: []const u8,
    content: []const u8,
    out: *diag.List,
) Allocator.Error!SpecFile {
    var p: Parser = .{
        .arena = arena,
        .path = path,
        .out = out,
        .lines = try splitLines(arena, content),
    };
    return p.run();
}

// ---------------------------------------------------------------- lines

const LineKind = enum { blank, fence, heading, in_fence, text };

const Line = struct {
    text: []const u8,
    kind: LineKind,
    level: u8 = 0,
    /// Heading text after the `#` characters, trimmed.
    heading: []const u8 = "",
    fence_open: bool = false,
    fence_info: []const u8 = "",
};

const Fence = struct {
    char: u8,
    len: usize,
    info: []const u8,
};

fn leadingSpaces(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len and text[i] == ' ') i += 1;
    return i;
}

fn openFence(text: []const u8) ?Fence {
    const i = leadingSpaces(text);
    if (i > 3 or i >= text.len) return null;
    const c = text[i];
    if (c != '`' and c != '~') return null;
    var n: usize = 0;
    while (i + n < text.len and text[i + n] == c) n += 1;
    if (n < 3) return null;
    const info = std.mem.trim(u8, text[i + n ..], " \t");
    if (c == '`' and std.mem.findScalar(u8, info, '`') != null) return null;
    return .{ .char = c, .len = n, .info = info };
}

/// Whether the first non-blank line of `rest`, the lines after a metadata
/// block with their endings, opens a `toml` fenced block. Removing the
/// metadata block would make that block the section's metadata block.
pub fn tomlBlockFollows(rest: []const []const u8) bool {
    for (rest) |raw| {
        const text = std.mem.trimEnd(u8, raw, "\r\n");
        if (std.mem.trim(u8, text, " \t").len == 0) continue;
        const f = openFence(text) orelse return false;
        return std.mem.eql(u8, f.info, "toml");
    }
    return false;
}

fn closesFence(text: []const u8, f: Fence) bool {
    const i = leadingSpaces(text);
    if (i > 3) return false;
    var n: usize = 0;
    while (i + n < text.len and text[i + n] == f.char) n += 1;
    if (n < f.len) return false;
    return std.mem.trim(u8, text[i + n ..], " \t").len == 0;
}

fn headingLevel(text: []const u8) ?u8 {
    var n: usize = 0;
    while (n < text.len and text[n] == '#') n += 1;
    if (n == 0 or n > 6 or n >= text.len or text[n] != ' ') return null;
    return @intCast(n);
}

fn splitLines(arena: Allocator, content: []const u8) Allocator.Error![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(arena);
    var it = std.mem.splitScalar(u8, content, '\n');
    var fence: ?Fence = null;
    while (it.next()) |raw| {
        if (it.index == null and raw.len == 0) break;
        const text = std.mem.trimEnd(u8, raw, "\r");
        var line: Line = .{ .text = text, .kind = .text };
        if (fence) |f| {
            if (closesFence(text, f)) {
                line.kind = .fence;
                fence = null;
            } else line.kind = .in_fence;
        } else if (openFence(text)) |f| {
            line.kind = .fence;
            line.fence_open = true;
            line.fence_info = f.info;
            fence = f;
        } else if (isBlank(text)) {
            line.kind = .blank;
        } else if (headingLevel(text)) |lvl| {
            line.kind = .heading;
            line.level = lvl;
            line.heading = std.mem.trim(u8, text[lvl + 1 ..], " \t");
        }
        try lines.append(arena, line);
    }
    return lines.toOwnedSlice(arena);
}

/// Whether `text`, a line as `SpecFile.lines` holds it, is blank outside a
/// fenced code block.
pub fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t").len == 0;
}

/// Whether `text`, a line as `SpecFile.lines` holds it, is a `---` line.
pub fn isSeparator(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "---") and std.mem.trim(u8, text[3..], " \t").len == 0;
}

/// The separator: the first `---` line outside fenced code blocks that follows
/// a blank line.
fn findSeparator(lines: []const Line) ?usize {
    for (lines, 0..) |l, i| {
        if (i > 0 and l.kind == .text and isSeparator(l.text) and lines[i - 1].kind == .blank) {
            return i;
        }
    }
    return null;
}

fn hasSectionHeading(lines: []const Line) bool {
    for (lines) |l| {
        if (l.kind == .heading and refs.startsWithSign(l.heading)) return true;
    }
    return false;
}

fn isSetextUnderline(text: []const u8) bool {
    const i = leadingSpaces(text);
    if (i > 3) return false;
    const t = std.mem.trimEnd(u8, text[i..], " \t");
    if (t.len == 0 or (t[0] != '=' and t[0] != '-')) return false;
    for (t) |c| if (c != t[0]) return false;
    return true;
}

fn isThematicBreak(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0 or (t[0] != '-' and t[0] != '*' and t[0] != '_')) return false;
    var n: usize = 0;
    for (t) |c| {
        if (c == t[0]) n += 1 else if (c != ' ' and c != '\t') return false;
    }
    return n >= 3;
}

fn isListItem(text: []const u8) bool {
    const t = text[leadingSpaces(text)..];
    if (t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and (t[1] == ' ' or
        t[1] == '\t')) return true;
    var i: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    return i > 0 and i + 1 < t.len and (t[i] == '.' or t[i] == ')') and (t[i + 1] == ' ' or
        t[i + 1] == '\t');
}

/// Approximates CommonMark's "line of a paragraph", which a setext underline
/// turns into a heading.
fn isParagraphLine(line: Line) bool {
    if (line.kind != .text) return false;
    const t = line.text;
    if (leadingSpaces(t) >= 4) return false;
    const s = std.mem.trimStart(u8, t, " ");
    if (s.len > 0 and (s[0] == '>' or s[0] == '<' or s[0] == '|')) return false;
    return !isListItem(t) and !isThematicBreak(t) and !isSetextUnderline(t);
}

// ---------------------------------------------------------------- keywords

/// The RFC 2119 requirement keywords specrail recognizes. Each negated form,
/// such as `MUST NOT`, contains one of them.
pub const keywords = [_][]const u8{
    "MUST",
    "REQUIRED",
    "SHALL",
    "SHOULD",
    "RECOMMENDED",
    "MAY",
    "OPTIONAL",
};

const Hit = struct {
    line: usize,
    column: u32,
    word: []const u8,
};

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Blanks out inline code spans, keeping newlines and byte offsets.
fn maskCodeSpans(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        if (buf[i] != '`') {
            i += 1;
            continue;
        }
        var run: usize = 0;
        while (i + run < buf.len and buf[i + run] == '`') run += 1;
        var j = i + run;
        const close: ?usize = scan: while (j < buf.len) {
            if (buf[j] != '`') {
                j += 1;
                continue :scan;
            }
            var r: usize = 0;
            while (j + r < buf.len and buf[j + r] == '`') r += 1;
            if (r == run) break :scan j;
            j += r;
        } else null;
        if (close) |c| {
            for (buf[i .. c + run]) |*b| {
                if (b.* != '\n') b.* = ' ';
            }
            i = c + run;
        } else i += run;
    }
}

fn scanWords(
    arena: Allocator,
    text: []const u8,
    line: usize,
    hits: *std.ArrayList(Hit),
) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (!std.ascii.isUpper(text[i]) or (i > 0 and isWordChar(text[i - 1]))) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < text.len and std.ascii.isUpper(text[j])) j += 1;
        if (j >= text.len or !isWordChar(text[j])) {
            for (keywords) |k| {
                if (std.mem.eql(u8, k, text[i..j])) {
                    try hits.append(arena, .{ .line = line, .column = @intCast(i + 1), .word = k });
                    break;
                }
            }
        }
        i = j;
    }
}

// ---------------------------------------------------------------- parser

/// A run of lines, as 0-based indices; `end` is not included.
pub const Range = struct { start: usize, end: usize };

const Parser = struct {
    arena: Allocator,
    path: []const u8,
    out: *diag.List,
    lines: []Line,
    sections: std.ArrayList(Section) = .empty,
    /// Own prose of each section, as a range of line indices.
    prose: std.ArrayList(Range) = .empty,
    broken: bool = false,
    duplicate: bool = false,

    fn report(
        p: *Parser,
        severity: diag.Severity,
        at: diag.Position,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        try p.out.append(p.arena, .{
            .path = p.path,
            .line = at.line,
            .column = at.column,
            .severity = severity,
            .message = try p.arena.print(fmt, args),
        });
    }

    /// Reports an error at a 0-based line index.
    fn err(
        p: *Parser,
        index: usize,
        column: u32,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        try p.report(.err, .{ .line = @intCast(index + 1), .column = column }, fmt, args);
    }

    fn findKeywords(p: *Parser, lines: Range) Allocator.Error![]const Hit {
        const start = lines.start;
        const end = lines.end;
        var hits: std.ArrayList(Hit) = .empty;
        errdefer hits.deinit(p.arena);
        var i = start;
        while (i < end) {
            if (p.lines[i].kind != .text) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < end and p.lines[j].kind == .text) j += 1;
            // Masked text; hits do not point into it.
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(p.arena);
            for (p.lines[i..j], 0..) |l, k| {
                if (k > 0) try buf.append(p.arena, '\n');
                try buf.appendSlice(p.arena, l.text);
            }
            maskCodeSpans(buf.items);
            var it = std.mem.splitScalar(u8, buf.items, '\n');
            var line = i;
            while (it.next()) |text| : (line += 1) try scanWords(p.arena, text, line, &hits);
            i = j;
        }
        return hits.toOwnedSlice(p.arena);
    }

    fn run(p: *Parser) Allocator.Error!SpecFile {
        const n = p.lines.len;
        const sep = findSeparator(p.lines);
        const ctx_end: usize, const sec_start: usize = if (sep) |s|
            .{ s, s + 1 }
        else if (hasSectionHeading(p.lines))
            .{ 0, 0 }
        else
            .{ n, n };
        try p.checkLayout(sep);
        try p.checkContext(ctx_end);
        try p.readSections(sec_start);
        try p.buildTree();
        try p.checkProse();
        const open_fence = try p.checkFences();
        p.markExtents();
        const texts = try p.arena.alloc([]const u8, n);
        for (p.lines, 0..) |l, i| texts[i] = l.text;
        return .{
            .path = p.path,
            .sections = p.sections.items,
            .lines = texts,
            .context = .{ .start = 0, .end = ctx_end },
            .separator = sep,
            .broken = p.broken,
            .duplicate = p.duplicate,
            .open_fence = open_fence,
        };
    }

    /// Reports a fenced code block that is never closed, and returns the
    /// index of its opening line.
    fn checkFences(p: *Parser) Allocator.Error!?usize {
        var open: ?usize = null;
        for (p.lines, 0..) |l, i| {
            if (l.kind != .fence) continue;
            open = if (l.fence_open) i else null;
        }
        const at = open orelse return null;
        const msg = "this code block is never closed, so everything after it, sections " ++
            "included, is code; close it with a line of the same backticks or tildes";
        try p.err(at, 1, msg, .{});
        return at;
    }

    /// Records where each section's own text ends, and where its subtree does.
    fn markExtents(p: *Parser) void {
        const secs = p.sections.items;
        for (secs, 0..) |*s, idx| {
            s.own_end = @intCast(p.prose.items[idx].end);
            s.subtree_end = @intCast(p.lines.len);
            for (secs[idx + 1 ..]) |later| {
                if (later.level <= s.level) {
                    s.subtree_end = later.line - 1;
                    break;
                }
            }
        }
    }

    /// Reports a separator with nothing before it, and setext underlines anywhere.
    fn checkLayout(p: *Parser, sep: ?usize) Allocator.Error!void {
        const lines = p.lines;
        if (sep) |s| {
            const empty = for (lines[0..s]) |l| {
                if (l.kind != .blank) break false;
            } else true;
            if (empty) try p.err(s, 1, "separator with no context before it; remove it", .{});
        }
        for (lines, 0..) |l, i| {
            if (i == 0 or l.kind != .text or (sep != null and sep.? == i)) continue;
            if (isSetextUnderline(l.text) and isParagraphLine(lines[i - 1])) {
                try p.err(
                    i,
                    1,
                    "this underline makes the line above a heading that specrail does not " ++
                        "recognize; use a '#' heading",
                    .{},
                );
            }
        }
    }

    /// Reports section headings and requirement keywords in the context, which is
    /// the lines before `ctx_end`.
    fn checkContext(p: *Parser, ctx_end: usize) Allocator.Error!void {
        for (p.lines[0..ctx_end], 0..) |l, i| {
            if (l.kind == .heading and refs.startsWithSign(l.heading)) {
                try p.err(
                    i,
                    1,
                    "section heading in the context; move it below the '---' separator",
                    .{},
                );
            }
        }
        for (try p.findKeywords(.{ .start = 0, .end = ctx_end })) |h| {
            try p.err(
                h.line,
                h.column,
                "requirement keyword '{s}' in context; requirements belong in leaf sections",
                .{h.word},
            );
        }
    }

    /// Reports requirement keywords in the prose of parent sections, and leaves
    /// whose prose states no requirement.
    fn checkProse(p: *Parser) Allocator.Error!void {
        for (p.sections.items, 0..) |*s, idx| {
            const hits = try p.findKeywords(p.prose.items[idx]);
            if (!s.is_leaf) {
                for (hits) |h| {
                    try p.err(
                        h.line,
                        h.column,
                        "requirement keyword '{s}' in the prose of parent section § {s}; " ++
                            "requirements belong in leaf sections",
                        .{ h.word, s.number },
                    );
                }
                continue;
            }
            s.has_keyword = hits.len > 0;
            if (s.has_keyword) continue;
            const severity: diag.Severity = if (s.effective == .done) .err else .warning;
            try p.report(
                severity,
                .{ .line = s.line, .column = 1 },
                "leaf § {s} {s} states no requirement; state it with a requirement keyword " ++
                    "(MUST, SHOULD, MAY, ...) or move the text into context",
                .{ s.number, s.title },
            );
        }
    }

    fn readSections(p: *Parser, start: usize) Allocator.Error!void {
        const lines = p.lines;
        const n = lines.len;
        var cur: ?usize = null;
        var seen_heading = false;
        var preamble_reported = false;
        var i = start;
        while (i < n) : (i += 1) {
            const l = lines[i];
            if (l.kind != .heading) {
                if (!seen_heading and l.kind != .blank and !preamble_reported) {
                    preamble_reported = true;
                    try p.err(
                        i,
                        1,
                        "content before the first section heading; a '---' separator is missing " ++
                            "or misplaced",
                        .{},
                    );
                }
                continue;
            }
            seen_heading = true;
            if (cur) |c| p.prose.items[c].end = i;
            cur = null;
            const a = switch (refs.parseAddress(l.heading, .required)) {
                .ok => |a| a,
                .err => |msg| {
                    p.broken = true;
                    try p.err(
                        i,
                        1,
                        "not a section heading: {s}; section headings look like '# § 1 Title'",
                        .{msg},
                    );
                    continue;
                },
            };
            try p.sections.append(
                p.arena,
                .{
                    .number = a.number,
                    .title = a.title,
                    .level = l.level,
                    .line = @intCast(i + 1),
                },
            );
            var prose_start = i + 1;
            var j = i + 1;
            while (j < n and lines[j].kind == .blank) j += 1;
            const metadata_block = j < n and lines[j].kind == .fence and lines[j].fence_open and
                std.mem.eql(u8, lines[j].fence_info, "toml");
            if (metadata_block) {
                var k = j + 1;
                while (k < n and lines[k].kind == .in_fence) k += 1;
                p.sections.items[p.sections.items.len - 1].metadata = try p.readMetadata(
                    .{ .start = j, .end = k },
                );
                prose_start = @min(k + 1, n);
                i = prose_start - 1;
            }
            try p.prose.append(p.arena, .{ .start = prose_start, .end = n });
            cur = p.sections.items.len - 1;
        }
    }

    fn buildTree(p: *Parser) Allocator.Error!void {
        const secs = p.sections.items;
        var stack: [7]?usize = @splat(null);
        var counters: [7]u32 = @splat(0);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(p.arena);
        for (secs, 0..) |*s, idx| {
            try p.checkLevel(idx);
            var lvl: usize = s.level - 1;
            while (lvl > 0) : (lvl -= 1) {
                if (stack[lvl]) |parent| {
                    s.parent = parent;
                    secs[parent].is_leaf = false;
                    break;
                }
            }
            stack[s.level] = idx;
            for (s.level + 1..7) |d| stack[d] = null;
            counters[s.level] += 1;
            for (s.level + 1..7) |d| counters[d] = 0;
            try p.checkNumber(s.*, counters);
            const key = try p.arena.print("{s}\x00{s}", .{ s.number, s.title });
            const gop = try seen.getOrPut(p.arena, key);
            if (gop.found_existing) {
                p.duplicate = true;
                try p.err(
                    s.line - 1,
                    1,
                    "duplicate section § {s} {s}; references cannot tell the two apart",
                    .{ s.number, s.title },
                );
            }
        }
        for (secs) |*s| {
            const inherited: Status = if (s.parent) |parent| secs[parent].effective else .done;
            s.effective = if (s.metadata) |m| m.status orelse inherited else inherited;
        }
    }

    /// Reports a first section heading that is not level 1, and a heading more
    /// than one level deeper than the one before it.
    fn checkLevel(p: *Parser, idx: usize) Allocator.Error!void {
        const s = p.sections.items[idx];
        if (idx == 0 and s.level != 1) {
            p.broken = true;
            try p.err(
                s.line - 1,
                1,
                "the first section heading is level {d}; it must be level 1 ('#')",
                .{s.level},
            );
        }
        if (idx == 0) return;
        const prev = p.sections.items[idx - 1].level;
        if (s.level > prev + 1) {
            p.broken = true;
            try p.err(
                s.line - 1,
                1,
                "heading jumps from level {d} to level {d}; levels go down one at a time",
                .{ prev, s.level },
            );
        }
    }

    /// Reports a section number that its position contradicts, given the counters
    /// for each level so far, and a heading level that does not match its depth.
    fn checkNumber(p: *Parser, s: Section, counters: [7]u32) Allocator.Error!void {
        const gap = for (1..s.level) |d| {
            if (counters[d] == 0) break true;
        } else false;
        if (!gap) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(p.arena);
            for (counters[1 .. s.level + 1], 0..) |c, k| {
                if (k > 0) try buf.append(p.arena, '.');
                try buf.print(p.arena, "{d}", .{c});
            }
            if (!std.mem.eql(u8, buf.items, s.number)) {
                try p.err(
                    s.line - 1,
                    1,
                    "§ {s} is out of order; by its position it is § {s}",
                    .{ s.number, buf.items },
                );
            }
        }
        if (refs.depth(s.number) != s.level) {
            try p.err(
                s.line - 1,
                1,
                "heading level {d} does not match § {s}, which has {d} components",
                .{ s.level, s.number, refs.depth(s.number) },
            );
        }
    }

    /// Reads the metadata block whose fences are the lines `fences.start` and
    /// `fences.end`.
    fn readMetadata(p: *Parser, fences: Range) Allocator.Error!Metadata {
        var m: Metadata = .{ .line = @intCast(fences.start + 1) };
        if (fences.end < p.lines.len) {
            m.close_line = @intCast(fences.end + 1);
        } else p.broken = true;
        // The parsed document borrows keys and strings from this text, and the
        // metadata borrows from the document, so it is freed only on error.
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(p.arena);
        for (p.lines[fences.start + 1 .. fences.end], 0..) |l, k| {
            if (k > 0) try buf.append(p.arena, '\n');
            try buf.appendSlice(p.arena, l.text);
        }
        // TOML line 1 is the line after the opening fence.
        const base: u32 = @intCast(fences.start + 1);
        const doc = switch (try toml.parse(p.arena, buf.items)) {
            .ok => |doc| doc,
            .err => |e| {
                p.broken = true;
                const at: diag.Position = .{ .line = base + e.line, .column = e.column };
                try p.report(.err, at, "invalid metadata: {s}", .{e.message});
                return m;
            },
        };
        if (doc.comment_lines.len > 0) p.broken = true;
        for (doc.comment_lines) |cl| {
            try p.report(
                .err,
                .{ .line = base + cl, .column = 1 },
                "comments are not allowed in metadata blocks, because 'specrail fmt' reorders " ++
                    "keys; use an x- key instead",
                .{},
            );
        }
        var deps: std.ArrayList(Dependency) = .empty;
        errdefer deps.deinit(p.arena);
        for (doc.entries) |e| try p.readEntry(&m, &deps, base, e);
        if (m.assigned_until != null and m.assigned == null) {
            try p.report(
                .err,
                .{ .line = base + doc.get("assigned-until").?.line, .column = 1 },
                "'assigned-until' needs an 'assigned' key naming who holds the claim",
                .{},
            );
        }
        m.dependencies = try deps.toOwnedSlice(p.arena);
        return m;
    }

    /// Reads one metadata key into `m`, and dependency entries into `deps`.
    /// `base` turns the document's line numbers into the file's.
    fn readEntry(
        p: *Parser,
        m: *Metadata,
        deps: *std.ArrayList(Dependency),
        base: u32,
        e: toml.Entry,
    ) Allocator.Error!void {
        const line = base + e.line;
        if (std.mem.eql(u8, e.key, "status")) {
            if (e.value != .string) return p.wrongType(line, e, "a string");
            m.status = Status.parse(e.value.string) orelse return p.report(
                .err,
                .{ .line = line, .column = e.column },
                "'{s}' is not a status; use planned, in-progress or done",
                .{e.value.string},
            );
        } else if (std.mem.eql(u8, e.key, "due")) {
            if (e.value != .date) return p.wrongType(line, e, "a local date such as 2027-06-29");
            m.due = e.value.date;
        } else if (std.mem.eql(u8, e.key, "assigned")) {
            if (e.value != .string) return p.wrongType(line, e, "a string");
            m.assigned = e.value.string;
        } else if (std.mem.eql(u8, e.key, "assigned-until")) {
            if (e.value != .datetime) {
                return p.wrongType(line, e, "an offset date-time such as 2026-11-17T16:00:00Z");
            }
            m.assigned_until = e.value.datetime;
        } else if (std.mem.eql(u8, e.key, "dependencies")) {
            if (e.value != .array) return p.wrongType(line, e, "an array of strings");
            try p.readDependencies(deps, base, e.value.array);
        } else if (!std.mem.startsWith(u8, e.key, "x-")) {
            try p.report(
                .err,
                .{ .line = line, .column = e.column },
                "unknown metadata key '{s}'; the keys are status, due, assigned, " ++
                    "assigned-until and dependencies, and extension keys start with 'x-'",
                .{e.key},
            );
        }
    }

    /// Reads dependency entries, each a string in reference form.
    fn readDependencies(
        p: *Parser,
        deps: *std.ArrayList(Dependency),
        base: u32,
        items: []const toml.Item,
    ) Allocator.Error!void {
        for (items) |item| {
            const at: diag.Position = .{ .line = base + item.line, .column = item.column };
            if (item.value != .string) {
                try p.report(
                    .err,
                    at,
                    "dependency entries must be strings, not {s}",
                    .{item.value.kind()},
                );
                continue;
            }
            switch (refs.parseForm(item.value.string, .required)) {
                .ok => |f| try deps.append(
                    p.arena,
                    .{ .form = f, .line = at.line, .column = at.column },
                ),
                .err => |msg| try p.report(.err, at, "invalid dependency entry: {s}", .{msg}),
            }
        }
    }

    fn wrongType(p: *Parser, line: u32, e: toml.Entry, expected: []const u8) Allocator.Error!void {
        try p.report(
            .err,
            .{ .line = line, .column = e.column },
            "'{s}' must be {s}, not {s}",
            .{ e.key, expected, e.value.kind() },
        );
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    file: SpecFile,
    diags: diag.List,

    fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }

    fn expect(self: *const Parsed, line: u32, severity: diag.Severity, needle: []const u8) !void {
        for (self.diags.items) |d| {
            const found = std.mem.find(u8, d.message, needle) != null;
            if (d.line == line and d.severity == severity and found) return;
        }
        std.debug.print(
            "no {s} containing '{s}' on line {d}; got:\n",
            .{ severity.name(), needle, line },
        );
        for (self.diags.items) |d| std.debug.print(
            "  {d}:{d}: {s}: {s}\n",
            .{ d.line, d.column, d.severity.name(), d.message },
        );
        return error.TestUnexpectedResult;
    }

    fn expectClean(self: *const Parsed) !void {
        if (self.diags.items.len == 0) return;
        for (self.diags.items) |d| std.debug.print(
            "  {d}:{d}: {s}: {s}\n",
            .{ d.line, d.column, d.severity.name(), d.message },
        );
        return error.TestUnexpectedResult;
    }

    fn count(self: *const Parsed) usize {
        return self.diags.items.len;
    }
};

fn parseTest(content: []const u8) !Parsed {
    var r: Parsed = .{ .arena = .init(testing.allocator), .file = undefined, .diags = .empty };
    r.file = try parse(r.arena.allocator(), "specs/t.spec.md", content, &r.diags);
    return r;
}

// specrail: specs/format/spec-files.spec.md § 2.1 Separator
// specrail: specs/format/spec-files.spec.md § 2.5 Later thematic breaks
test "the first --- after a blank line separates context from sections" {
    var r = try parseTest(
        \\Context that explains.
        \\
        \\## Context may have headings
        \\
        \\---
        \\
        \\# § 1 First
        \\
        \\The tool MUST work.
        \\
        \\---
        \\
        \\More prose for § 1, after a thematic break.
        \\
    );
    defer r.deinit();
    try r.expectClean();
    try testing.expectEqual(@as(usize, 1), r.file.sections.len);
    try testing.expectEqualStrings("First", r.file.sections[0].title);
}

// specrail: specs/format/spec-files.spec.md § 2.2 Files without a separator
test "a file without a separator is all context or all sections" {
    var context_only = try parseTest("# Title\n\nJust context, with a heading.\n");
    defer context_only.deinit();
    try context_only.expectClean();
    try testing.expectEqual(@as(usize, 0), context_only.file.sections.len);

    var sections_only = try parseTest("# § 1 One\n\nIt MUST work.\n");
    defer sections_only.deinit();
    try sections_only.expectClean();
    try testing.expectEqual(@as(usize, 1), sections_only.file.sections.len);
}

// specrail: specs/format/spec-files.spec.md § 2.3 Content before the first section
test "content before the first section heading is an error" {
    var missing = try parseTest("Some intro.\n# § 1 One\n\nIt MUST work.\n");
    defer missing.deinit();
    try missing.expect(1, .err, "separator is missing or misplaced");

    var misplaced = try parseTest("Intro.\n\n---\n\nMore intro.\n\n# § 1 One\n\nIt MUST work.\n");
    defer misplaced.deinit();
    try misplaced.expect(5, .err, "separator is missing or misplaced");
}

// specrail: specs/format/spec-files.spec.md § 2.4 Empty context
test "a separator with nothing before it is an error" {
    var r = try parseTest("\n---\n\n# § 1 One\n\nIt MUST work.\n");
    defer r.deinit();
    try r.expect(2, .err, "no context before it");
}

// specrail: specs/format/spec-files.spec.md § 2.6 Section headings in context
test "a section heading on the context side of the separator is an error" {
    var r = try parseTest(
        "# § 1 Wrong side\n\n## % 2 Also wrong\n\n## 50% of users\n\n---\n\n# § 1 Right\n\nIt " ++
            "MUST work.\n",
    );
    defer r.deinit();
    try r.expect(1, .err, "section heading in the context");
    try r.expect(3, .err, "section heading in the context");
    try testing.expectEqual(@as(usize, 2), r.count());
}

// specrail: specs/format/spec-files.spec.md § 3.1 Fenced code blocks
// specrail: specs/format/spec-files.spec.md § 3.8 Unclosed code blocks
test "a code block that is never closed is an error, and takes the rest of the file" {
    var r = try parseTest(
        \\# § 1 One
        \\
        \\```zig
        \\# § 2 Swallowed
        \\
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try r.expect(3, .err, "this code block is never closed");
    try testing.expectEqual(@as(usize, 1), r.file.sections.len);
    try testing.expectEqual(@as(?usize, 2), r.file.open_fence);
    var closed = try parseTest("# § 1 One\n\n```zig\ncode\n```\nIt MUST work.\n");
    defer closed.deinit();
    try testing.expectEqual(@as(?usize, null), closed.file.open_fence);
}

test "headings, separators, metadata and keywords inside fences are ignored" {
    var r = try parseTest(
        \\Context.
        \\
        \\````markdown
        \\# § 9 Not a section
        \\
        \\---
        \\
        \\It MUST be ignored.
        \\```toml
        \\status = 1
        \\```
        \\````
        \\
        \\---
        \\
        \\# § 1 One
        \\
        \\~~~
        \\## § 1.1 Also not a section
        \\~~~
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try r.expectClean();
    try testing.expectEqual(@as(usize, 1), r.file.sections.len);
}

// specrail: specs/format/spec-files.spec.md § 3.2 Heading lines
// specrail: specs/format/spec-files.spec.md § 3.4 Section heading syntax
test "every heading among the sections must be a section heading" {
    var r = try parseTest(
        \\# § 1 One
        \\
        \\It MUST work.
        \\
        \\## Not numbered
        \\
        \\#### § 1.0 Bad number
        \\
        \\####### seven hashes is text, and so is
        \\#no-space
        \\
    );
    defer r.deinit();
    try r.expect(5, .err, "not a section heading");
    try r.expect(7, .err, "not a section heading");
    try testing.expectEqual(@as(usize, 2), r.count());
}

// specrail: specs/format/spec-files.spec.md § 3.3 Setext headings
test "setext heading underlines are errors" {
    var r = try parseTest(
        \\Context line
        \\===
        \\
        \\- a list item
        \\---
        \\
        \\***
        \\---
        \\
        \\Another paragraph
        \\---
        \\
        \\---
        \\
        \\# § 1 One
        \\
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try r.expect(2, .err, "underline");
    try r.expect(11, .err, "underline");
    try testing.expectEqual(@as(usize, 2), r.count());
}

// specrail: specs/format/spec-files.spec.md § 3.5 Heading level equals depth
test "the heading level must equal the number of components" {
    var r = try parseTest("# § 1 One\n\nIt MUST work.\n\n## § 1.1.1 Deep\n\nIt MUST work.\n");
    defer r.deinit();
    try r.expect(5, .err, "does not match § 1.1.1");
}

// specrail: specs/format/spec-files.spec.md § 3.6 Section tree
test "the tree follows heading levels" {
    var r = try parseTest(
        \\# § 1 One
        \\## § 1.1 Child
        \\
        \\It MUST work.
        \\
        \\## § 1.2 Second child
        \\
        \\It MUST work.
        \\
        \\# § 2 Two
        \\
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try r.expectClean();
    const s = r.file.sections;
    try testing.expectEqual(@as(?usize, null), s[0].parent);
    try testing.expectEqual(@as(?usize, 0), s[1].parent);
    try testing.expectEqual(@as(?usize, 0), s[2].parent);
    try testing.expect(!s[0].is_leaf and s[1].is_leaf and s[3].is_leaf);

    var bad = try parseTest(
        "## § 1 Starts deep\n\nIt MUST work.\n\n#### § 1.1.1 Skips\n\nIt MUST work.\n",
    );
    defer bad.deinit();
    try bad.expect(1, .err, "must be level 1");
    try bad.expect(5, .err, "jumps from level 2 to level 4");
}

// specrail: specs/format/spec-files.spec.md § 4.1 Contiguous numbering
test "numbers must follow position" {
    var r = try parseTest(
        \\# § 1 One
        \\## § 1.1 A
        \\
        \\It MUST work.
        \\
        \\## § 1.3 B
        \\
        \\It MUST work.
        \\
        \\# § 3 Two
        \\
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try r.expect(6, .err, "by its position it is § 1.2");
    try r.expect(10, .err, "by its position it is § 2");
    try testing.expectEqual(@as(usize, 2), r.count());
}

// specrail: specs/format/spec-files.spec.md § 4.2 Duplicate headings
test "the same number and title twice is an error" {
    var r = try parseTest("# § 1 One\n\nIt MUST work.\n\n# § 1 One\n\nIt MUST work.\n");
    defer r.deinit();
    try r.expect(5, .err, "duplicate section § 1 One");
}

// specrail: specs/format/spec-files.spec.md § 5.1 Requirements only in leaves
test "requirement keywords in context prose are errors" {
    var r = try parseTest(
        \\The context MUST NOT demand.
        \\
        \\---
        \\
        \\# § 1 Parent
        \\
        \\Parent prose SHOULD NOT demand either.
        \\
        \\## § 1.1 Leaf
        \\
        \\The leaf MUST demand.
        \\
    );
    defer r.deinit();
    try r.expect(1, .err, "'MUST' in context");
    try r.expect(7, .err, "'SHOULD' in the prose of parent section § 1");
    try testing.expectEqual(@as(usize, 2), r.count());
}

// specrail: specs/format/spec-files.spec.md § 5.2 Keyword recognition
test "keywords are uppercase whole words outside code" {
    var r = try parseTest(
        \\Lowercase must and should are plain English, as are MUSTARD,
        \\MAYBE and RECOMMENDED_X. Code like `MUST` or ``a `MAY` b`` is
        \\ignored, and so is this span that crosses `a line
        \\break SHALL`.
        \\
        \\```
        \\REQUIRED inside a fence
        \\```
        \\
        \\## OPTIONAL in a heading
    );
    defer r.deinit();
    try r.expectClean();

    var hit = try parseTest("Context saying OPTIONAL.\n");
    defer hit.deinit();
    try hit.expect(1, .err, "'OPTIONAL' in context");
}

// specrail: specs/format/spec-files.spec.md § 5.3 Leaves state requirements
// specrail: specs/format/spec-files.spec.md § 5.4 Unfinished leaves without requirements
test "leaves without a keyword are errors when done and warnings otherwise" {
    var r = try parseTest(
        \\# § 1 Done
        \\
        \\Just a description.
        \\
        \\# § 2 Planned
        \\```toml
        \\status = "planned"
        \\```
        \\
        \\TBD.
        \\
    );
    defer r.deinit();
    try r.expect(1, .err, "leaf § 1 Done states no requirement");
    try r.expect(5, .warning, "leaf § 2 Planned states no requirement");
}

// specrail: specs/format/spec-files.spec.md § 6.1 Alternate section sign
test "percent stands in for the section sign in headings" {
    var r = try parseTest("# % 1 One\n\nIt MUST work.\n");
    defer r.deinit();
    try r.expectClean();
    try testing.expectEqualStrings("1", r.file.sections[0].number);
}

// specrail: specs/format/metadata.spec.md § 1.1 Recognizing a block
test "only a toml block first after the heading is metadata" {
    var r = try parseTest(
        \\# § 1 One
        \\
        \\```toml
        \\status = "planned"
        \\```
        \\
        \\It MUST work.
        \\
        \\```toml
        \\status = "nonsense, but only an example"
        \\```
        \\
        \\# § 2 Two
        \\```yaml
        \\status: planned
        \\```
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try r.expectClean();
    try testing.expectEqual(Status.planned, r.file.sections[0].metadata.?.status.?);
    try testing.expectEqual(@as(?Metadata, null), r.file.sections[1].metadata);
}

// specrail: specs/format/metadata.spec.md § 2.4 No comments in metadata blocks
test "comments in metadata blocks are errors" {
    var r = try parseTest(
        "# § 1 One\n```toml\n# why\nstatus = \"planned\" # because\n```\nIt MUST work.\n",
    );
    defer r.deinit();
    try r.expect(3, .err, "comments are not allowed");
    try r.expect(4, .err, "comments are not allowed");
}

// specrail: specs/format/metadata.spec.md § 3.1 Known keys
test "known keys must have the right types" {
    var r = try parseTest(
        \\# § 1 One
        \\```toml
        \\status         = "planned"
        \\due            = 2027-06-29
        \\assigned       = "agent-7"
        \\assigned-until = 2026-11-17T16:00:00Z
        \\dependencies   = ["specs/t.spec.md § 2 Two"]
        \\```
        \\It MUST work.
        \\
        \\# § 2 Two
        \\```toml
        \\status         = 1
        \\due            = "tomorrow"
        \\assigned       = true
        \\assigned-until = 2026-11-17
        \\dependencies   = "specs/t.spec.md § 1 One"
        \\```
        \\It MUST work.
        \\
    );
    defer r.deinit();
    const m = r.file.sections[0].metadata.?;
    try testing.expectEqualStrings("agent-7", m.assigned.?);
    try testing.expectEqual(@as(u8, 29), m.due.?.day);
    try testing.expectEqualStrings("2", m.dependencies[0].form.number);
    for (13..18) |line| try r.expect(@intCast(line), .err, "must be");
}

// specrail: specs/format/metadata.spec.md § 3.2 Extension keys
// specrail: specs/format/metadata.spec.md § 3.3 Unknown keys
test "x- keys are accepted and other unknown keys are errors" {
    var r = try parseTest(
        "# § 1 One\n```toml\nx-jira = \"ABC-1\"\nx-n = [1, 2]\nstauts = \"planned\"\n```\nIt " ++
            "MUST work.\n",
    );
    defer r.deinit();
    try r.expect(5, .err, "unknown metadata key 'stauts'");
    try testing.expectEqual(@as(usize, 1), r.count());
}

// specrail: specs/format/metadata.spec.md § 4.1 Status values
test "status must be planned, in-progress or done" {
    var r = try parseTest(
        "# § 1 One\n```toml\nstatus = \"wip\"\n```\nIt MUST work.\n# § 2 Two\n```toml\nstatus = " ++
            "\"in-progress\"\n```\nIt MUST work.\n",
    );
    defer r.deinit();
    try r.expect(3, .err, "'wip' is not a status");
    try testing.expectEqual(Status.in_progress, r.file.sections[1].effective);
}

// specrail: specs/format/metadata.spec.md § 4.2 Effective status
test "status is inherited from the nearest ancestor that sets one" {
    var r = try parseTest(
        \\# § 1 Parent
        \\```toml
        \\status = "planned"
        \\```
        \\## § 1.1 Inherits
        \\
        \\It MUST work.
        \\
        \\## § 1.2 Overrides
        \\```toml
        \\status = "done"
        \\```
        \\It MUST work.
        \\
        \\# § 2 Default
        \\
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try r.expectClean();
    const s = r.file.sections;
    try testing.expectEqual(Status.planned, s[1].effective);
    try testing.expectEqual(Status.done, s[2].effective);
    try testing.expectEqual(Status.done, s[3].effective);
}

// specrail: specs/format/metadata.spec.md § 5.1 Expiry needs an assignee
test "assigned-until without assigned is an error" {
    var r = try parseTest(
        "# § 1 One\n```toml\nassigned-until = 2026-11-17T16:00:00Z\n```\nIt MUST work.\n",
    );
    defer r.deinit();
    try r.expect(3, .err, "needs an 'assigned' key");
}

// specrail: specs/format/metadata.spec.md § 6.1 Entry syntax
test "dependency entries are in reference form" {
    var r = try parseTest(
        \\# § 1 One
        \\```toml
        \\dependencies = [
        \\  "specs/other.spec.md % 2.1 Two",
        \\  "specs/other.spec.md two",
        \\  3,
        \\]
        \\```
        \\It MUST work.
        \\
    );
    defer r.deinit();
    try testing.expectEqualStrings("Two", r.file.sections[0].metadata.?.dependencies[0].form.title);
    try r.expect(5, .err, "invalid dependency entry");
    try r.expect(6, .err, "must be strings");
}
