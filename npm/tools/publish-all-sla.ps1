#Requires-Version 7.0
<#
.SYNOPSIS
  Publish all @slalang/sla packages in dependency order (Windows flow).
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$NpmArgs
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent

@(
    "sla-linux-x64", "sla-linux-arm64", "sla-darwin-arm64",
    "sla-darwin-x64", "sla-win32-x64", "sla-freebsd-x64"
) | ForEach-Object {
    Write-Host "=== publishing @slalang/$_"
    Push-Location (Join-Path $Root "packages/$_")
    try {
        npm publish --access public @NpmArgs
        if ($LASTEXITCODE -ne 0) { throw "npm publish failed for $_" }
    }
    finally { Pop-Location }
}

Write-Host "=== publishing @slalang/sla"
Push-Location (Join-Path $Root "packages/sla")
try {
    npm publish --access public @NpmArgs
    if ($LASTEXITCODE -ne 0) { throw "npm publish failed for sla" }
}
finally { Pop-Location }
