param([string]$Odin = 'odin')
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
& $Odin check $root '-thread-count:1'
if ($LASTEXITCODE -ne 0) { throw 'Normal History coordinate API failed to compile' }
$invalidTypes = @('Patch_New_Line', 'Patch_Pixel_Y', 'Patch_Old_Count', 'Patch_Line_Index')
for ($case = 1; $case -le $invalidTypes.Count; $case++) {
    $diagnostics = & $Odin check $root '-thread-count:1' "-define:HISTORY_COORDINATE_ERROR=$case" 2>&1
    if ($LASTEXITCODE -eq 0 -or ($diagnostics -join "`n") -notmatch ('Cannot assign value.*' + $invalidTypes[$case-1])) {
        throw "Expected a typed coordinate rejection for case $case; received $diagnostics"
    }
    Write-Output "PASS compile rejection: $($invalidTypes[$case-1])"
}
exit 0
