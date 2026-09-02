param(
    [switch]$Execute,
    [string]$Chain = "sepolia",
    [string]$ResumeFile,
    [string]$RivalIntervalTreeLibrary,
    [string]$SolcPath,
    [int]$BatchSize = 0,
    [int]$BatchIndex = 1
)

function Load-Env {
    $envPath = Join-Path -Path $PSScriptRoot -ChildPath "..\.env"
    if (Test-Path $envPath) {
        Get-Content $envPath | ForEach-Object {
            if ($_ -match '^\s*#|^\s*$') { return }
            $parts = $_ -split '=', 2
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim()
                $val = $parts[1].Trim()
                [Environment]::SetEnvironmentVariable($key, $val, "Process")
                Set-Item -Path "Env:$key" -Value $val
            }
        }
    }
}

Load-Env

$resumePath = if ($ResumeFile) {
    $ResumeFile
} elseif ($Env:DEPLOY_RESUME_FILE) {
    Join-Path -Path $PSScriptRoot -ChildPath "..\$($Env:DEPLOY_RESUME_FILE)"
} else {
    Join-Path -Path $PSScriptRoot -ChildPath "..\deployments\$Chain-resume.json"
}
$resume = $null
if (Test-Path $resumePath) {
    $resume = Get-Content -Raw $resumePath | ConvertFrom-Json
}

$RivalIntervalTreeLibrary = if ($RivalIntervalTreeLibrary) { $RivalIntervalTreeLibrary } elseif ($resume -and $resume.base.RivalIntervalTreeLibrary) { $resume.base.RivalIntervalTreeLibrary } else { $Env:RIVAL_INTERVAL_TREE_LIBRARY }
$librarySpec = if ($RivalIntervalTreeLibrary) { "contracts/libraries/RivalIntervalTreeLibrary.sol:RivalIntervalTreeLibrary:$RivalIntervalTreeLibrary" } else { $null }
$LabTransferLibrary = if ($resume -and $resume.base.LibLabTransfer) { $resume.base.LibLabTransfer } else { $Env:LIB_LAB_TRANSFER }
function Get-SolcPathFromFoundryToml {
    $tomlPath = Join-Path -Path $PSScriptRoot -ChildPath "..\foundry.toml"
    if (-not (Test-Path $tomlPath)) {
        return $null
    }
    $toml = Get-Content -Raw $tomlPath
    if ($toml -match '(?im)^\s*solc\s*=\s*\"([^\"]+)\"') {
        return $Matches[1]
    }
    return $null
}

$SolcPath = if ($SolcPath) { $SolcPath } elseif ($Env:SOLC_PATH) { $Env:SOLC_PATH } else { Get-SolcPathFromFoundryToml }

$missingApiKey = $Execute -and [string]::IsNullOrWhiteSpace($Env:ETHERSCAN_API_KEY)
if ($missingApiKey) {
    throw "ETHERSCAN_API_KEY no esta definido en .env"
}

$libLinks = if ($RivalIntervalTreeLibrary) { @{ "contracts/libraries/RivalIntervalTreeLibrary.sol:RivalIntervalTreeLibrary" = $RivalIntervalTreeLibrary } } else { @{} }

$reservationConfirmLib = if ($resume) { $resume.base.LibReservationConfirmation } else { $null }
$instConfirmLib = if ($resume) { $resume.base.LibInstitutionalReservationConfirmation } else { $null }
$instValidationLib = if ($resume) { $resume.base.LibInstitutionalReservationRequestValidation } else { $null }
$instReleaseLib = if ($resume) { $resume.base.LibInstitutionalReservationRelease } else { $null }

$originalProfile = $Env:FOUNDRY_PROFILE
if (-not $Env:FOUNDRY_PROFILE) {
    $Env:FOUNDRY_PROFILE = "verify"
}

