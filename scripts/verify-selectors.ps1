param(
    [string]$RpcUrl,
    [string]$Diamond,
    [switch]$Compile,
    [int]$ThrottleMs = 125,
    [int]$Retries = 8,
    [int]$RetryBaseMs = 300
)

$ErrorActionPreference = "Stop"

function Import-Env {
    $envPath = Join-Path -Path $PSScriptRoot -ChildPath "..\.env"
    if (Test-Path $envPath) {
        Get-Content $envPath | ForEach-Object {
            if ($_ -match '^\s*#') { return }
            if ($_ -match '^\s*$') { return }
            $parts = $_ -split '=', 2
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim()
                $val = $parts[1].Trim()
                [Environment]::SetEnvironmentVariable($key, $val, "Process")
                Set-Item -Path "Env:$key" -Value $val
            }
        }
        Write-Host "Loaded .env from $envPath"
    } else {
        Write-Warning ".env no encontrado en $envPath"
    }
}

Import-Env

if ($RpcUrl) { $Env:RPC_URL = $RpcUrl }
if (-not $Env:RPC_URL) { throw "RPC_URL must be provided (or set in .env)" }

if (-not $Diamond) {
    $latestPath = Join-Path -Path $PSScriptRoot -ChildPath "..\deployments\sepolia-latest.json"
    if (Test-Path $latestPath) {
        $Diamond = (Get-Content $latestPath | ConvertFrom-Json).contracts.Diamond
    }
}
if (-not $Diamond) { throw "Diamond address missing (pass -Diamond or ensure sepolia-latest.json exists)" }

if ($Compile -or -not (Test-Path (Join-Path -Path $PSScriptRoot -ChildPath "..\out"))) {
    Write-Host "Running forge build..."
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Foundry writes compiler notes to stderr even when the build succeeds.
        # Do not let PowerShell's Stop preference turn those diagnostics into an
        # exception; the process exit code is the source of truth for the build.
        $ErrorActionPreference = "Continue"
        $buildOutput = forge build 2>&1
        $buildExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Write-Host $buildOutput
    if ($buildExitCode -ne 0) {
        throw "forge build failed (exit $buildExitCode)"
    }
}

Write-Host "Verifying selectors on $Diamond ..."
$verifyScript = Join-Path -Path $PSScriptRoot -ChildPath "verify-all-facets-selectors.cjs"
node $verifyScript --rpc $Env:RPC_URL --diamond $Diamond --throttle-ms $ThrottleMs --retries $Retries --retry-base-ms $RetryBaseMs
