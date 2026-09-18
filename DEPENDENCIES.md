# Dependencies

## Alicorn

`vendor/alicorn` is a Git submodule pinned to a known Alicorn commit. The app
uses only the public runtime and reusable native host packages.

## Odin and SDL3

The Windows runner uses the SDL3 DLL shipped with the selected Odin
distribution and copies it beside the executable.

## Git

The installed `git` executable is the only Git backend. The app never writes
to a repository and does not use GitHub or another network service.
