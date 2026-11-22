//! Claims on sections: who holds a section and until when, what keeps a new
//! claim off a section, writing a claim into a spec file, and deciding whether
//! a change to a spec file only claims and releases sections. `specrail
//! claim`, `specrail release` and `specrail hook` share it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diag = @import("diag.zig");
const fmt = @import("fmt.zig");
const refs = @import("refs.zig");
const rewrite = @import("rewrite.zig");
const spec = @import("spec.zig");
const toml = @import("toml.zig");

/// Who holds a section, and until when. A hold without `until` is an
/// assignment without expiry, typically to a person.
pub const Hold = struct {
    assignee: []const u8,
    until: ?toml.DateTime = null,

    /// Whether the hold keeps others off the section at `now`.
    pub fn isActive(h: Hold, now: i64) bool {
        const until = h.until orelse return true;
        return until.seconds > now;
    }

    /// The hold in words, such as `agent-7 until 2026-11-17T16:00:00Z`.
    pub fn describe(h: Hold, arena: Allocator) Allocator.Error![]const u8 {
        const until = h.until orelse return arena.print("{s}, with no expiry", .{h.assignee});
        return arena.print("{s} until {s}", .{ h.assignee, until.text });
    }

    fn eql(a: Hold, b: Hold) bool {
        if (!std.mem.eql(u8, a.assignee, b.assignee)) return false;
        const a_until = if (a.until) |u| u.text else "";
        const b_until = if (b.until) |u| u.text else "";
        return std.mem.eql(u8, a_until, b_until);
    }
};

/// A claim to write: who takes the section, and until when, as an RFC 3339
/// date-time.
pub const Claim = struct {
    assignee: []const u8,
    until: []const u8,
};

const claim_keys = [_][]const u8{ "assigned", "assigned-until" };

