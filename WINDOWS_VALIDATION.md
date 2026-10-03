# Alicorn History Windows Validation

Status: **PASS — local native build, self-tests, selected-detail smoke, and
true-idle proof completed on 2026-10-02.**

This closes the Windows build/run gap for the Alicorn dogfood boundary gate.
The repository does not currently have Windows CI; these results are a
reproducible local validation record.

## Environment

```text
History repository:  b3fc21d9bb13806d875cbcc284f65de385d49cb9
vendor/alicorn:      cc0274b92aff744466847c5058984205c721bb25
Windows:             Windows 10 Home 22H2, build 19045.6466
CPU:                 AMD Ryzen 5 7600X, 12 logical processors
Odin:                dev-2026-09-nightly:a2fb372
SDL3:                3.4.2
GPU driver:          Direct3D 12
```

The working tree was clean before the validation. The Windows runner built the
native executable with the pinned Alicorn submodule and staged the SDL runtime
DLL next to it.

## Commands and results

Run from the History repository root, replacing the repository argument when
you want to inspect a different Git repository:

```powershell
.\tools\run.ps1 -Repository C:\Users\saman\dev\alicorn-history -SelfTest
.\tools\run.ps1 -Repository C:\Users\saman\dev\alicorn-history -Smoke
.\out\alicorn-history.exe C:\Users\saman\dev\alicorn-history --smoke --select-first
.\out\alicorn-history.exe C:\Users\saman\dev\alicorn-history --select-first --idle-proof-seconds=2
```

Results:

- `-SelfTest`: **PASS** — History parser, generation, worker-shutdown, patch,
  real-Git, and retained view tests.
- `-Smoke`: **PASS** — native SDL window launched on Direct3D 12, loaded 26
  commits, and shut down cleanly (3 submissions, 3 retired).
- `--smoke --select-first`: **PASS** — selected-commit detail and patch paths
  loaded for the 26-commit repository; 8 History builds and 7 GPU submissions
  completed and retired cleanly.
- `--select-first --idle-proof-seconds=2`: **PASS** — loaded the same 26-commit
  history and selected detail/patch, then completed the two-second idle proof
  with 4 host event waits, 3 application wakeups, and no application tick.

All four commands exited with code 0. SDL reported version 3.4.2 and selected
`direct3d12`; no backend error was reported.

## Scope

This verifies the Windows build, test executable, native window startup and
shutdown, real-Git history loading, selected commit detail/patch loading, and
event-driven idle behavior. It is a bounded smoke run, not a manual
certification of Windows dialogs, IME, DPI transitions, or extended interactive
use. The macOS validation record is in [MACOS_VALIDATION.md](MACOS_VALIDATION.md).
