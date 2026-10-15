param([string]$Odin = 'odin', [ValidateRange(1, 5)][int]$Runs = 3, [switch]$NoBuild)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$binary = Join-Path $root 'out/alicorn-history.exe'
if (-not $NoBuild) {
    . (Join-Path $root 'vendor/alicorn/tools/common.ps1')
    $kit = Get-AlicornAccessKit
    $flags = '/LIBPATH:' + (Split-Path -Parent $kit.Library) + ' bcrypt.lib ntdll.lib propsys.lib runtimeobject.lib uiautomationcore.lib userenv.lib ws2_32.lib'
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'out') | Out-Null
    & $Odin build $root "-out:$binary" '-thread-count:1' '-o:speed' "-extra-linker-flags:$flags"
    if ($LASTEXITCODE -ne 0) { throw 'History native build failed' }
    $odinExecutable = (Get-Command $Odin).Source
    Copy-Item -LiteralPath (Join-Path (Split-Path $odinExecutable) 'vendor/sdl3/SDL3.dll') -Destination (Join-Path $root 'out/SDL3.dll') -Force
}
$rawPath = Join-Path $root 'research/native-folding-windows-2026-10-14.txt'
$warmPath = Join-Path $root 'research/native-folding-active-stages-windows-2026-10-14.json'
$records = @()
Set-Content -LiteralPath $rawPath -Encoding utf8NoBOM -Value @(
    "History binary block folding; $(& $Odin version)",
    "Windows $([Environment]::OSVersion.Version); -o:speed -thread-count:1; $Runs sequential paired native runs",
    'Real 3a22f38 history_view patch; 38 finite scheduled steps; three seconds per process.',
    'Ordinary build p95 excludes GPU work; active stage CPU sums build + GPU encoding + submission.',
    'Warm active records are 29 ordinary scroll presentations, excluding the final view/capture presentations.'
)
foreach ($file in (Get-ChildItem -LiteralPath $root -Filter '*.odin' | Sort-Object Name)) {
    Add-Content -LiteralPath $rawPath -Encoding utf8NoBOM -Value "source_sha256 $($file.Name) $((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)"
}
for ($trial = 1; $trial -le $Runs; $trial++) {
    foreach ($mode in @('expanded', 'folding')) {
        $log = Join-Path $root "out/profile-$mode-$trial.txt"
        $errLog = Join-Path $root "out/profile-$mode-$trial-error.txt"
        $argumentLine = '"' + $root + '" --profile-' + $mode + ' --smoke --diagnostics --capture-after=2'
        $process = Start-Process -FilePath $binary -ArgumentList $argumentLine -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $errLog
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Native profile exceeded its 15-second process limit' }
        $output = Get-Content -LiteralPath $log
        if ($process.ExitCode -ne 0) { throw "Native $mode run failed: $output $(Get-Content -LiteralPath $errLog)" }
        Add-Content -LiteralPath $rawPath -Encoding utf8NoBOM -Value "trial $trial mode $mode"
        Add-Content -LiteralPath $rawPath -Encoding utf8NoBOM -Value $output
        $captureLine = $output | Where-Object { $_ -match '^alicorn_diagnostics path (.+?) inspector ' } | Select-Object -Last 1
        if (-not $captureLine -or $captureLine -notmatch '^alicorn_diagnostics path (.+?) inspector ') { throw 'Missing native diagnostics capture' }
        $captureDir = Split-Path (Join-Path $root $Matches[1])
        $timeline = Get-Content -LiteralPath (Join-Path $captureDir 'timeline.json') -Raw | ConvertFrom-Json
        $active = @($timeline.samples | Where-Object { $_.work.app_builds -gt 0 -and $_.work.gpu_submissions -gt 0 })
        if ($active.Count -lt 31) { throw 'Native trace did not contain all ordinary presentations' }
        $warm = @($active[($active.Count-31)..($active.Count-3)] | ForEach-Object {
            [PSCustomObject]@{sample=$_.sample_index; build_ns=$_.timing_ns.application_build; encode_ns=$_.timing_ns.gpu_encode; submit_ns=$_.timing_ns.gpu_submit; active_cpu_ns=([long]$_.timing_ns.application_build+[long]$_.timing_ns.gpu_encode+[long]$_.timing_ns.gpu_submit)}
        })
        $sorted = @($warm.active_cpu_ns | Sort-Object)
        $p95 = $sorted[[Math]::Floor($sorted.Count*0.95)]
        $records += [PSCustomObject]@{trial=$trial; mode=$mode; capture=(Split-Path $captureDir -Leaf); ordinary_active_cpu_p95_ns=$p95; samples=$warm}
        Add-Content -LiteralPath $rawPath -Encoding utf8NoBOM -Value "native_ordinary_active_cpu trial $trial mode $mode samples $($warm.Count) p95_ns $p95"
        $output | Where-Object { $_ -match '^native_history|^native_projection_script|^native_projection_memory' }
        Write-Output "native_ordinary_active_cpu trial $trial mode $mode p95_ns $p95"
    }
}
$records | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $warmPath -Encoding utf8NoBOM
exit 0