fn isClaimKey(key: []const u8) bool {
    for (claim_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

/// The hold on a section, if it has one.
pub fn holdOf(s: spec.Section) ?Hold {
    const m = s.metadata orelse return null;
    const who = m.assigned orelse return null;
    return .{ .assignee = who, .until = m.assigned_until };
}

fn heldByOther(s: spec.Section, assignee: []const u8, now: i64) bool {
    const h = holdOf(s) orelse return false;
    return h.isActive(now) and !std.mem.eql(u8, h.assignee, assignee);
}

/// The first of the section at `index`, its ancestors and its descendants
/// that someone other than `assignee` holds at `now`.
pub fn conflict(file: *const spec.SpecFile, index: usize, assignee: []const u8, now: i64) ?usize {
    const sections = file.sections;
    var at: ?usize = index;
    // Each step moves to a parent, which comes earlier in the file.
    while (at) |i| {
        if (heldByOther(sections[i], assignee, now)) return i;
        at = sections[i].parent;
    }
    const level = sections[index].level;
    for (sections[index + 1 ..], index + 1..) |s, i| {
        if (s.level <= level) break;
        if (heldByOther(s, assignee, now)) return i;
    }
    return null;
}

/// The entries of a metadata block, from the lines between its fences;
/// null when they are not valid TOML.
fn blockEntries(
    arena: Allocator,
    inner: []const []const u8,
    newline: []const u8,
) Allocator.Error!?[]const toml.Entry {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(arena);
    for (inner, 0..) |l, k| {
        if (k > 0) try text.appendSlice(arena, newline);
        try text.appendSlice(arena, rewrite.body(l));
    }
    // The entries point into the text, so it stays allocated.
    const owned = try text.toOwnedSlice(arena);
    return switch (try toml.parse(arena, owned)) {
        .ok => |doc| doc.entries,
        .err => null,
    };
}

/// A `key = value` line to write, with its value as it is to be written.
const Line = struct {
    key: []const u8,
    value: []const u8,
};

/// `content`, the text `file` was parsed from, with the hold on the section at
/// `index` set to `claim`, or removed when `claim` is null. The metadata block
/// is written in fmt's canonical form, and nothing outside it changes. Null
/// when the section's metadata block cannot be read.
pub fn withClaim(
    arena: Allocator,
    file: *const spec.SpecFile,
    content: []const u8,
    index: usize,
    claim: ?Claim,
) Allocator.Error!?[]const u8 {
    const lines = try rewrite.splitLines(arena, content);
    const newline = rewrite.fileEnding(lines);
    const s = file.sections[index];
    var kept: std.ArrayList(Line) = .empty;
    defer kept.deinit(arena);
    // A new block goes right after the heading; an existing one is replaced.
    var start: usize = s.line;
    var end: usize = s.line;
    var last_ending = newline;
    if (s.metadata) |m| {
        if (m.close_line == 0) return null;
        start = m.line - 1;
        end = m.close_line;
        last_ending = rewrite.ending(lines[m.close_line - 1]);
        const entries = (try blockEntries(arena, lines[m.line .. m.close_line - 1], newline)) orelse
            return null;
        for (entries) |e| {
            if (!isClaimKey(e.key)) try kept.append(arena, .{ .key = e.key, .value = e.text });
        }
    }
    if (claim) |c| {
        const quoted = try rewrite.basicString(arena, c.assignee);
        try kept.append(arena, .{ .key = "assigned", .value = quoted });
        try kept.append(arena, .{ .key = "assigned-until", .value = c.until });
    }
    const closing = if (last_ending.len > 0) last_ending else newline;
    // An empty block stays when removing it would make a later block the
    // section's metadata block, or a `---` line below it the separator.
    const keep_empty = s.metadata != null and
        (spec.tomlBlockFollows(lines[end..]) or
            promotesSeparator(file, .{ .start = start, .end = end }));
    const block = if (kept.items.len == 0 and keep_empty)
        try arena.print("```toml{s}```{s}", .{ newline, closing })
    else
        try render(arena, kept.items, newline, closing);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    for (lines[0..start]) |l| try out.appendSlice(arena, l);
    // A heading on the last line, without an ending, gets one before a block.
    if (s.metadata == null and block.len > 0 and rewrite.ending(lines[start - 1]).len == 0) {
        try out.appendSlice(arena, newline);
    }
    try out.appendSlice(arena, block);
    for (lines[end..]) |l| try out.appendSlice(arena, l);
    return try out.toOwnedSlice(arena);
}

/// Whether removing `block`, the lines of a metadata block, would put a `---`
/// line right below a blank one in a file without a separator. That line
/// would become the separator, and the sections above it context. The lines
/// are judged as the parser reads them, without their trailing `\r`s.
fn promotesSeparator(file: *const spec.SpecFile, block: spec.Range) bool {
    const lines = file.lines;
    if (file.separator != null or block.end >= lines.len) return false;
    // A heading comes before the block, so it never starts on the first line.
    return spec.isBlank(lines[block.start - 1]) and spec.isSeparator(lines[block.end]);
}

/// A metadata block in fmt's canonical form: the known keys in fmt's order,
/// then the extension keys as they came, each `=` one space after the longest
/// key. Empty when there are no keys.
fn render(
    arena: Allocator,
    lines: []const Line,
    newline: []const u8,
    last_ending: []const u8,
) Allocator.Error![]const u8 {
    if (lines.len == 0) return "";
    var ordered: std.ArrayList(Line) = .empty;
    defer ordered.deinit(arena);
    for (fmt.known_keys) |k| {
        for (lines) |l| {
            if (std.mem.eql(u8, l.key, k)) try ordered.append(arena, l);
        }
    }
    for (lines) |l| {
        if (!fmt.isKnown(l.key)) try ordered.append(arena, l);
    }
    var width: usize = 0;
    for (ordered.items) |l| width = @max(width, l.key.len);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try out.print(arena, "```toml{s}", .{newline});
    for (ordered.items) |l| {
        try out.appendSlice(arena, l.key);
        try out.appendNTimes(arena, ' ', width - l.key.len);
        try out.print(arena, " = {s}{s}", .{ l.value, newline });
    }
    try out.print(arena, "```{s}", .{last_ending});
    return out.toOwnedSlice(arena);
}

/// One line of a spec file as a claim-only change sees it, where a metadata
/// block counts only by its keys other than `assigned` and `assigned-until`.
const Piece = struct {
    /// 1-based line in the file.
    line: usize,
    text: []const u8,
};

/// The pieces of a spec file that a claim commit must leave as they are.
fn skeleton(
    arena: Allocator,
    file: *const spec.SpecFile,
    content: []const u8,
) Allocator.Error![]Piece {
    const lines = try rewrite.splitLines(arena, content);
    const block_at = try arena.alloc(?spec.Metadata, lines.len);
    defer arena.free(block_at);
    @memset(block_at, null);
    for (file.sections) |s| {
        const m = s.metadata orelse continue;
        if (m.close_line > 0) block_at[m.line - 1] = m;
    }
    var out: std.ArrayList(Piece) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const m = block_at[i] orelse {
            try out.append(arena, .{ .line = i + 1, .text = lines[i] });
            continue;
        };
        const entries = (try blockEntries(arena, lines[m.line .. m.close_line - 1], "\n")) orelse {
            try out.append(arena, .{ .line = i + 1, .text = lines[i] });
            continue;
        };
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(arena);
        // Keys may change order; their values may not change.
        const sorted = try arena.dupe(toml.Entry, entries);
        std.mem.sort(toml.Entry, sorted, {}, keyLess);
        for (sorted) |e| {
            if (!isClaimKey(e.key)) try text.print(arena, "{s} = {s}\n", .{ e.key, e.text });
        }
        if (text.items.len > 0) {
            const kept_keys = try text.toOwnedSlice(arena);
            try out.append(arena, .{ .line = i + 1, .text = kept_keys });
        }
        i = m.close_line - 1;
    }
    return out.toOwnedSlice(arena);
}

fn keyLess(_: void, a: toml.Entry, b: toml.Entry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

/// The rules a claim must keep, at the time of a change.
pub const Rules = struct {
    now: i64,
    /// `claim_max_hours` from `specrail.toml`.
    hours_max: ?i64 = null,
};

/// Why the change of the spec file at `path` from `before` to `after` is not
/// one a claim commit may make; null when it is. A claim commit only adds,
/// renews and removes `assigned` and `assigned-until`, with an expiry in the
/// future, within `claim_max_hours`, and without taking a section, or a
/// section above or below it, from someone who holds it.
pub fn checkChange(
    arena: Allocator,
    path: []const u8,
    before: []const u8,
    after: []const u8,
    rules: Rules,
) Allocator.Error!?[]const u8 {
    var found: diag.List = .empty;
    defer found.deinit(arena);
    const old = try spec.parse(arena, path, before, &found);
    const new = try spec.parse(arena, path, after, &found);
    if (old.broken or new.broken) {
        const msg = "changes {s}, which has errors that keep it from being checked";
        return try arena.print(msg, .{path});
    }
    const old_pieces = try skeleton(arena, &old, before);
    const new_pieces = try skeleton(arena, &new, after);
    for (0..@max(old_pieces.len, new_pieces.len)) |k| {
        const same = k < old_pieces.len and k < new_pieces.len and
            std.mem.eql(u8, old_pieces[k].text, new_pieces[k].text);
        if (same) continue;
        const line = if (k < new_pieces.len) new_pieces[k].line else new.lines.len;
        const msg = "changes {s}:{d}, beyond assigned and assigned-until";
        return try arena.print(msg, .{ path, line });
    }
    // The same lines can still read as other sections, such as when a `---`
    // comes to follow a blank line and turns the sections above it into
    // context.
    if (!sameSections(old.sections, new.sections)) {
        const msg = "changes which sections {s} has, beyond assigned and assigned-until";
        return try arena.print(msg, .{path});
    }
    for (old.sections, new.sections, 0..) |o, n, i| {
        const holds: Holds = .{ .old = holdOf(o), .new = holdOf(n) };
        if (try checkSection(arena, &new, i, holds, rules)) |why| {
            const parts = .{ path, refs.section_sign, n.number, n.title };
            const name = try arena.print("{s} {s} {s} {s}", parts);
            return try arena.print("{s}: {s}", .{ name, why });
        }
    }
    return null;
}

/// Whether `a` and `b` are the same sections, by number and title, in the
/// same order.
fn sameSections(a: []const spec.Section, b: []const spec.Section) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.number, y.number)) return false;
        if (!std.mem.eql(u8, x.title, y.title)) return false;
    }
    return true;
}

