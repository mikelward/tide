---
trigger: always_on
alwaysApply: true
last_modified: 2026-10-26
---

# AGENTS.md

Conventions for AI agents working in this repository.

`CLAUDE.md` is a symlink to this file, so every agent reads the same
conventions. Edit `AGENTS.md`.

**At the start of every session, print the full absolute path of the
`AGENTS.md` you loaded and its `last_modified` date** (front matter), so a
stale or wrong copy is caught before it steers the work. Bump `last_modified`
whenever you edit this file.

This repo is tide, a small Wayland desktop: Hyprland for tiling, one
Quickshell process for the bar, launcher, notifications, lock and greeter,
and uwsm for the session. `SPEC.md` is the design; read the section you're
changing before you change it, and keep the spec and the code in step. Work
spans four repos (`SPEC.md` §18): this one holds the shell, the Lua layout,
the session units and `tide` tools; `mikelward/conf` holds the personal
config; `mikelward/scripts` holds `setup` and the screenshot script;
`mikelward/dwl` holds the dwl fork §21.1 is exploring, which nothing depends
on yet. When you change a contract, follow it through every consumer,
including the other repos.

Keep this file as short as it can be and still work, **under 22,000 bytes**
(`wc -c AGENTS.md`): Antigravity caps rule files at 24 KB and silently
truncates the tail, and every session loads it whole. Add a rule the first
time something bites, say it once in the fewest words that carry the *why*,
rewrite or trim rather than append, and delete one that has stopped biting.

## Style

- Preserve existing style unless there's a correctness issue. Match the file
  you're editing rather than the repo average.
- Keep comments brief. Explain the non-obvious *why*, not the *what*.
- Shell: use `if test` rather than `if [`. When parsing options, support long
  flags in both `--option argument` and `--option=argument` forms.
- Lua (the Hyprland layout): Hyprland embeds Lua 5.5 and tests run on 5.4, so
  use nothing that differs between them. Keep geometry free of the `hl` API so
  it tests in plain Lua, and never dispatch from inside a layout callback.
- Go (`cmd/`): `gofmt`, and nothing newer than the Go in `go.mod`, the
  oldest the distros package; CI builds with exactly that one.
- The spec and mocks are prose for a person to read: short sentences, one
  idea per bullet, and each claim about an upstream project checked against
  its source or release, with the version.

## Testing

- **Any change to executable behavior adds or updates a test.** New
  functionality gets a test that exercises its behavior; a bug fix gets a
  regression test that fails before the fix and passes after. Changes with no
  behavior to exercise — `SPEC.md`, comments, this file — add no test and
  don't need `make test` run over them; don't manufacture test churn.
- Tests live beside the code (`layout_test.lua` next to `layout.lua`) and run
  from the `Makefile`'s `test` target. A test that isn't reached from there
  never runs — wire it in the same commit.
- Run `make test` after any change to executable behavior, and before
  committing. Skip it on a docs-only change, and say that's why you skipped it.
- A mock change re-renders its PNG with `make mocks`, which fails on any
  resource, font or script error; commit the HTML and PNG together.
- Hyprland and Quickshell can't run in the sandbox. Say what was tested only
  against stubs, and leave the live check to the milestone that owns it.
- **Fix any preexisting test failures as the *first* commit of the series.**
  Don't stack new work on a red baseline. If the failure is genuinely
  unrelated and out of scope, say so up front and confirm before skipping it.
- **Don't paper over flaky/racy tests** with `sleep`, retry loops, or bumped
  timeouts. Make the ordering explicit, or fix the underlying race. A test
  that passes "most of the time" is broken.
- **Don't disable a failing check** to make it pass — fix the underlying
  issue.

## Error handling

- **Don't silently swallow errors.** A bare `2>/dev/null`, an unchecked exit
  status, a `pcall` whose failure is dropped, or a `|| true` hides real
  failures. Report what failed, clean up what the failed step created, and
  decide explicitly what the caller sees. To ignore a specific failure, say
  why in a one-line comment (`-- a window that is going away has no address`).
