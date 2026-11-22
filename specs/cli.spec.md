# The command line

specrail is a single binary with no runtime dependencies other than `git`.

| Command | Purpose |
| --- | --- |
| `specrail init` | Create `specrail.toml` |
| `specrail check` | Verify specs, references and coverage |
| `specrail context` | Print what an agent needs to read before working on a section |
| `specrail fmt` | Normalize spec files, renumber sections, rewrite references |
| `specrail mv` | Rename or move a section or spec file, rewriting references |
| `specrail swap` | Exchange two sections, rewriting references |
| `specrail claim` | Take a section for a limited time by pushing a claim commit |
| `specrail release` | Give up a claim early |
| `specrail hook` | Git hooks that let only claim commits be pushed to the claim branch |
| `specrail lsp` | Run the language server over stdin and stdout |
| `specrail skill` | Print the agent skill |

Agents pay for every byte of output in tokens. Commands print nothing beyond
what they were asked for, and paths are always relative to the project root.

Sections are named on the command line in reference form, the same text that
follows `specrail: ` in a test, so an agent can paste a reference straight
from code into a command. Where `§` is hard to type, `%` works in its place:
`specrail context specs/auth/login.spec.md % 1.1.1`.

## Diagnostic lines

Commands that report problems in specs or references describe each problem in
one line of the same shape, a diagnostic line:

```
<path>:<line>:<column>: <severity>: <message>
```

`<path>` is relative to the project root, `<line>` and `<column>` count from
1, and `<severity>` is `error`, `warning` or `note`. Terminals and editors turn
this shape into a link. Each command's spec says where its diagnostics go: to
stdout when they are the command's output, as for `check`, or to stderr when
stdout carries something else, as for `context`.

## Exit status

Commands share three exit statuses:

- 0: the command did what it was asked.
- 1: the command ran but found a problem, in the specs, in references, or with
  the section or claim it was asked about.
- 2: the command could not run, because of a usage error, a configuration
  error, or a failure to run `git` or to read or write files.

`specrail lsp` is the exception: the Language Server Protocol defines its exit
status.

The requirements below cover what every command shares: argument parsing and
the way diagnostic lines are written. Everything else a command prints is
specified with that command.

---

# § 1 Arguments

## § 1.1 Help

`specrail --help` MUST print to stdout a usage summary listing every command,
and `specrail <command> --help` MUST print that command's usage to stdout.
Both MUST exit with status 0.

## § 1.2 Usage errors

Given an unknown command, an unknown option, or a missing or malformed
argument, specrail MUST print the problem to stderr with a hint to run
`specrail <command> --help`, or `specrail --help` when the command itself is
missing or unknown, and exit with status 2.

## § 1.3 Version

`specrail --version` MUST print to stdout the version that `build.zig.zon`
names, alone on a line, and exit with status 0.

# § 2 Color

Color helps a person scan diagnostics in a terminal. Anywhere else, escape
codes cost agents tokens and stop editors from recognizing the
`<path>:<line>:<column>` shape, so by default color is only for terminals.
`--color=always` forces it on where it is wanted anyway, such as CI logs that
render it.

## § 2.1 Colored diagnostics

When color is on, specrail MUST color diagnostic lines: the location in bold,
and the severity in red for `error`, yellow for `warning` and cyan for
`note`.

## § 2.2 Color option

Every command MUST accept `--color=<when>`, where `<when>` is `auto`,
`always` or `never`.

## § 2.3 Automatic color

By default, and given `--color=auto`, color MUST be on exactly when the
output stream is a terminal and the `NO_COLOR` environment variable is unset
or empty, as described at https://no-color.org.

## § 2.4 Forced color

Given `--color=always`, color MUST be on even when the output is not a
terminal or `NO_COLOR` is set, because an explicit option overrides the
environment, as no-color.org recommends.

## § 2.5 No color

Given `--color=never`, color MUST be off.