/// A section's hold before and after a change.
const Holds = struct {
    old: ?Hold,
    new: ?Hold,
};

/// Why the hold on the section at `index` of `file` may not change as `holds`
/// says in a claim commit; null when it may.
fn checkSection(
    arena: Allocator,
    file: *const spec.SpecFile,
    index: usize,
    holds: Holds,
    rules: Rules,
) Allocator.Error!?[]const u8 {
    const old = holds.old;
    const n = holds.new orelse return null;
    if (old) |o| {
        if (o.eql(n)) return null;
    }
    const until = n.until orelse {
        return try arena.print("assigns {s} without assigned-until", .{n.assignee});
    };
    if (until.seconds <= rules.now) {
        return try arena.print("claims it until {s}, which has passed", .{until.text});
    }
    if (rules.hours_max) |max| {
        if (until.seconds > rules.now + max * 3600) {
            const msg = "claims it until {s}, more than claim_max_hours ({d}) from now";
            return try arena.print(msg, .{ until.text, max });
        }
    }
    if (old) |o| {
        if (o.isActive(rules.now) and !std.mem.eql(u8, o.assignee, n.assignee)) {
            return try arena.print("takes it from {s}", .{try o.describe(arena)});
        }
    }
    if (conflict(file, index, n.assignee, rules.now)) |j| {
        const s = file.sections[j];
        const held = try holdOf(s).?.describe(arena);
        const msg = "claims it while § {s} {s} is held by {s}";
        return try arena.print(msg, .{ s.number, s.title, held });
    }
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const plain =
    \\# § 1 Login
    \\
    \\## § 1.1 Password
    \\```toml
    \\status = "planned"
    \\```
    \\
    \\It MUST accept a password.
    \\
    \\## § 1.2 Google
    \\
    \\It MUST accept Google.
    \\
;

/// `content` with a claim set on, or removed from, its section `index`.
fn claimed(arena: Allocator, content: []const u8, index: usize, claim: ?Claim) ![]const u8 {
    var found: diag.List = .empty;
    defer found.deinit(arena);
    const file = try spec.parse(arena, "specs/a.spec.md", content, &found);
    return (try withClaim(arena, &file, content, index, claim)).?;
}

// specrail: specs/cli/claim.spec.md § 2.1 Release commit
test "a released block stays, empty, when the next block would take its place" {
    // Found by fuzzing: removing it made the code block below the metadata
    // block, and the hook refused the release.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const content = "# § 1 One\n```toml\n```\n```toml\nnot = metadata\n```\nIt MUST work.\n";
    const claim: Claim = .{ .assignee = "agent-7", .until = "2026-11-17T02:00:00Z" };
    const held = try claimed(arena, content, 0, claim);
    try testing.expectEqualStrings(content, try claimed(arena, held, 0, null));
    const rules: Rules = .{ .now = 20774 * 86400 };
    const why = try checkChange(arena, "specs/a.spec.md", held, content, rules);
    try testing.expectEqual(@as(?[]const u8, null), why);
}

// specrail: specs/cli/claim.spec.md § 2.1 Release commit
test "a released block stays, empty, when a --- line below it would become the separator" {
    // Found by fuzzing: removing it put the --- right after a blank line,
    // which made it the separator and the section above it context, and the
    // hook refused the release.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const claim: Claim = .{ .assignee = "agent-7", .until = "2026-11-17T02:00:00Z" };
    const rules: Rules = .{ .now = 20774 * 86400 };
    // Found by fuzzing too: a line of only carriage returns is blank, and
    // `---` and carriage returns a separator, as the parser reads them.
    const kept = [_][]const u8{
        "# § 1 One\n\n```toml\n```\n---\nIt MUST work.\n",
        "# § 1 One\n\r\r\n```toml\n```\n---\nIt MUST work.\n",
        "# § 1 One\n \t\n```toml\n```\n---\r\r\nIt MUST work.\n",
    };
    for (kept) |content| {
        const held = try claimed(arena, content, 0, claim);
        try testing.expectEqualStrings(content, try claimed(arena, held, 0, null));
        const why = try checkChange(arena, "specs/a.spec.md", held, content, rules);
        try testing.expectEqual(@as(?[]const u8, null), why);
    }
    // Otherwise the block goes: below a separator, the --- is a line of
    // prose, and without the blank line or the ---, no line becomes one.
    const cases = [_]struct { []const u8, []const u8 }{
        .{
            "Context.\n\n---\n\n# § 1 One\n\n```toml\n```\n---\nIt MUST work.\n",
            "Context.\n\n---\n\n# § 1 One\n\n---\nIt MUST work.\n",
        },
        .{ "# § 1 One\n```toml\n```\n---\nIt MUST work.\n", "# § 1 One\n---\nIt MUST work.\n" },
        .{ "# § 1 One\n\n```toml\n```\nIt MUST work.\n", "# § 1 One\n\nIt MUST work.\n" },
    };
    for (cases) |c| {
        const with_claim = try claimed(arena, c[0], 0, claim);
        const released = try claimed(arena, with_claim, 0, null);
        try testing.expectEqualStrings(c[1], released);
        const accepted = try checkChange(arena, "specs/a.spec.md", with_claim, released, rules);
        try testing.expectEqual(@as(?[]const u8, null), accepted);
    }
}

// specrail: specs/cli/hook.spec.md § 1.1 Definition
test "the hook refuses a change that keeps every line but not every section" {
    // Found by fuzzing: removing the block makes the --- the separator, and
    // § 1 context. The lines are the same, so the hook compared the sections
    // one by one, and crashed on lists of different lengths.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const held =
        "# § 1 One\n\n```toml\nassigned       = \"agent-7\"\n" ++
        "assigned-until = 2026-11-17T02:00:00Z\n```\n---\n# § 2 Two\n\nIt MUST work.\n";
    const released = "# § 1 One\n\n---\n# § 2 Two\n\nIt MUST work.\n";
    const rules: Rules = .{ .now = 20774 * 86400 };
    const why = (try checkChange(arena, "specs/a.spec.md", held, released, rules)).?;
    try testing.expectEqualStrings(
        "changes which sections specs/a.spec.md has, beyond assigned and assigned-until",
        why,
    );
}

test "a claim is written as a canonical metadata block, and removed without a trace" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const claim: Claim = .{ .assignee = "agent-7", .until = "2026-11-17T02:00:00Z" };
    const google = try claimed(arena, plain, 2, claim);
    try testing.expect(std.mem.find(u8, google,
        \\## § 1.2 Google
        \\```toml
        \\assigned       = "agent-7"
        \\assigned-until = 2026-11-17T02:00:00Z
        \\```
        \\
        \\It MUST accept Google.
    ) != null);
    try testing.expectEqualStrings(plain, try claimed(arena, google, 2, null));
    const password = try claimed(arena, plain, 1, claim);
    try testing.expect(std.mem.find(u8, password,
        \\```toml
        \\status         = "planned"
        \\assigned       = "agent-7"
        \\assigned-until = 2026-11-17T02:00:00Z
        \\```
    ) != null);
    try testing.expectEqualStrings(plain, try claimed(arena, password, 1, null));
}