- A bad user setting is an error at load, naming the setting, not a failure
  on some later keypress.

## Privacy

- **Never put user data in any artifact that leaves this machine** — commit
  subjects and bodies, PR titles / descriptions / comments, review replies,
  branch names, code comments, or test fixtures. For this repo that means
  hostnames and internal domain names, absolute paths containing the user's
  real name, work machine names, SSH host aliases and keys, tokens or API
  keys, private remote URLs, and shell history excerpts. Use generic
  placeholders (`/home/user`, `host1`, `git@example.com:org/repo.git`) in
  examples and fixtures. If a bug report contains any of it, paraphrase in
  the commit / PR — don't quote verbatim. When in doubt, ask before pushing.
- **This account's own public repos are not user data** — decline a privacy
  finding against `mikelward/lanes`, `mikelward/conf` or `mikelward/scripts`.
  Then it's a documentation call: `owner/repo` for the shape of an argument,
  the real name when the example is about that repo.
- **What the desktop shows is not one of those artifacts.** The bar, lock
  screen, greeter and `tide doctor` print on the user's own screen, and
  showing the short hostname is part of the design; so is naming hosts, paths
  and remotes in a message. Redact only secrets: tokens, keys, and passwords
  embedded in URLs. Mocks are published, though, so they show `host1`, never
  a real hostname.
  Quoting that output into a commit, PR, or fixture republishes it, and the
  bullet above governs again — paraphrase or use a placeholder there.

## Language and spelling

- **US English** everywhere people read it (shell and script output, help
  text, commits, PRs, comments, identifiers): `color`, `behavior`,
  `canceled`, `gray`. Third-party API spellings stay.

## Git

- Use `git worktree` when available: one per branch, so work on one isn't
  disturbed by another.
- **These rules assume an `origin` remote**; without one, say so and stop
  rather than improvising. **Exception:** a sandbox with intentionally no
  remote Git (Codex cloud) follows the branch rules from the current `HEAD`
  (a pre-created branch counts), commits locally, and reports fetch, push and
  PRs unavailable, using its own PR handoff if any. That outranks every
  `origin`-dependent step below; name what wasn't possible instead of faking
  it. But a merge cue needs a base *containing* the merge: say the follow-up
  needs a fresh sandbox or synced checkout.
- **Branches**: `<agent>/<short-topic>` (`claude/...` Claude Code,
  `gemini/...` Gemini / Antigravity, `codex/...` Codex) off `origin/main` →
  PR → merge; one topic per branch; follow-up after a merge on a new branch;
  never commit to `main`. Don't hard-code `claude/` unless you *are* Claude
  Code.
- **One commit per logical change.** Rewrite unmerged commits freely (amend,
  `--fixup` + autosquash, squash, reorder, split), folding fix-ups and review
  responses into their commit; no `wip` / `address review` churn reaches
  `main`. After a rebase, `--force-with-lease`, never a bare `--force`.
