# specrail
Spec-driven-development, on guardrails, for coding agents and humans alike

specrail keeps natural-language specs linked to the tests that prove them.
Requirements live in numbered sections of Markdown files. A test names the
requirement it verifies in a one-line comment. `specrail check` fails while
any finished requirement has no test, or while any comment no longer matches
the section it names. That gives an agent a signal to work against: a check
that passes only once the spec is covered.

specrail is built for AI agents first. Everything it reads and prints is easy
to find with `rg` and costs few tokens. It never runs tests and never judges
them; it only tracks that every requirement is claimed by at least one.

## A spec and its test

specrail is specified with specrail. This is the start of
[`specs/cli/init.spec.md`](specs/cli/init.spec.md):

````markdown
`specrail init` sets up a project. Unlike most commands, it does not need an
existing `specrail.toml`.

---

# § 1 Initializing a project

## § 1.1 Create config

`specrail init` MUST create `specrail.toml` in the working directory with
`spec_root = "specs"`, and MUST create the `specs` directory when it does not
exist.

## § 1.2 Root file

`specrail init` MUST create `root.spec.md` in the spec root when it does not
exist. The file MUST hold only context explaining its purpose, so that
`specrail check` passes on the new project. git does not track empty
directories, and without this file a fresh clone would have no spec root at
all.
````

And this is the test in [`src/init.zig`](src/init.zig) that verifies both
sections:

```zig
// specrail: specs/cli/init.spec.md § 1.1 Create config
// specrail: specs/cli/init.spec.md § 1.2 Root file
test "init sets up a project that check accepts" {
    ...
}
```

The comment lines are the whole link. If either section is renumbered or
retitled, `specrail check` reports the reference as stale, and `specrail mv`
or `specrail fmt` rewrites it, here in this README as well as in the test. A
section that is not built yet carries `status = "planned"` in a metadata
block, and `check` counts it apart instead of asking for its test.

Specs form one tree. `specs/cli.spec.md` is the parent of `specs/cli/`, and
its context applies to every spec below it. `specs/root.spec.md` is the root
of the tree. `specrail context` prints what an agent should read before
working on a section: the context of every spec above it, its ancestors, the
section itself, its dependencies and the tests that already verify it.

[`specs/`](specs) is the full specification of specrail, and
[`specs/root.spec.md`](specs/root.spec.md) is the place to start.

## Installing

specrail is a single binary, and it needs `git` at run time.

