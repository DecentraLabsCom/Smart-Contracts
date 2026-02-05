param(
    [string]$RpcUrl
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
    if (-not $RpcUrl) {
        Write-Host "SEPOLIA_RPC_URL missing -- skipping verify"
        return
    }

    $deploymentsPath = "./deployments/sepolia-latest.json"
    if (-not (Test-Path $deploymentsPath)) {
        Write-Host "sepolia-latest.json missing -- skipping verify"
        return
    }

    $diamond = node -e "console.log(require('./deployments/sepolia-latest.json').contracts.Diamond)"
    & ./scripts/verify-selectors.ps1 -RpcUrl $RpcUrl -Diamond $diamond -Compile
} finally {
    Pop-Location
}