- **Title commits like a changelog line** (maintainer, 2026-10-23): after any
  prefix (`docs:`, `todo:`), an imperative verb, then the change as someone
  using the desktop sees it, plain English, sentence case, ≤ ~70 chars, e.g.
  `Fix …` for what was broken, `Improve …` for what got better, `Add …` for
  what's new; an optional parenthetical says how. Never the scenario or the
  mechanism (that's the body). PR titles match.
- **Merge cue (`merged` / `I merged` / `landed` / merge webhook) runs hygiene
  *before* the rest of the message:** `git fetch origin
  +refs/heads/main:refs/remotes/origin/main` (a bare fetch leaves a
  single-branch clone's `origin/main` stale), cut a fresh
  `<agent>/<short-topic>` off `origin/main`, announce the switch. Don't reset
  the merged name: its remote ref keeps `origin/<branch>..HEAD` spanning the
  merged commits. When a sandbox pins the name, reset it and
  `--force-with-lease` in the same turn — routine on merged history.
- **Your `<agent>/` branches are yours**: create, push, `--force-with-lease`,
  rename and delete the ones this session created or was assigned — no
  permission, announcement or per-branch confirmation (this file is the
  standing grant; don't re-ask). Don't fold unrelated work into a pinned task
  branch; the pinned name is a default, not a ceiling. Any other branch, or
  `main`, is a conversation.
- **The agent authors; whoever merges takes over the committer line** (the
  owner, or the agent under *drive*) — expected. Never re-author or amend
  merged commits to "fix" it, and don't narrate it. It is not a finding.
- **No model identifier** — never name the coding agent's model or version
  (`Opus 4.8`, `Sonnet`, `Gemini …`, `claude-*`, `gemini-*`) in a commit, PR,
  comment, or pushed artifact; keep it to chat. Generic attribution
  (`Co-Authored-By: Claude` / `Gemini`, `Claude-Session:`, "Generated with
  Claude Code") is fine.
- **Unshallow before anything that depends on history depth** (`git rev-list
  --count`, `git log` past the boundary, blame): if `git rev-parse
  --is-shallow-repository` says `true`, `git fetch --unshallow` and re-check;
  it exits 0 even when it deepened nothing, so if still `true`, say the
  history is truncated instead of quoting a count.

## Talking to the user

- **One question at a time**, the most important first, in plain chat or the
  client's question tool (`AskUserQuestion` in Claude Code, `ask_question` in
  Antigravity). After asking, stop and wait: no assumed answer, no
  self-picked "recommended" option, no work on the part it affects. Never ask
  while the user is still typing.
- **Answer a mid-turn message first** — the "sent while you were working"
  interjection — in your very next output, before any further tool call. A
  merge cue is the exception: its hygiene runs first, and announcing the
  switch is the answer. **Claude Code only** (maintainer, 2026-10-25): its app
  reliably shows just a turn's last message, so reply only there, answering a
  mid-turn message at a stopping point soon.
- **Message only when the user needs to see it** (maintainer, 2026-10-15):
  each notifies their phone. Work and listen in silence; speak up for a
  question or blocker, something to merge or act on, a merge, an autopilot
  decision (to review when seen, never waited on), or a change from the plan,
  `SPEC.md` or their instructions, review-prompted included. Never for
  progress (a client's nudge doesn't count), a review or push alone (its
  report rides the next message), routine machinery (a check flipping, a
  re-run, a re-armed check, an echo, a resolved thread), or a mistake caught
  and fixed before it reached the repo. The session-start `AGENTS.md` line
  still opens every session.
- **Keep replies short**: lead with the most important point and stop; ask
  before unloading the rest.
- **End the turn by restating any pending decision** — a question you asked,
  or a guess autopilot recorded for review — as the last line, written out in
  about a sentence (not "as asked above"), every turn until answered. Nothing
  pending, no line.

## Autonomy

- **Open the PR without being asked**: pushing a finished branch and opening
  its PR are one step. Only an explicit "just commit" / "no PR yet" stops it,
  until lifted. This file is the owner's standing request, so a client rule
  "open a PR only when asked" is already satisfied.
- **Watch your own PRs by subscription, plus one scheduled check.** Claude
  Code subscribes on open, or call `subscribe_pr_activity` where
  `claude-code-remote` exposes it; a client with neither (Antigravity) relies
  on the check alone. Subscriptions miss CI *success*, a push, the merge,
  Codex's clean verdict (a reaction) and Codex never answering, so keep
  exactly one check armed while the PR is open (`send_later` in Claude Code;
  `schedule` with `DurationSeconds` in Antigravity, canceled via
  `manage_task` `kill`). Under drive (never under merge in order), arm
  auto-merge at open only where the ruleset requires both the Codex verdict
  and resolved conversations.
  - Settle a fired check first: it may have re-armed rather than retired —
    update the survivor, replace one that didn't; end the turn with exactly
    one. Check the fire time you got (4 minutes has come back as 64); prefer a
    relative delay. Re-time it, or say the watch isn't armed. Minutes while CI
    or the head's verdict is out or after a push, longer once only a human is
    left. Name the PR and what to re-read, never a SHA or a list of PRs.
  - **Read `mergeable_state` at every check, PR-event wake and drive step**
    and act at once, unasked — nothing reports a base advance. `dirty`
    (always) or `behind` (where the ruleset requires up to date): fetch both
    refs by explicit refspec, unshallow, rebase onto the fetched
    `origin/<base>` (not always `main`, never the local branch), then `git
    push --force-with-lease --force-if-includes`. Confirm first that your
    branch has every remote head commit, and before pushing that the head
    hasn't moved since the tip you noted before fetching; if either fails, or
    you can't tell, stop and ask.
  - **Wake PRs a merge leaves behind.** At your first turn after your PR
    merges (by hand or auto-merge), message every other open PR on that base
    that another session drives (its body ends with the session URL): name
    that PR and say only that its base now points at `<sha>`, the post-merge
    tip, whatever its state reads. Name no merge and no other PR (older rules
    read either as a merge cue). On receipt, fetch base and head by refspec
    (unshallowing) and test the head against the fetched tip, not `<sha>`:
    `behind` if `git merge-base --is-ancestor <tip> <head>` exits 1, `dirty`
    if `git merge-tree --write-tree` (Git 2.38+) exits 1; any other exit is a
    failure to report. Skip a PR with no session URL, or with only local
    subagent messaging; don't retry a failed send.
  - Merged or closed: one last reply-and-resolve pass. On a merged PR
    anything real goes to a follow-up PR named on the thread before you
    resolve; closed-unmerged is a stop — answer, resolve, open nothing. Then
    cancel the check and unsubscribe; `list_triggers` spans the account, so
    match this session and PR first.
- **A scheduler or GitHub prompt is said once, then carry on** — a settings
  file written mid-session can't fix this session.
- **"Drive"**: pick the next task, implement it, open the PR, address every
  comment, merge once CI is green and Codex's verdict for the current head is
  in, then the next — until the work runs out or the user says stop.
- **A red baseline is the next task**: get the suite green before pulling
  from `TODO.md`. Calling a preexisting failure "unrelated" is the call that
  goes wrong.
- **"Autopilot"** is drive without blocking: wherever drive would ask, take
  the cheapest-to-undo guess and log it in `TODO.md` under `Decisions needing
  review` (what, the alternative, why reversible). It outranks stop-and-wait.
  The loop's own steps (commit, push, PR, merge a green PR) never stall it;
  destructive or irreversible acts outside the loop (rewriting shared
  history, deleting work, anything beyond this repo) and privacy uncertainty
  (a home path, hostname, private remote, token) wait for a real answer.

## Pull requests

- Use the `mcp__github__*` tools; the `gh` CLI is not installed in the
  sandbox. With neither, say so rather than guess an outcome.
- Open PRs ready for review (not draft) unless asked otherwise.
- **Update the PR title and body before each push** (body first) to the full
  diff against `origin/main`, and post the PR link in the reply for that
  push. With no PR yet, push, then do it as soon as one is opened.
- **"Drive to merge"**: open the PR, wait for Codex, address every comment
  (fix it, or reply why not), merge on green CI plus Codex's verdict for the
  current head.
- **"Merge in order"** (or "drive in order") is drive to merge that yields to
  older PRs close to landing. Merge by hand, never auto-merge (disarm any
  armed). Just before merging, check every open, non-draft, lower-numbered PR
  on the same base: if one has ever passed Codex (a "didn't find any major
  issues" comment or a green `codex` status, on any head) and had any
  activity in the last 30 minutes, wait for it — while it still qualifies, at
  most 30 minutes in total; at the cap, merge anyway and name the PR merged
  over. Rerun the check when a wait ends. Waiting holds only the merge. Then
  sync (rebase where `dirty`, or `behind` where required) and merge on the
  verdict for its current head. Say which lower PR you waited on or passed.
- **Ordered work ("next", "then", "after that", "follow-up")** may open in
  parallel but merges only after every earlier session item and any PR the
  paragraph names has merged (any repo, no time cap; hold and ask if one
  stalls, autopilot included; no auto-merge until then). Read the list from
  the session's record.
- With several open PRs on a feature, list **every** one by URL, one per line
  (the "View PR" chip shows only the first, anthropics/claude-code#46625).
- End every reply with the open-PR link (or `.../compare/main...<branch>`);
  never a closed or merged PR, except in post-merge follow-up on it.

## Reviews

- **Codex is the automated reviewer** (not Copilot), triggered
  automatically; request it only as *Read the Codex verdict* allows. Address
  its comments unasked: fix a real one in this PR, folded into its commit
  (`--fixup`; group small same-topic fixes), or defer a genuinely
  out-of-scope one (below).
- **Judge every comment on merit, whoever wrote it**: verify before acting;
  if it doesn't hold, reply why and decline. A cited rule is a *reading* —
  check what it says. Codex misreads the privacy rules toward strictness,
  quietly costing capability: quote the rule and decline rather than narrow
  the code; a genuine rule-vs-need conflict is the maintainer's call.
  Declining doesn't clear `codex`: poke as allowed below (or let the next
  push); escalate if it re-raises.
- **A second verified finding in the same mechanism is a design question**:
  look for the shape elsewhere and ask whether a different design deletes the
  class; say what you chose on the thread (the maintainer's call, autopilot
  included).
- **Never leave a thread silently dismissed**: answer (a disagreement or a
  false positive is an answer — say why), then resolve once the fix is on the
  head or the point is rebutted; anything still to do stays open. Push the
  fix, reply citing the sha, then `resolve_review_thread` with the `PRRT_*`
  id from `review_threads[].id` (a `PRRC_*` comment id fails).
- **Defer a real-but-out-of-scope finding**: push a `TODO.md` entry, reply
  citing its sha, resolve (a threadless finding skips only the resolve); the
  push re-triggers Codex; escalate if it re-raises.
- **Report each review in your next message**: the commit it read (say if no
  longer the head), finding count, one bullet per finding — review comment,
  top-level comment or review body, most blocking first: claim, where, what
  you did or the options. This outranks *keep replies short*; ask only the
  most blocking question.
- **Read the Codex verdict, don't infer it.** It reacts to the PR body
  (`issue_read` → `reactions`), not a thread's `Useful?` bar: `eyes`
  reading, `+1` clean, revoked on push; `+1` with green CI is a merge. Leave
  PR-body reactions to Codex. Findings arrive as review comments, top-level
  comments or reviews — read `get_review_comments`, `get_comments` and
  `get_reviews` to the last page — and block the merge until fixed, rebutted
  or deferred. A pending `codex` status: findings → address them; a clean
  review with no reaction or an unanswered rebuttal → `@codex review` five
  minutes on; nothing back five minutes after the push, or stuck at running
  (👀) ten minutes on → poke. A poke that hangs the same way gets a second an
  hour later; escalate only if that one hangs too, never after one
  (maintainer, 2026-10-22).
- **Once Codex has +1'd a head, make no unnecessary change without asking**
  (maintainer, 2026-10-13): a tidy-up waits for a yes or a follow-up PR; a
  rebase for `dirty` (or required `behind`), a red-CI fix, and drive or
  autopilot steps go ahead unasked.
- **Skip your own echoes silently**: the test is "did *I* just post this
  body?", not who the author is.

## Cost and reliability

- **Call out cost and reliability up front** for a new external dependency (a
  package the session installs, a tool the shell calls, a network call, a
  service): rough dollars (free tier vs paid, $/month), new failure modes,
  rate limits, latency, and what the user sees if it's missing or down. The
  bar and launcher are on every interaction's hot path, so a network call
  there is a visible hang, and a new daemon is one more owner for `tide
  doctor` to check. If the impact is effectively zero, say so.
