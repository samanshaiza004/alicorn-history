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

## Phase 1 scope

- repository path and current branch summary;
- asynchronous `git log` loading;
- filterable, keyed, fixed-height virtual commit list;
- mouse and keyboard selection;
- explicit refresh;
- no blocking Git command on the UI thread;
- no periodic application tick while idle;
- bounded, nonblocking result delivery during shutdown;
- no write operations or network access.

Commit details, diffs, refs, and the DAG are intentionally later phases.
