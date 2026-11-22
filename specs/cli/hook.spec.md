`specrail hook` lets a git server forbid direct pushes to the claim branch in
general while letting claim commits through. specrail decides only whether a
push consists of valid claim commits; the hook script that calls it decides
when to ask. The provider's own branch protection has to let agents push to
the claim branch for the hook to run at all; the hook then becomes the rule.

Some providers also run pre-receive hooks for the pull request merges they
perform themselves, and identify those merges through their own environment
variables. A server hook script therefore typically lets those through and
sends everything else to specrail:

```sh
#!/bin/sh
# Server-side pre-receive hook. How to recognize the provider's own pull
# request merges is provider-specific; is_provider_merge stands in for it.
if is_provider_merge; then exit 0; fi
exec specrail hook pre-receive
```

The same check can run on the client, from a pre-push hook script, so that an
agent learns before pushing that a push to the claim branch would be
rejected. As on the server, the script decides when to ask. People who push
other work to the claim branch should not be stopped, so a script might check
only agents, which name themselves in `SPECRAIL_ASSIGNEE`:

```sh
#!/bin/sh
# Client-side pre-push hook: agents push only claims to the claim branch.
if [ -n "$SPECRAIL_ASSIGNEE" ]; then
  exec specrail hook pre-push "$@"
fi
```

The client hook is a convenience, since `git push --no-verify` skips it; the
server hook is the enforcement. When the project lives in a subdirectory of
the repository, both hooks take `--project <dir>` to say where. Hosted
providers that do not run custom server hooks can get the same effect from a
bot that is allowed to bypass branch protection: agents push claims to a side
branch, and the bot runs the same check and fast-forwards the claim branch.

---

# § 1 Claim commits

## § 1.1 Definition

specrail MUST count a commit as a claim commit exactly when it has one parent,
changes only spec files, and each changed spec file differs from its version
in the parent only in metadata blocks whose keys and values, other than
`assigned` and `assigned-until`, are unchanged. A block MAY be added or
removed when it holds only those two keys. Each changed spec file MUST also
keep the same sections, with the same numbers and titles in the same order,
which a block's removal could change without changing any other line.

## § 1.2 Valid expiry

Every claim that a claim commit adds or renews MUST have an `assigned-until`
later than the current time and, when `claim_max_hours` is set, no more than
that many hours after the current time.

## § 1.3 No takeovers

A claim commit MUST NOT change the assignee of a section that is held by an
unexpired claim or by an assignment without `assigned-until`, and MUST NOT
claim a section whose ancestor sections or descendants are held that way by a
different assignee.

# § 2 Server side

## § 2.1 Input

`specrail hook pre-receive` MUST read the `<old> <new> <ref>` lines that git
passes to a pre-receive hook on stdin, and check only updates to the claim
branch.

## § 2.2 Fast-forward only

It MUST reject an update to the claim branch that is not a fast-forward, that
creates the branch, or that deletes it.

## § 2.3 Only claim commits

It MUST reject an update to the claim branch when any commit in
`<old>..<new>` is not a claim commit, or breaks the rules for claim commits on
expiry or takeovers.

## § 2.4 Without a working tree

It MUST run in a bare repository without a project root, reading
`specrail.toml` and spec files from git objects, and MUST decide whether a ref
is the claim branch using the `specrail.toml` at the root of the ref's old
tip, or of its new tip when the update creates the ref.

## § 2.5 Rejection messages

For each rejected update, it MUST print to stderr one line naming the first
offending commit and the change that disqualifies it. It MUST exit with
status 1 when it rejects any update, and 0 otherwise.

## § 2.6 Project directory

Given `--project <dir>`, pre-receive MUST read `specrail.toml` from `<dir>` in
each tip instead of from the root of its tree, and MUST take the spec root as
relative to `<dir>`. It MUST exit with status 2 when `<dir>` is absolute or
contains a `..` component.

# § 3 Client side

## § 3.1 Input

`specrail hook pre-push` MUST read the
`<local-ref> <local-sha> <remote-ref> <remote-sha>` lines that git passes to a
pre-push hook on stdin, and apply the server-side checks to updates of the
claim branch when pushing to the claim remote.

## § 3.2 Unknown remote tip

When the remote's tip of the claim branch is not present locally, it MUST
reject the push and suggest fetching first.

## § 3.3 Project directory

Given `--project <dir>`, pre-push MUST use the project whose `specrail.toml`
is in `<dir>` under the top of the working tree, instead of searching from the
working directory, and MUST exit with status 2 when `<dir>` holds no
`specrail.toml`.