$facets = @{}
if ($resume -and $resume.facets) {
    foreach ($prop in $resume.facets.PSObject.Properties) {
        $facets[$prop.Value] = $prop.Name
    }
} else {
    $facets = @{
        "0xf1c4D2c4d14f1FC529130FE455A36D0216DF70e0" = "contracts/facets/diamond/DiamondCutFacet.sol:DiamondCutFacet"
        "0x786B33f738c0D18cAE32d9445a86C53dea7B0741" = "contracts/facets/diamond/DiamondLoupeFacet.sol:DiamondLoupeFacet"
        "0x877d0DBfb4d8db58dd4C21636a9EA42Ea7ce5C7B" = "contracts/facets/diamond/OwnershipFacet.sol:OwnershipFacet"
        "0x4e1e4B11d4dCf9aB8CB934cD6d365Cd705481d9d" = "contracts/facets/lab/LabFacet.sol:LabFacet"
        "0xF242Af2b89A8f96B730583d8F1Ce9e50DD4D4AF1" = "contracts/facets/lab/LabAdminFacet.sol:LabAdminFacet"
        "0x6097c823b9D04431671993E984f3E8DFb08B792A" = "contracts/facets/lab/LabQueryFacet.sol:LabQueryFacet"
        "0x14BDde99d872233795870e81Ffd0618c8e2b1AA3" = "contracts/facets/lab/LabIntentFacet.sol:LabIntentFacet"
        "0x18AE779D4A9F532602544cEE9AfEF0dcFd3Bc350" = "contracts/facets/ProviderFacet.sol:ProviderFacet"
        "0x5cd4E45d0938f501de3726D7540b8Db0171F12bD" = "contracts/facets/IntentRegistryFacet.sol:IntentRegistryFacet"
        "0xeb961BB2874DE6BE1e343d603308715BFffA2193" = "contracts/facets/reservation/institutional/InstitutionalReservationFacet.sol:InstitutionalReservationFacet"
        "0xB20D8727096a7A46D3C4BB4a8AA5B496593491b1" = "contracts/facets/reservation/institutional/InstitutionalReservationCoreFacet.sol:InstitutionalReservationCoreFacet"
        "0xc0EaE6B7380f89D3b628615da295e7E3590d621e" = "contracts/facets/reservation/institutional/InstitutionalReservationRequestCreationFacet.sol:InstitutionalReservationRequestCreationFacet"
        "0x2e7AD73CB25414dD7d9E2da9508F9cc487BBA7CD" = "contracts/facets/reservation/institutional/InstitutionalReservationRequestValidationFacet.sol:InstitutionalReservationRequestValidationFacet"
        "0x01A6186b0E91591151D34F1c94577AbB455788F0" = "contracts/facets/reservation/institutional/InstitutionalReservationRequestFacet.sol:InstitutionalReservationRequestFacet"
        "0x636761303E8F7499A3d6748184566E98eA761f83" = "contracts/facets/reservation/institutional/InstitutionalReservationConfirmationFacet.sol:InstitutionalReservationConfirmationFacet"
        "0xB16320755C050cA0dFE97bb882032328B18f314B" = "contracts/facets/reservation/institutional/InstitutionalReservationCancellationFacet.sol:InstitutionalReservationCancellationFacet"
        "0xEf6898F0BDc84d1B4Edd42773ef7ddC399fDe0f1" = "contracts/facets/reservation/institutional/InstitutionalReservationQueryFacet.sol:InstitutionalReservationQueryFacet"
        "0xb731dee566027bAA846CBe2ad0C13F9d5905238c" = "contracts/facets/reservation/ReservationIntentFacet.sol:ReservationIntentFacet"
        "0x79dEeDa9C54Fb3cdd6d73f3d100A314c1C56940E" = "contracts/facets/reservation/institutional/InstitutionalTreasuryFacet.sol:InstitutionalTreasuryFacet"
        "0x962456F035739b10891C97f1307E5E2cad2Fa7c4" = "contracts/facets/reservation/institutional/InstitutionalOrgRegistryFacet.sol:InstitutionalOrgRegistryFacet"
        "0xB64E9e25AACd701A2f64B8B953248D82142cf787" = "contracts/facets/reservation/institutional/InstitutionFacet.sol:InstitutionFacet"
    }
}