On Debian 13, or a system based on it, [`install.sh`](install.sh) installs
the Debian package from a
[release](https://github.com/ari-becker/specrail/releases), for amd64 or
arm64, and git with it. In the Dockerfile of an image for CI:

```dockerfile
FROM debian:trixie-slim
ARG SPECRAIL_VERSION=0.1.0
ADD https://raw.githubusercontent.com/ari-becker/specrail/v${SPECRAIL_VERSION}/install.sh /tmp/install-specrail.sh
RUN sh /tmp/install-specrail.sh "$SPECRAIL_VERSION" \
 && rm -rf /tmp/install-specrail.sh /var/lib/apt/lists/*
```

The script runs as root, and runs `apt-get update`, hence the `rm`. It
installs curl first when the image has none, and the latest release when it
is given no version.

Elsewhere, build it with Zig 0.17.1:

```sh
git clone https://github.com/ari-becker/specrail.git
cd specrail
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

That installs `~/.local/bin/specrail`.

## Getting started

In the root of a git repository:

```sh
specrail init        # creates specrail.toml and specs/root.spec.md
specrail check       # passes: there is nothing to cover yet
```

Then write specs under `specs/` and reference them from tests.

## Commands

| Command | Purpose |
| --- | --- |
| `specrail init` | Create `specrail.toml` and the spec root |
| `specrail check` | Verify specs, references and coverage |
| `specrail context` | Print what to read before working on a section |
| `specrail fmt` | Renumber sections, rewrite references, normalize spec files |
| `specrail mv` | Move or retitle a section, spec file or directory, rewriting references |
| `specrail swap` | Exchange two sections, rewriting references |
| `specrail claim` | Take a section for a limited time |
| `specrail release` | Give up a claim early |
| `specrail hook` | Check pushes to the claim branch, from git hook scripts |
| `specrail lsp` | Run the language server |
| `specrail skill` | Print the agent skill |

Sections are named on the command line the way a test names them, so a
reference can be pasted straight into a command. `%` can stand in for `§`:

```sh
specrail context 'specs/cli/init.spec.md % 1.1'
specrail mv 'specs/cli/init.spec.md § 1.1 Create config' \
            'specs/cli/init.spec.md § 1.1 Create the config file'
```

`fmt`, `mv` and `swap` rewrite every reference and dependency that names what
they change, so section numbers and titles are never edited by hand. `specrail
<command> --help` describes each command, and `specs/cli/` specifies it.

## Agents

Agents learn the workflow from a skill that is compiled into the binary, so
it always matches the installed version. Install it wherever your agent looks
for skills; for Claude Code:

```sh
mkdir -p .claude/skills/specrail
specrail skill > .claude/skills/specrail/SKILL.md
```

## Claims, for fleets of agents

When many agents pick work from the same specs at once, `specrail claim`
lets one of them take a section for a limited time. It pushes a tiny commit
to `main` that records who holds the section and until when. git accepts only
one of two racing pushes, so two agents never build the same thing. An agent
that a person drives from a terminal does not need claims.

```sh
export SPECRAIL_ASSIGNEE=agent-7
specrail claim 'specs/cli/init.spec.md § 1.3 Spec root option' --for 2h
```

`specrail hook` lets a git server accept direct pushes to `main` only when
they are valid claim commits. [`specs/cli/hook.spec.md`](specs/cli/hook.spec.md)
has example server and client hook scripts.

## Editors

`specrail lsp` is a language server: go to definition from a reference to
its section, find a section's references, hover, completion of paths and
headings, diagnostics as you type, rename, formatting, a renumbering action,
and reference updates when spec files are moved. It finds the project from
the editor's workspace folder.

Neovim 0.11 or later:

```lua
vim.lsp.config('specrail', {
  cmd = { 'specrail', 'lsp' },
  root_markers = { 'specrail.toml' },
})
vim.lsp.enable('specrail')
```

Emacs, with eglot, listing the modes of your specs and tests:

```elisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '((markdown-mode python-mode zig-mode) . ("specrail" "lsp"))))
```

Neither Neovim's built-in client nor eglot tells servers when files are
moved, so moving a spec file there leaves its references behind, and
`specrail check` reports them as dangling. `specrail mv` moves the file and
rewrites them.

## Developing specrail

```sh
zig build test        # unit and integration tests, then specrail check on this repository
zig build lint        # zlinter, with the rules in tools/lint/
zig build test-lsp    # the language server driven by pytest-lsp; needs uv
tools/fuzz-for.sh 60  # search for inputs that break a fuzz test for an hour, on every core

tools/fuzz-for.sh 60 "fuzz: any text is a document"  # only the fuzz tests so named
zig build test -Doptimize=ReleaseSafe --fuzz=100K  # 100K runs of each fuzz test, on one core
```

`zig build test-lsp` plays the clients of VS Code, Neovim and Emacs against
the server, using their recorded capabilities, and compares every edit the
server returns with what the CLI does.

The fuzz tests check properties against made-up inputs: fmt changes nothing
in its own output and keeps references matching; mv and swap keep every
reference that matched, lose no prose or title, and put each section where
they say, and a swap undoes itself; the hook accepts every claim and release
that `specrail claim` and `specrail release` write; the language server
answers every request about any project exactly once, its rename and
formatting do what mv and fmt do, and every heading it completes names its
section exactly; and the parsers take any text. `zig build test` runs each
of them on fixed seeds; `--fuzz` searches further. Without the `=100K`, it
runs a fuzzer on every core, which pass each other what they find, and a web
UI, and it never stops; `tools/fuzz-for.sh` runs it until a deadline. Every
fuzz test keeps the inputs it found in `.zig-cache/f`, and starts from them
the next time. Fuzzing needs a ReleaseSafe build: Debug builds for x86_64 use
Zig's own backend, which does not instrument code for the fuzzer. A failing
input is saved in `.zig-cache/f/crash`, and
`zig build test -Dfuzz-input=.zig-cache/f/crash` replays it. `zig build test
--fuzz` does not stop when a fuzz test fails, and with `=100K` it exits 0;
`tools/fuzz-for.sh` watches for that file instead. `-Dtest-filter=<name>`
builds only the tests so named.

On every push, CI runs the tests on Linux and macOS, lint, and the language
server tests. The Fuzz workflow gives every fuzz test a job of its own, on
all of its runner's cores, all of them at once: for 5 hours 50 minutes every
night, just inside the 6 hours GitHub allows a job, and for a quarter of an
hour on every pull request. Each job starts from the inputs its fuzz test
found the night before, with a seed no other job has had, and keeps any
input that fails as an artifact to replay.

To release, set `.version` in `build.zig.zon` and push the tag `v<version>`
of that commit. The Release workflow runs the tests on amd64 and arm64,
builds a Debian package for each with `tools/package-deb.sh`, installs it
with `install.sh` on Debian 13, and publishes the packages as a release. Run
by hand, it does all of that but publish.

## License

[GNU Affero General Public License v3.0](LICENSE)
