# dwl or sway

tide has two compositors that can run it:

- [tidewm](https://github.com/mikelward/tidewm) is a fork of dwl.
- [tidesway](https://github.com/mikelward/tidesway) is a fork of sway 1.12.

This compares them as a base for tide on four things: speed, the cost of keeping up with
upstream, bugs, and how easily each syncs with upstream on its own. It was written on
2026-11-09, against tidewm `1f47ac2` and tidesway `d55663ec`.

The earlier experiment, stock sway plus an IPC helper, is in tidewm's
[`SWAY.md`](https://github.com/mikelward/tidewm/blob/main/SWAY.md). tidesway's numbers are in its
[`MEASUREMENTS.md`](https://github.com/mikelward/tidesway/blob/main/MEASUREMENTS.md).

## Where it stands

**tidewm stays the main base.** tide's defining feature is workspaces that span every
monitor. tidewm has them natively. On sway they're a workaround, and that's where
tidesway's bugs cluster.

sway wins if tide comes to lean harder on sway's tools: bars like waybar, notification
daemons, `nwg-displays`, and sway configs that work unchanged.

Run both day to day before deciding for good.

## Speed: a tie

These figures are from the same CI runner: median and 95th percentile, in ms, over 50
runs.

| | tidewm | tidesway |
|---|---|---|
| New window, first seen → final place | 0 / 0 | 0 / 0 |
| Layouts a new window passes through on the way | 0 | 0 |
| Closes showing a wrong frame | 0 of 25 | 0 of 25 |
| Workspace switch, command → reply | 0.19 / 0.25 | 0.68 / 1.3 |
| Workspace switch, command → screen settled | 1.6 / 2.9 | 0.97 / 1.5 |

Every figure is well under one frame (16.7 ms), so nobody will feel the difference.

## Keeping up with upstream: dwl is cheaper

| | tidewm | tidesway |
|---|---|---|
| Size | about 15k lines in all | about 51k lines of sway, plus 4.4k of tide's |
| Where tide's code sits | its own headers, included from `dwl.c` | `sway/tide/`, with hooks in about 44 of sway's files |
| How upstream comes in | merge dwl's `main` | rebase onto each sway release |
| Behind upstream today | 15 commits (dwl `main`, since 2026-09-29) | none on sway's `v1.12` branch; `master` is 55 ahead |

Several of tidesway's hooks are small, but they sit in sway's busiest code:
- transactions;
- arrange;
- seat focus;
- cursor hit-testing;
- output evacuation;
- IPC.

Each sway release means real rebase work there.

tidewm pays a different cost. It rebuilt sway's config syntax and IPC itself, and
keeping them matching sway is ongoing work.

## Bugs: mature sway, but tide's features collide with it

These are judgments, not counts.

- **sway's own code** is the least likely to surprise. It has years of daily use on
  many GPUs and monitor setups, and tools like waybar exercise its IPC daily.
- **dwl** is small and carefully reviewed, but fewer people run it, so its rarer paths
  get less exercise. One example: built with Xwayland support but run without an
  Xwayland binary, it crashed on exit. tidewm fixed this in `30174dd` (2026-11-03).
  dwl fixed it the same way in `f08d8b3` (2026-10-19), so there's nothing to send
  upstream. Ours drops out at the next merge.
- **tidewm's additions** are the newest and least used code: its IPC, config,
  workspaces, focus guard and output settings. Only its tests and its one user have
  run them.
- **tide's features on sway** kept colliding with sway's model:
  - split trees;
  - three kinds of fullscreen;
  - floating windows;
  - transactions;
  - X11.

  Codex found about 40 real bugs across tidesway's first PRs. Spanning workspaces
  alone drew 12, including two crashes. A third crash, in the pointer code, took
  down `GrantTest` until tidesway #11 fixed it.

## Syncing on its own: tidewm can, tidesway mostly can't

**tidewm can sync automatically.**
- dwl's `main` moves slowly: 15 commits in six weeks, nearly all small fixes.
- tidewm merges it, so history isn't rewritten.
- tide's code is in separate headers, so most merges touch only `dwl.c` lines tidewm
  never changed.

A weekly job could merge dwl's `main`, run the build and `make test`, and open a PR.
On a conflict or a failing test, it opens the PR anyway with the failure, or an issue
saying where it stuck.

**tidesway can't sync automatically.**
- It follows sway releases, a couple a year, and rebases onto each one, since tide's
  patches are kept one commit each.
- A rebase rewrites `main`, so it can't land as an ordinary PR, and the conflicts are
  in sway's busiest files.

What can be automated is noticing: a weekly check for a new sway release tag or a new
commit on the release branch, such as a point release's fixes. The check would open an
issue. Picking up a point release's fixes is a cherry-pick, which a PR can carry. A
new minor release stays a deliberate rebase.

## Tracking upstream

A weekly scheduled task does both jobs:

- **tidewm:** merge dwl's `main` on a branch, build with and without Xwayland, run
  `make test`, and open a PR, driven to merge like any other.
- **tidesway:** check `swaywm/sway` for a new release tag or new commits on the
  current release branch. Open a PR cherry-picking the release branch's fixes, or an
  issue for a new release.

This could be a GitHub workflow or a scheduled Claude Code session:

- **A workflow** needs a token or GitHub App with push and PR rights. A PR opened with
  the default token doesn't trigger CI, so the PR would need that token too. It can't
  resolve conflicts.
- **A scheduled session** opens the PR as the maintainer, so CI and Codex run as
  usual. It can resolve simple conflicts and fix what a merge breaks. It costs one
  session a week.
