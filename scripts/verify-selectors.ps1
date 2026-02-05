param(
    [string]$RpcUrl,
    [string]$Diamond,
    [switch]$Compile,
    [int]$ThrottleMs = 50
)

$ErrorActionPreference = "Stop"

function Load-Env {
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

Load-Env

if ($RpcUrl) { $Env:RPC_URL = $RpcUrl }
if (-not $Env:RPC_URL) { throw "RPC_URL must be provided (or set in .env)" }

if (-not $Diamond) {
    $resumePath = Join-Path -Path $PSScriptRoot -ChildPath "..\deployments\sepolia-resume.json"
    if (Test-Path $resumePath) {
        $Diamond = (Get-Content $resumePath | ConvertFrom-Json).base.Diamond
    }
}
if (-not $Diamond) { throw "Diamond address missing (pass -Diamond or ensure resume file exists)" }

if ($Compile -or -not (Test-Path (Join-Path -Path $PSScriptRoot -ChildPath "..\hh-artifacts"))) {
    Write-Host "Running hardhat compile..."
    npx hardhat compile | Out-String | Write-Host
}

Write-Host "Verifying selectors on $Diamond ..."
node "$PSScriptRoot\verify-all-facets-selectors.js" --rpc $Env:RPC_URL --diamond $Diamond --throttle-ms $ThrottleMs
