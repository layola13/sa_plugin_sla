#Requires-Version 7.0
<#
.SYNOPSIS
  Fetch prebuilt `sla` binaries from a sa_plugin_sla GitHub Release.
.EXAMPLE
  powershell tools/fetch-sla-binaries.ps1
  powershell tools/fetch-sla-binaries.ps1 -Version 0.1.3
#>
param(
    [string]$Version = "0.1.3"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
$Base = "https://github.com/layola13/sa_plugin_sla/releases/download/$Version"

$Map = @(
    @("linux-x86_64", "linux-x64", "sla"),
    @("arm-aarch64", "linux-arm64", "sla"),
    @("mac-aarch64", "darwin-arm64", "sla"),
    @("mac-x86_64", "darwin-x64", "sla"),
    @("windows-x86_64", "win32-x64", "sla.exe"),
    @("freebsd-x86_64", "freebsd-x64", "sla")
)

$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) "sla-fetch-$Version"
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

foreach ($m in $Map) {
    $Url = "$Base/sla-$Version-$($m[0]).zip"
    $Zip = Join-Path $Tmp "sla-$Version-$($m[0]).zip"
    $DestDir = Join-Path $Root "packages/sla-$($m[1])/bin"
    Write-Host "[i] $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Zip
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Fs = [System.IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($e in $Fs.Entries) {
            if ($e.Name -eq $m[2]) {
                $Dest = Join-Path $DestDir $m[2]
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $Dest, $true)
            }
        }
    }
    finally { $Fs.Dispose() }
    Write-Host "[ok] sla-$($m[1]) <= sla-$Version-$($m[0]).zip"
}

Remove-Item -Recurse -Force $Tmp
Write-Host "[✓] all platform binaries staged under npm/packages/*/bin"