/// A project whose `origin` is a bare repository, for the tests of claim,
/// release and hook.
pub const fixture = struct {
    const sandbox = @import("sandbox.zig");
    const Sandbox = sandbox.Sandbox;
    const SetUpError = sandbox.GitError || sandbox.WriteError || Allocator.Error;

    /// The spec file whose sections the tests claim.
    pub const path = "specs/a.spec.md";

    /// Its content at first.
    pub const login =
        \\# § 1 Login
        \\
        \\## § 1.1 Password
        \\```toml
        \\status = "planned"
        \\```
        \\
        \\It MUST accept a password.
        \\
        \\## § 1.2 Google
        \\
        \\It MUST accept Google.
        \\
    ;

    /// Makes `s` a project with `config` as its `specrail.toml`, whose
    /// `origin` is the bare repository `r.git` in `remote`, and pushes it to
    /// that repository's main.
    pub fn setUp(s: *Sandbox, remote: *Sandbox, config: []const u8) SetUpError!void {
        try remote.git(&.{ "git", "init", "-q", "--bare", "-b", "main", "r.git" });
        try s.write("specrail.toml", config);
        try s.write(path, login);
        try s.write("src/t.zig", "// specrail: specs/a.spec.md § 1.2 Google\n");
        try s.commitAll("init");
        const url = try std.Io.Dir.path.join(s.arena_state.allocator(), &.{ remote.root, "r.git" });
        try s.git(&.{ "git", "remote", "add", "origin", url });
        try s.git(&.{ "git", "push", "-q", "origin", "main" });
    }

    /// Runs git in the remote's bare repository, and returns what it printed,
    /// without surrounding whitespace.
    pub fn remoteGit(
        remote: *Sandbox,
        args: []const []const u8,
    ) (sandbox.GitError || Allocator.Error)![]const u8 {
        const arena = remote.arena_state.allocator();
        const git_dir = [_][]const u8{ "git", "--git-dir", "r.git" };
        const argv = try std.mem.concat(arena, []const u8, &.{ &git_dir, args });
        return remote.gitOutput(argv);
    }

    /// The spec file as the remote's main holds it.
    pub fn remoteSpec(remote: *Sandbox) (sandbox.GitError || Allocator.Error)![]const u8 {
        return remote.gitRaw(&.{ "git", "--git-dir", "r.git", "show", "main:" ++ path });
    }

    /// The id of the remote's main.
    pub fn remoteTip(remote: *Sandbox) (sandbox.GitError || Allocator.Error)![]const u8 {
        return remoteGit(remote, &.{ "rev-parse", "main" });
    }

    /// Writes `content` to the spec file, commits it, and returns the commit.
    pub fn commitSpec(s: *Sandbox, content: []const u8) SetUpError![]const u8 {
        try s.write(path, content);
        try s.commitAll("change the spec");
        return s.gitOutput(&.{ "git", "rev-parse", "HEAD" });
    }
};