$extraContracts = @{}
if ($resume -and $resume.base) {
    if ($resume.base.RivalIntervalTreeLibrary) {
        $extraContracts[$resume.base.RivalIntervalTreeLibrary] = "contracts/libraries/RivalIntervalTreeLibrary.sol:RivalIntervalTreeLibrary"
    }
    if ($resume.base.LibLabTransfer) {
        $extraContracts[$resume.base.LibLabTransfer] = "contracts/libraries/LibLabTransfer.sol:LibLabTransfer"
    }
    if ($resume.base.LibReservationConfirmation) {
        $extraContracts[$resume.base.LibReservationConfirmation] =
            "contracts/libraries/LibReservationConfirmation.sol:LibReservationConfirmation"
    }
    if ($resume.base.LibInstitutionalReservationConfirmation) {
        $extraContracts[$resume.base.LibInstitutionalReservationConfirmation] =
            "contracts/libraries/LibInstitutionalReservationConfirmation.sol:LibInstitutionalReservationConfirmation"
    }
    if ($resume.base.LibInstitutionalReservationRequestValidation) {
        $extraContracts[$resume.base.LibInstitutionalReservationRequestValidation] =
            "contracts/libraries/LibInstitutionalReservationRequestValidation.sol:LibInstitutionalReservationRequestValidation"
    }
    if ($resume.base.LibInstitutionalReservationRelease) {
        $extraContracts[$resume.base.LibInstitutionalReservationRelease] =
            "contracts/libraries/LibInstitutionalReservationRelease.sol:LibInstitutionalReservationRelease"
    }
}

$facetLibMap = @{
    "contracts/facets/lab/LabFacet.sol:LabFacet" = @{
        "contracts/libraries/LibLabTransfer.sol:LibLabTransfer" = $LabTransferLibrary
    }
    "contracts/facets/reservation/ProviderSettlementFacet.sol:ProviderSettlementFacet" = $libLinks
    "contracts/facets/reservation/ReservationDenialFacet.sol:ReservationDenialFacet" = @{
        "contracts/libraries/LibReservationConfirmation.sol:LibReservationConfirmation" = $reservationConfirmLib
    }
    "contracts/facets/reservation/institutional/InstitutionalReservationConfirmationFacet.sol:InstitutionalReservationConfirmationFacet" = @{
        "contracts/libraries/LibInstitutionalReservationConfirmation.sol:LibInstitutionalReservationConfirmation" = $instConfirmLib
    }
    "contracts/facets/reservation/institutional/InstitutionalReservationRequestFacet.sol:InstitutionalReservationRequestFacet" = $libLinks
    "contracts/facets/reservation/institutional/InstitutionalReservationRequestValidationFacet.sol:InstitutionalReservationRequestValidationFacet" = @{
        "contracts/libraries/LibInstitutionalReservationRequestValidation.sol:LibInstitutionalReservationRequestValidation" = $instValidationLib
    }
    "contracts/facets/reservation/institutional/InstitutionalReservationRequestCreationFacet.sol:InstitutionalReservationRequestCreationFacet" = $libLinks
    "contracts/facets/reservation/institutional/InstitutionalReservationCancellationFacet.sol:InstitutionalReservationCancellationFacet" = $libLinks
    "contracts/facets/reservation/ReservationIntentFacet.sol:ReservationIntentFacet" = $libLinks
    "contracts/facets/reservation/institutional/InstitutionalReservationQueryFacet.sol:InstitutionalReservationQueryFacet" = $libLinks
    "contracts/facets/reservation/institutional/InstitutionalReservationFacet.sol:InstitutionalReservationFacet" = @{
        "contracts/libraries/LibInstitutionalReservationRelease.sol:LibInstitutionalReservationRelease" = $instReleaseLib
    }
}

# Historical Sepolia deployments use Foundry's default 200 optimizer runs.
# The current ProviderSettlementFacet upgrade was deliberately deployed with
# one run to stay within EIP-170, so pin only that new address to its exact
# compiler configuration.
$optimizerRunsByContract = @{
    "contracts/facets/reservation/ProviderSettlementFacet.sol:ProviderSettlementFacet" = 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Verificacion de Facets en Etherscan" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not $Execute) {
    Write-Host "[DRY RUN MODE]" -ForegroundColor Yellow
    Write-Host "Para ejecutar la verificacion real, usa: .\script\verify_facets.ps1 -Execute" -ForegroundColor Yellow
    Write-Host ""
}

