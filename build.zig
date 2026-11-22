//! Builds specrail, runs its tests, and lints it with zlinter.

const std = @import("std");

const zlinter = @import("zlinter");

/// The version `specrail --version` prints.
const version = @import("build.zig.zon").version;

/// Defines the install, run, test, test-lint-rules, lint and test-lsp steps.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "specrail",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // A fuzz input that failed, such as the one the Fuzz workflow keeps,
    // joins every fuzz test's seeds, so that `zig build test` replays it.
    const options = b.addOptions();
    const fuzz_input = b.option(
        []const u8,
        "fuzz-input",
        "Replay this fuzz input, relative to the project root, in every fuzz test",
    );
    options.addOption(?[]const u8, "fuzz_input", fuzz_input);
    options.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_options", options);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run specrail");
    run_step.dependOn(&run_cmd.step);

    // The Fuzz workflow fuzzes each fuzz test in a job of its own.
    const filters = b.option(
        []const []const u8,
        "test-filter",
        "Build only the tests whose names contain this; may be given more than once",
    ) orelse &.{};
    const tests = b.addTest(.{ .root_module = exe.root_module, .filters = filters });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_tests.step);
    // The test build leaves `main` out, so the executable is built too: a
    // compile error there fails the tests as well.
    test_step.dependOn(&exe.step);

    // The repository checks itself with the specrail just built: every finished
    // requirement in specs/ has a test that references it. This runs on every
    // build, since the specs and tests it reads are not inputs the build system
    // tracks.
    const self_check = b.addRunArtifact(exe);
    self_check.addArgs(&.{ "check", "--warnings-as-errors" });
    self_check.setCwd(b.path("."));
    self_check.stdio = .inherit;
    b.step("check", "Check that every finished requirement has a test").dependOn(&self_check.step);
    test_step.dependOn(&self_check.step);

    const rule_tests = ruleTestStep(b, exe.root_module);
    test_step.dependOn(rule_tests);
    b.step("test-lint-rules", "Run the custom lint rules' tests").dependOn(rule_tests);

    b.step("lint", "Lint the Zig sources").dependOn(lintStep(b));
    b.step("test-lsp", "Run the language server's end-to-end tests").dependOn(lspTestStep(b, exe));
}

/// The custom lint rules' own tests, for the target and optimization `like`
/// has: a rule that flags nothing looks the same as one that works, until it
/// is tested.
fn ruleTestStep(b: *std.Build, like: *std.Build.Module) *std.Build.Step {
    const rule_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/lint/tests.zig"),
        .target = like.resolved_target,
        .optimize = like.optimize,
        .imports = &.{
            .{ .name = "zlinter", .module = b.dependency("zlinter", .{}).module("zlinter") },
        },
    }) });
    return &b.addRunArtifact(rule_tests).step;
}

/// The language server driven the way editors drive it: pytest-lsp plays the
/// clients of VS Code, Neovim and Emacs. It needs uv, so it is a step of its
/// own rather than part of `test`.
fn lspTestStep(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step {
    const lsp_tests = b.addSystemCommand(&.{
        "uv", "run", "--locked", "--project", "tests/lsp", "pytest", "-q", "tests/lsp",
    });
    lsp_tests.addPrefixedArtifactArg("--specrail=", exe);
    lsp_tests.setCwd(b.path("."));
    lsp_tests.stdio = .inherit;
    // The tests are not inputs the build system tracks, so they always run.
    lsp_tests.has_side_effects = true;
    return &lsp_tests.step;
}

/// The TigerStyle rules in `tools/lint/`, each named after its file.
const custom_rules = [_][]const u8{
    "callbacks_last",
    "comment_sentences",
    "div_intent",
    "fn_length",
    "line_length",
    "loop_bound",
    "no_compound_assert",
    "no_twin_int_params",
    "qualifier_last",
    "recursion_bound",
};

/// The lint step: zlinter with every built-in rule, and the custom rules.
/// Warnings fail it too, so every rule is a control, not advice.
fn lintStep(b: *std.Build) *std.Build.Step {
    var builder = zlinter.builder(b, .{});
    // Short names such as `i` and `ok` are ordinary Zig.
    builder.addRule(.{ .builtin = .field_naming }, .{ .union_field_min_len = .off });
    // Fields are alphabetical; code that needs another order says so
    // explicitly, as `diag.Severity.rank` does.
    builder.addRule(.{ .builtin = .field_ordering }, .{});
    builder.addRule(.{ .builtin = .declaration_naming }, .{ .decl_name_min_len = .off });
    builder.addRule(.{ .builtin = .function_naming }, .{});
    builder.addRule(.{ .builtin = .file_naming }, .{});
    builder.addRule(.{ .builtin = .import_ordering }, .{});
    builder.addRule(.{ .builtin = .build_zig_zon }, .{});
    builder.addRule(.{ .builtin = .require_fmt }, .{});
    builder.addRule(.{ .builtin = .require_braces }, .{});
    builder.addRule(.{ .builtin = .require_doc_comment }, .{ .file_severity = .warning });
    builder.addRule(.{ .builtin = .require_errdefer_dealloc }, .{});
    builder.addRule(.{ .builtin = .require_exhaustive_enum_switch }, .{});
    builder.addRule(.{ .builtin = .require_labeled_continue }, .{});
    builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
    builder.addRule(.{ .builtin = .max_positional_args }, .{});
    builder.addRule(.{ .builtin = .no_comment_out_code }, .{});
    builder.addRule(.{ .builtin = .no_deprecated }, .{});
    builder.addRule(.{ .builtin = .no_empty_block }, .{});
    builder.addRule(.{ .builtin = .no_global_vars }, .{});
    builder.addRule(.{ .builtin = .no_hidden_allocations }, .{});
    builder.addRule(.{ .builtin = .no_inferred_error_unions }, .{});
    builder.addRule(.{ .builtin = .no_literal_args }, .{});
    builder.addRule(.{ .builtin = .no_literal_only_bool_expression }, .{});
    builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
    builder.addRule(.{ .builtin = .no_panic }, .{});
    builder.addRule(.{ .builtin = .no_redundant_comptime }, .{});
    builder.addRule(.{ .builtin = .no_swallow_error }, .{});
    builder.addRule(.{ .builtin = .no_todo }, .{});
    builder.addRule(.{ .builtin = .no_unsafe_undefined }, .{});
    builder.addRule(.{ .builtin = .no_unused }, .{});
    inline for (custom_rules) |name| {
        builder.addRule(
            .{ .custom = .{ .name = name, .path = "tools/lint/" ++ name ++ ".zig" } },
            .{},
        );
    }
    const lint = builder.build();
    lint.cast(std.Build.Step.Run).?.addArgs(&.{ "--max-warnings", "0" });
    return lint;
}
