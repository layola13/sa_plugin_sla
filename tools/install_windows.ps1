[CmdletBinding()]
param(
    [string]$SciBin = (Join-Path $env:LOCALAPPDATA 'Programs\SCI\current\bin'),
    [string]$Zig = 'D:\zig-x86_64-windows-0.14.1\zig.exe',
    [int]$TimeoutSeconds = 300,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$pluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path -LiteralPath $SciBin -PathType Container)) {
    throw "SCI bin directory does not exist: $SciBin"
}
if (-not (Test-Path -LiteralPath $Zig -PathType Leaf)) {
    $zigCommand = Get-Command zig.exe -ErrorAction SilentlyContinue
    if ($null -eq $zigCommand) { throw "zig.exe was not found. Pass -Zig <path>." }
    $Zig = $zigCommand.Source
}

if (-not $SkipBuild) {
    Push-Location $pluginRoot
    try {
        & $Zig build -Doptimize=ReleaseFast --summary all
        if ($LASTEXITCODE -ne 0) { throw "sa_plugin_sla build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

$sa = Join-Path $SciBin 'sa.exe'
if (-not (Test-Path -LiteralPath $sa -PathType Leaf)) {
    throw "SCI executable not found: $sa"
}
$env:SA_PLUGIN_DEV = '1'
$installArgs = @('plugin', 'install', '--dev', $pluginRoot)
$proc = Start-Process -FilePath $sa -ArgumentList $installArgs -PassThru -WindowStyle Hidden
if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    $proc.Kill()
    throw "Timed out installing sa_plugin_sla after $TimeoutSeconds seconds"
}
if ($proc.ExitCode -ne 0) { throw "sa plugin install failed with exit code $($proc.ExitCode)" }

$builtBin = Join-Path $pluginRoot 'zig-out\bin'
foreach ($name in @('sla.exe', 'sla.pdb')) {
    $source = Join-Path $builtBin $name
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $SciBin $name) -Force
    }
}

$sla = Join-Path $SciBin 'sla.exe'
if (-not (Test-Path -LiteralPath $sla -PathType Leaf)) {
    throw "Global sla executable was not produced: $sla"
}
Write-Host "Installed sa_plugin_sla globally." -ForegroundColor Green
Write-Host "  Plugin: $env:LOCALAPPDATA\sa_plugins\installed\sla\current"
Write-Host "  CLI:    $sla"
Write-Host "  Usage:  sla check <file.sla>"