$count = 0
$success = 0
$failed = 0
$verifyTargets = @{}
foreach ($k in $facets.Keys) { $verifyTargets[$k] = $facets[$k] }
foreach ($k in $extraContracts.Keys) { $verifyTargets[$k] = $extraContracts[$k] }
$items = $verifyTargets.GetEnumerator() | Sort-Object -Property Name
if ($BatchSize -gt 0) {
    if ($BatchIndex -lt 1) { throw "BatchIndex must be >= 1" }
    $start = ($BatchIndex - 1) * $BatchSize
    $end = [Math]::Min($start + $BatchSize - 1, $items.Count - 1)
    if ($start -ge $items.Count) {
        Write-Host "Batch $BatchIndex is empty (start $start >= total $($items.Count))." -ForegroundColor Yellow
        exit 0
    }
    $items = $items[$start..$end]
    Write-Host "Batch mode: size=$BatchSize index=$BatchIndex (items $start..$end of $($verifyTargets.Count))" -ForegroundColor Yellow
}
$total = $items.Count

foreach ($entry in $items) {
    $count++
    $address = $entry.Key
    $contract = $entry.Value
    $name = $contract.Split(':')[-1]
    $libs = $null
    if ($facetLibMap.ContainsKey($contract)) {
        $libs = $facetLibMap[$contract]
    } elseif ($contract -eq "contracts/libraries/LibReservationConfirmation.sol:LibReservationConfirmation" -or
              $contract -eq "contracts/libraries/LibInstitutionalReservationConfirmation.sol:LibInstitutionalReservationConfirmation") {
        $libs = $libLinks
    }

    Write-Host "[$count/$total] $name" -ForegroundColor Cyan
    Write-Host "  Address: $address" -ForegroundColor Gray

    if ($Execute) {
        if ($libs -and $libs.Count -gt 0) {
            foreach ($libKey in $libs.Keys) {
                if ([string]::IsNullOrWhiteSpace($libs[$libKey])) {
                    Write-Host "  [SKIP] Falta direccion para $libKey" -ForegroundColor Yellow
                    $failed++
                    Write-Host ""
                    continue 2
                }
            }
        }

        Write-Host "  Verificando..." -ForegroundColor Yellow
        $forgeArgs = @(
            "verify-contract",
            $address,
            $contract,
            "--chain",
            $Chain,
            "--verifier",
            "etherscan",
            "--etherscan-api-key",
            $Env:ETHERSCAN_API_KEY,
            "--skip-is-verified-check",
            "--watch"
        )
        if ($SolcPath) { $forgeArgs += @("--use", $SolcPath, "--no-auto-detect") }
        if ($libs -and $libs.Count -gt 0) {
            $libArgs = @()
            foreach ($libKey in $libs.Keys) {
                $libArgs += "${libKey}:$($libs[$libKey])"
            }
            $forgeArgs += @("--libraries", ($libArgs -join ","))
        }
        if ($optimizerRunsByContract.ContainsKey($contract)) {
            $forgeArgs += @("--optimizer-runs", [string]$optimizerRunsByContract[$contract])
        }

        $result = & forge @forgeArgs 2>&1 | Out-String

        if ($LASTEXITCODE -eq 0 -or $result -match "already verified|Contract successfully verified") {
            Write-Host "  [OK] Verificado" -ForegroundColor Green
            $success++
        } else {
            Write-Host "  [ERROR] Fallo" -ForegroundColor Red
            Write-Host "  Error: $($result.Substring(0, [Math]::Min(200, $result.Length)))" -ForegroundColor DarkRed
            $failed++
        }
        Start-Sleep -Seconds 3
    } else {
        Write-Host "  [DRY RUN] Se verificaria con:" -ForegroundColor Gray
        $solcHint = if ($SolcPath) { " --use $SolcPath --no-auto-detect" } else { "" }
        $libraryHint = ""
        if ($libs -and $libs.Count -gt 0) {
            $libArgs = @()
            foreach ($libKey in $libs.Keys) {
                $libArgs += "${libKey}:$($libs[$libKey])"
            }
            $libraryHint = " --libraries " + ($libArgs -join ",")
        }
        Write-Host "    forge verify-contract $address $contract --chain $Chain --verifier etherscan$solcHint$libraryHint" -ForegroundColor DarkGray
    }
    Write-Host ""
}

Write-Host "========================================" -ForegroundColor Cyan
if ($Execute) {
    Write-Host "Exitosos: $success" -ForegroundColor Green
    Write-Host "Fallidos: $failed" -ForegroundColor Red
}
Write-Host "Total: $count facets" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan

if ($originalProfile) {
    $Env:FOUNDRY_PROFILE = $originalProfile
} else {
    Remove-Item Env:FOUNDRY_PROFILE -ErrorAction SilentlyContinue
}