// ---------------------------------------------------------------- fuzz tests

const fuzzing = @import("fuzzing.zig");

/// Noon UTC on 2026-11-17, before every expiry the made-up files hold.
const fuzz_now: i64 = 20774 * 86400 + 12 * 3600;

/// Fails, showing why the hook refused a change claim made.
fn refused(why: []const u8, before: []const u8, after: []const u8) error{TestHookRefused} {
    const parts = .{ why, before, after };
    std.debug.print("hook refused: {s}\n--- before\n{s}\n--- after\n{s}\n", parts);
    return error.TestHookRefused;
}

/// Wherever `specrail claim` would claim a section of any spec file, the
/// hook accepts the change it writes, and the change that releases it.
fn claimThenRelease(_: void, smith: *testing.Smith) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = fuzzing.spec_paths[0];
    const before = try fuzzing.specText(smith, arena);
    var found: diag.List = .empty;
    errdefer found.deinit(arena);
    const file = try spec.parse(arena, path, before, &found);
    if (file.broken or file.sections.len == 0) return;
    const index = smith.index(file.sections.len);
    // The claim command refuses these, and changes nothing.
    if (conflict(&file, index, "fuzzer", fuzz_now) != null) return;
    const claim: Claim = .{ .assignee = "fuzzer", .until = "2027-01-01T00:00:00Z" };
    const with_claim = (try withClaim(arena, &file, before, index, claim)) orelse return;
    const rules: Rules = .{ .now = fuzz_now };
    if (try checkChange(arena, path, before, with_claim, rules)) |why| {
        return refused(why, before, with_claim);
    }
    const held = try spec.parse(arena, path, with_claim, &found);
    const released = (try withClaim(arena, &held, with_claim, index, null)) orelse
        return error.TestUnexpectedResult;
    if (try checkChange(arena, path, with_claim, released, rules)) |why| {
        return refused(why, with_claim, released);
    }
}

// specrail: specs/cli/claim.spec.md § 1.1 Claim commit
// specrail: specs/cli/claim.spec.md § 2.1 Release commit
// specrail: specs/cli/hook.spec.md § 1.1 Definition
test "fuzz: the hook accepts every claim and release that claim writes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const corpus = try fuzzing.seeds(arena_state.allocator(), &.{});
    try testing.fuzz({}, claimThenRelease, .{ .corpus = corpus });
}
