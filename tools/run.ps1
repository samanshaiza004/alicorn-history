param(
    [string]$Odin = $env:ALICORN_ODIN,
    [string]$Repository = '.',
    [switch]$Smoke,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
if (-not $Odin) { $Odin = 'odin' }
if ([IO.Path]::IsPathRooted($Odin)) {
    if (-not (Test-Path -LiteralPath $Odin -PathType Leaf)) { throw "Odin executable not found: $Odin" }
} else {
    $command = Get-Command $Odin -ErrorAction SilentlyContinue
    if (-not $command) { throw "Odin executable not found on PATH: $Odin" }
    $Odin = $command.Source
}

# The pinned native Alicorn host imports AccessKit on Windows. Reuse its
# versioned bootstrap and pass an absolute library path because this script
# runs from the History root, not from the Alicorn submodule root.
. (Join-Path $PSScriptRoot '..\vendor\alicorn\tools\common.ps1')
$AccessKit = Get-AlicornAccessKit
$AccessKitLibraryDirectory = Split-Path -Parent $AccessKit.Library
$AccessKitLinkerFlags = "/LIBPATH:$AccessKitLibraryDirectory bcrypt.lib ntdll.lib propsys.lib runtimeobject.lib uiautomationcore.lib userenv.lib ws2_32.lib"

New-Item -ItemType Directory -Force -Path 'out' | Out-Null
& $Odin build . "-extra-linker-flags:$AccessKitLinkerFlags" -out:out\alicorn-history.exe
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$odinRoot = Split-Path -Parent $Odin
$sdlDll = Join-Path $odinRoot 'vendor\sdl3\SDL3.dll'
if (-not (Test-Path -LiteralPath $sdlDll -PathType Leaf)) { throw "SDL3.dll was not found at $sdlDll" }
Copy-Item -LiteralPath $sdlDll -Destination 'out\SDL3.dll' -Force

$args = @($Repository)
if ($Smoke) { $args += '--smoke' }
if ($SelfTest) { $args += '--self-test' }
& .\out\alicorn-history.exe @args
exit $LASTEXITCODE
