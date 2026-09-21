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

## Phase 1–3 scope

- repository path and current branch summary;
- asynchronous `git log` loading;
- filterable, keyed, fixed-height virtual commit list;
- mouse and keyboard selection;
- asynchronous commit details and changed-file summaries;
- selectable changed files with asynchronous latest-wins patch loading;
- deterministic first-parent unified patches from Git;
- structured hunk/line parsing with binary and mode-change fallbacks;
- virtualized, no-wrap diff rows with fixed line-number gutters and retained
  horizontal scrolling;
- independent latest-wins history and detail request lanes;
- an independent latest-wins patch request lane;
- first-parent semantics for merge commit details;
- retained scroll-region routing for the history and detail panes;
- explicit refresh;
- no blocking Git command on the UI thread;
- no periodic application tick while idle;
- a blocking worker signal rather than an idle polling loop;
- bounded, nonblocking result delivery during shutdown;
- no write operations or network access.

The machine-readable Git log uses NUL-separated records (`git log -z`), and
the parser defensively ignores record-separator newlines so every parsed object
ID can be used directly in a subsequent Git query. Patch commands disable user
diff helpers and interpret Git-provided paths literally. Merge changes are
shown relative to the first parent; root commits compare against the empty
tree. Refs and the DAG remain intentionally separate phases.

The diff viewer is deliberately not a code editor: it has no syntax
highlighting, editing, staging, checkout, or write operations. It is a
structured, virtualized unified-patch view intended to pressure large text,
horizontal scrolling, independent async selection, and true idle behavior.
