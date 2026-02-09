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
    $throttleMs = if ($env:VERIFY_THROTTLE_MS) { [int]$env:VERIFY_THROTTLE_MS } else { 175 }
    $retries = if ($env:VERIFY_RETRIES) { [int]$env:VERIFY_RETRIES } else { 10 }
    $retryBaseMs = if ($env:VERIFY_RETRY_BASE_MS) { [int]$env:VERIFY_RETRY_BASE_MS } else { 400 }

    & ./scripts/verify-selectors.ps1 `
        -RpcUrl $RpcUrl `
        -Diamond $diamond `
        -Compile `
        -ThrottleMs $throttleMs `
        -Retries $retries `
        -RetryBaseMs $retryBaseMs
} finally {
    Pop-Location
}
