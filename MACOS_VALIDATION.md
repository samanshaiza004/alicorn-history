# Alicorn History macOS Validation

Status: **REVISE**

The History application builds and runs on this physical Apple Silicon Mac
with the pinned Alicorn runtime and SDL 3.4.16. The native Metal, Retina,
asynchronous Git, retained scroll, and idle/wakeup paths are proven by the
checks below. Manual keyboard, resize-between-displays, and real IME sessions
remain to be performed by a human on the desktop, so this report does not yet
claim the complete cross-platform dogfood gate.

## Baseline

```text
repository:        alicorn-history
base commit:       6ca8c476a8ef6cfb9e29d363e31f323fe8929870
branch:            port/macos-history-6ca8c47
working tree:      clean before changes
vendor/alicorn:    165eb5414021e0fc6ca711c7f89e6fd9a0f00cdb
macOS:             27.0 (26A428)
machine:           Apple Silicon arm64 MacBook Air (T8103)
Xcode developer:   /Applications/Xcode.app/Contents/Developer
clang:             Apple clang 21.0.0
Odin:              dev-2026-09-nightly:a2fb372
SDL3:              3.4.16 (Homebrew; runtime linked by Odin distribution)
window:            1200 x 800 logical
drawable:          2400 x 1600 physical
pixel density:     2
display scale:     2
```

The current validation branch repins the vendor submodule to Alicorn
`165eb54`, which contains the retained horizontal-scroll fix and the native
dialog host service used by this app.

## Tests and native runs

```text
ALICORN_ODIN=... ./tools/check.sh /Users/keina/dev/alicorn-history
    PASS — History parser, generation, worker-shutdown, patch, real-Git, and
           retained view layout/focus tests

./out/alicorn-history --self-test /Users/keina/dev/alicorn-history
    PASS — Alicorn history tests

./tools/run.sh ... --smoke
    PASS — SDL 3.4.16, Metal, 9 real commits, 26 submissions, 26 retired

./tools/run.sh ... --smoke --select-first
    PASS — selected commit, asynchronous detail/patch lanes, 13 submissions,
           13 retired, max frames in flight 2

./tools/run.sh ... --select-first --diagnostics --capture-after=1
    PASS — diagnostics JSON, inspector text, and Retina screenshot written
    output: out/history-diagnostics-final/

./tools/run.sh ... --select-first --idle-proof-seconds=2
    PASS — 13 submissions, 13 retired, 98 event waits, 3 application wakeups,
           no periodic application tick

vendor/alicorn/tools/check.sh
vendor/alicorn/tools/bench.sh
vendor/alicorn/tools/native_sdl_gpu.sh
    PASS — current Alicorn foundation suite, benchmarks, and retained Metal
           compositor on this same host
```

The native host selected `metal` from an explicit Darwin request. The final
diagnostics capture reported 64 retained nodes, six built frames, presentation
revision equal to submitted revision, and no inspector hard error. The
inspector showed the history scroll region at `(20,216) 484x564` and the patch
scroll region at `(532,514) 648x266`, confirming that the detail pane is a
sibling beside the commit list and that the patch viewport is inside it.

The final capture was also visually inspected after converting the host PPM
artifact to PNG. It showed the selected commit, changed-file list, and a
rendered unified patch in the corrected two-pane layout.

## Native dialog services gate

History now exposes `Open Repository...` and Ctrl/Cmd+O through the public
Alicorn host service. The request is an asynchronous SDL 3.4.16 open-folder
dialog; its callback deep-copies paths and errors before waking the Alicorn
main thread. A second request is rejected while one dialog is active. The
selected folder is validated by the existing Git worker, and an invalid
candidate leaves the currently displayed repository and history intact.

```text
./tools/dialogs_test.sh
    PASS — headless fake backend: accepted, cancelled, callback ownership,
           reopen-after-completion, and busy rejection

./tools/run.sh ... --smoke
    PASS — production History build against vendor/alicorn 165eb54,
           SDL 3.4.16, Metal, 2 submissions, 2 retired
```

The real macOS folder panel has not yet been manually accepted/cancelled in
this report. Its native callback, shutdown ownership, Unicode/path copying,
and cross-thread-to-main-thread delivery remain manual desktop checks.

## Fixes made

### Close the list panel before opening the detail panel

Symptom: the detail pane was accidentally nested under the left commit-list
panel. The runtime reported `unbalanced container or identity scope`, the
right-hand patch region could resolve to zero height, and detail content was
laid out below the visible viewport.

Root cause: `history_build` opened `history-list-panel` but did not close it
after `history-scroll` before opening `history-detail-panel`.

Change: added the missing `container_end` at the list/detail boundary.

Regression: `history_test_view_layout_and_focus` verifies that the retained
detail panel is beside the list and both remain within a 1200x800 viewport.
Native diagnostics now complete without a hard error.

### Give the filter deterministic initial focus

Symptom: a new History window did not guarantee a keyboard-ready focus owner.

Change: the first description pass focuses the filter through Alicorn’s public
runtime API. The native host’s existing Tab/Shift-Tab and Enter/Space handling
then applies to the filter, Refresh button, commit rows, and file rows.

Regression: the same view test verifies filter focus and that focus traversal
has a next target.

### Add Unix/macOS developer paths

Added `tools/run.sh` and `tools/check.sh`. They resolve Odin from
`ALICORN_ODIN` or `PATH`, initialize the pinned submodule, build into `out/`,
forward repository/host arguments, and preserve the existing Windows
`tools/run.ps1` workflow.

No package-manager invocation or user-specific path was added to the normal
scripts.

## Boundary and platform contract

History uses only the intended public Alicorn application boundary:

```text
vendor/alicorn/native/sdl_gpu.Application
vendor/alicorn/native/sdl_gpu.Run
vendor/alicorn/runtime public UI/runtime APIs
```

It does not import SDL GPU handles, renderer internals, text internals, or
retained renderer maps. SDL video, event pumping, text-input synchronization,
window metrics, GPU command encoding, and shutdown remain on the native main
thread. Git work runs on an app-owned worker and returns copied results through
the host wakeup boundary.

The dialog service is also host-owned. History receives only
`Application_Services.dialogs`, never an SDL window or file-dialog handle.
Dialog completion callbacks are serialized onto the same application thread
as all other History state changes.

The application has no periodic tick callback. It woke three times for async
Git results and otherwise entered the host’s event wait path. Logical window
coordinates remain separate from the 2x physical Metal drawable; the app’s
layout, scroll, and input model stays logical.

## Unverified areas

```text
real macOS IME preedit/candidate/commit session: not manually exercised
manual typing, Tab/Shift-Tab, Enter/Space, and pointer selection: not manually exercised here
manual aggressive resize/minimize/restore sweep: not exercised here
moving between displays with different scale factors: no second display tested
physical Windows run against this exact History commit: not available here
10–20 minute interactive soak: not run; bounded smoke and idle proof only
long-term allocator/GPU-resource soak: not run
```

The first unmodified native probe once returned 139 before producing the final
summary, but repeated independent runs, an LLDB run, selected-commit runs, and
the final diagnostics capture all completed successfully. It is recorded as a
transient/unreproduced probe result, not as a claimed application failure.

## Recommendation

**REVISE** — the macOS native foundation and History rendering/data path are
working on this machine, and the concrete app hierarchy bug is fixed. Complete
the short manual interaction/resize/IME pass and a longer soak before calling
Windows + macOS dogfood fully closed.
