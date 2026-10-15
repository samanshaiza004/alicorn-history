# Alicorn History

A small read-only Git history browser built as a separate dogfood application
for [Alicorn](https://github.com/samanshaiza004/alicorn).

Phase 1 focuses on one architectural question: can a native Alicorn application
load a large, mostly-static data set asynchronously and then remain quiet when
nothing is happening?

History uses Alicorn's event-driven native host path: the Git worker publishes
owned results through an Odin channel and requests an opaque host wakeup. The
worker never knows about SDL, and the UI has no periodic tick callback. After
the initial result is rendered, the host can sleep until a window/input event
or a worker completion arrives.

The application uses the installed `git` executable for repository data. It
does not checkout, modify, stage, commit, merge, rebase, push, or contact a
remote. Git work runs on an app-owned worker; the worker never touches the
Alicorn runtime.

## Build

Initialize the pinned Alicorn dependency and run the app with a repository:

```powershell
git submodule update --init --recursive
.\tools\run.ps1 -Repository C:\path\to\repository
```

Use `-SelfTest` for parser, generation, and model tests. Use `-Smoke` for a
bounded native run. The UI accepts a repository path as its first argument too:

```text
alicorn-history C:\path\to\repository
```

On macOS or another Unix-like host, use the native shell wrapper. It resolves
Odin from `ALICORN_ODIN` or `PATH`, initializes the pinned Alicorn submodule,
builds under `out/`, and forwards the repository and host flags:

```sh
ALICORN_ODIN=/path/to/odin ./tools/run.sh /path/to/repository
./tools/run.sh /path/to/repository --smoke --select-first
./tools/check.sh /path/to/repository
```

Platform validation records:

- [macOS validation](MACOS_VALIDATION.md)
- [Windows validation](WINDOWS_VALIDATION.md)

The Windows record covers a local build, native launch, selected-commit detail
and patch loading, and a true-idle proof. This repository does not currently
run Windows CI.

## Experimental folding projection — Alicorn #50

Enable the binary block projection explicitly:

```powershell
.\tools\run.ps1 -Repository C:\path\to\repository -Folding
```

The executable and Unix wrapper also accept `--folding`. A hunk header has a
Collapse/Expand control; its collapsed body becomes one expandable placeholder.
Select a source row using its gutter marker. The selection keeps the same
source identity when its hunk is hidden, and reappears on expansion. Fold
controls stay visible while the code is horizontally scrolled.

The view preserves the top source row and fractional row offset across folds.
When that row is hidden, it resolves to its hunk placeholder until expanded.
Later scrolling or explicit hunk navigation replaces that intent. Selection
here is by source row; the feature does not provide byte-range text selection.

The UI owns a compact projection over immutable parsed hunks. Background Git
results still pass the existing request-generation checks before adoption.
Public source, display, hunk and pixel queries use distinct coordinate types;
line numbers are one-based and display rows/hunk indexes are zero-based. No
tree lock or shared mutable projection is introduced. The worker's expanded
display array is released after compact preparation succeeds; a preparation
failure retains the existing display fallback.

This is a dogfood of fixed blocks with a binary summary directory. Whole-hunk
folding updates existing blocks, including hunks crossing multiple blocks.
It does not require general B+ tree insertion, deletion, or balancing. Findings,
measurements, and remaining gates are in [the validation record](research/folding-projection.md).

Run the focused correctness and type contracts, or the bounded Windows native
profile (one compiler thread and one native process at a time):

```powershell
.\out\alicorn-history.exe . --self-test-folding
.\tools\check_folding_types.ps1
.\tools\profile_folding.ps1
```

`--self-test` also includes the folding checks. The native profiler uses the
real scroll-change patch at History `3a22f38`, runs explicit finite scheduled
actions, and captures actual rendered viewports. Profiling callbacks are enabled
only by its command-line modes; ordinary application use has no periodic tick.

The positional directory selects the Git repository to inspect. Test fixtures
come from the History source checkout, independently. By default, tests resolve
`research/fixtures` from the process working directory; pass `--fixture-root`
when launching from elsewhere:

```powershell
.\out\alicorn-history.exe C:\path\to\another-repository --self-test --fixture-root C:\path\to\alicorn-history
```

## Phase 1–5 scope

- repository path and current branch summary;
- asynchronous `git log` loading;
- filterable, keyed, fixed-height virtual commit list;
- mouse and keyboard selection;
- asynchronous commit details and changed-file summaries;
- selectable changed files with asynchronous latest-wins patch loading;
- a read-only refs sidebar for local branches, remotes, and tags;
- ref navigation that selects the target commit and reveals it in the history list;
- deterministic first-parent unified patches from Git;
- structured hunk/line parsing with binary and mode-change fallbacks;
- virtualized, no-wrap diff rows with monospaced, shaded line-number gutters,
  retained horizontal scrolling, and previous/next hunk navigation;
- independent latest-wins history and detail request lanes;
- an independent latest-wins patch request lane;
- first-parent semantics for merge commit details;
- retained scroll-region routing for the history and detail panes;
- full-snapshot commit-DAG lane assignment with a GPU-rendered gutter aligned
  to the virtualized commit rows;
- marker-only graph presentation while filtering, so compacted rows never
  imply fabricated parent connections;
- explicit refresh;
- no blocking Git command on the UI thread;
- no periodic application tick while idle;
- a blocking worker signal rather than an idle polling loop;
- bounded, nonblocking result delivery during shutdown;
- no write operations or network access.

The machine-readable Git log uses NUL-separated records (`git log -z`), and
the parser defensively ignores record-separator newlines so every parsed object
ID can be used directly in a subsequent Git query. Ref names and object IDs are
read from NUL-delimited git for-each-ref fields as part of the same history
snapshot as the commit log. Clicking a branch or commit-pointing tag selects
its commit and clears a filter if needed to reveal it; symbolic remote HEAD
aliases and tags that do not resolve directly to a commit are not selectable.
Patch commands disable user diff helpers and interpret Git-provided paths
literally. Merge changes are shown relative to the first parent; root commits
compare against the empty tree. Ref navigation never changes repository state.

The commit graph is derived from the same full commit snapshot and parent IDs
used by the detail view. The lane model is UI/GPU independent and is built on
the Git worker; the visible viewport is projected into a small set of local
line segments and commit markers. Its geometry surface shares the commit
virtual list's retained scroll region, clipping, row height, and fractional
position. While a text filter compacts the history, only commit markers are
shown: edges are omitted rather than rewriting Git topology or connecting
non-adjacent matches.

The diff viewer is deliberately not a code editor: it has no syntax
highlighting, editing, staging, checkout, or write operations. It is a
structured, virtualized unified-patch view intended to pressure large text,
horizontal scrolling, independent async selection, and true idle behavior.

Phase 5 completes the intended read-only dogfood scope. History now covers
asynchronous repository data, refs, commit details, unified patches, and a
retained GPU commit graph. Further Git-client features are deliberately out of
scope; the remaining value should come from a different dogfood workload.
