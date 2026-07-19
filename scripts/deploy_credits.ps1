# powershell -File script/deploy_credits.ps1 -Broadcast 2>&1
# Credit-ledger / MiCA deployment flow

param(
    [switch]$Broadcast,
    [switch]$Resume,
    [string]$ResumeFile,
    [switch]$SkipVerify
)

# Loads key/value pairs from .env into $Env:*
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
                # Set in both Process scope and PowerShell variable for reliability
                [Environment]::SetEnvironmentVariable($key, $val, "Process")
                Set-Item -Path "Env:$key" -Value $val
            }
        }
        Write-Host "Loaded .env from $envPath"
    } else {
        Write-Warning ".env no encontrado en $envPath"
    }
}

# Returns only selectors explicitly assigned to the target in selectors/diamond.json.
function Get-Selectors {
    param(
        [string]$Target,   # e.g. contracts/facets/LabFacet.sol:LabFacet
        [string]$Address   # deployed address of that facet
    )

    $manifestScript = Join-Path -Path $PSScriptRoot -ChildPath "selector-manifest.cjs"
    $json = & node $manifestScript --target $Target
    if ($LASTEXITCODE -ne 0) { throw "Selector manifest lookup failed for $Target" }
    $entries = @($json | ConvertFrom-Json)
    $selectors = @($entries | ForEach-Object { $_.selector })
    return [PSCustomObject]@{
        Address   = $Address
        Selectors = $selectors
    }
}

function Get-FunctionSelector {
    param(
        [string]$Target,
        [string]$FunctionName
    )

    $manifestScript = Join-Path -Path $PSScriptRoot -ChildPath "selector-manifest.cjs"
    $json = & node $manifestScript --target $Target
    if ($LASTEXITCODE -ne 0) { throw "Selector manifest lookup failed for $Target" }
    $matches = @($json | ConvertFrom-Json) | Where-Object { $_.signature -like "$FunctionName(*" }
    if ($matches.Count -ne 1) { throw "Expected one manifest function named $FunctionName for $Target" }
    return $matches[0].selector
}

function DiamondCutBatch {
    param(
        [string]$Diamond,
        [array]$FacetCuts  # array of objects { Address, Selectors }
    )

    # Build Solidity-tuple syntax for this batch
    $tuples = @()
    foreach ($fc in $FacetCuts) {
        $sels = $fc.Selectors -join ","
        $tuples += "($($fc.Address),0,[$sels])"
    }
    $cutArg = "[" + ($tuples -join ",") + "]"

    $calldata = cast calldata "diamondCut((address,uint8,bytes4[])[],address,bytes)" $cutArg 0x0000000000000000000000000000000000000000 0x 2>&1
    if (-not $calldata -or $calldata -notmatch '^0x') {
        throw "Failed to encode diamondCut calldata: $calldata"
    }

    if ($Broadcast) {
        Write-Host "  Sending batch diamondCut..."
        $rawResult = & cast send $Diamond $calldata --rpc-url $Env:RPC_URL --private-key $Env:PRIVATE_KEY 2>&1
        $sendExitCode = $LASTEXITCODE
        $result = ($rawResult | Out-String).Trim()
        if ($sendExitCode -ne 0 -or $result -notmatch 'status\s+1') {
            throw "diamondCut transaction failed (exit code $sendExitCode): $result"
        }
        Write-Host $result
    } else {
        Write-Output "  Dry-run: cast send $Diamond <calldata> --rpc-url ..."
    }
}

function DiamondCut {
    param(
        [string]$Diamond,
        [array]$FacetCuts  # array of objects { Address, Selectors }
    )

    # Split into batches of 3 facets to avoid Windows command line length limit
    $batchSize = 3
    $totalBatches = [math]::Ceiling($FacetCuts.Count / $batchSize)
    
    Write-Host "Splitting diamondCut into $totalBatches batches of max $batchSize facets..."
    
    for ($i = 0; $i -lt $FacetCuts.Count; $i += $batchSize) {
        $batch = $FacetCuts[$i..([math]::Min($i + $batchSize - 1, $FacetCuts.Count - 1))]
        $batchNum = [math]::Floor($i / $batchSize) + 1
        Write-Host "Processing batch $batchNum/$totalBatches ($($batch.Count) facets)..."
        DiamondCutBatch -Diamond $Diamond -FacetCuts $batch
    }
}

Load-Env

if (-not $Env:RPC_URL -or -not $Env:PRIVATE_KEY) {
    throw "RPC_URL y PRIVATE_KEY must be defined in .env"
}

$network = if ($Env:RPC_URL -match "sepolia") { "sepolia" } elseif ($Env:RPC_URL -match "mainnet") { "mainnet" } else { "unknown" }
$defaultResumeFile = Join-Path -Path $PSScriptRoot -ChildPath "..\deployments\$network-resume.json"
if (-not $ResumeFile) {
    $ResumeFile = $defaultResumeFile
}

function Is-ValidAddress {
    param([string]$Address)
    return $Address -match '^0x[a-fA-F0-9]{40}$'
}

function Load-ResumeState {
    param([string]$Path)
    $state = [ordered]@{
        base = @{}
        facets = @{}
    }
    if (-not $Resume -or -not $Path -or -not (Test-Path $Path)) {
        return $state
    }
    $raw = Get-Content -Raw $Path | ConvertFrom-Json
    if ($raw.base) {
        foreach ($prop in $raw.base.PSObject.Properties) {
            $state.base[$prop.Name] = $prop.Value
        }
    }
    if ($raw.facets) {
        foreach ($prop in $raw.facets.PSObject.Properties) {
            $state.facets[$prop.Name] = $prop.Value
        }
    }
    return $state
}

function Save-ResumeState {
    param([string]$Path, [hashtable]$State)
    if (-not $Resume -or -not $Broadcast -or -not $Path) {
        return
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $out = [ordered]@{
        network = $network
        updated = (Get-Date -Format "o")
        base = $State.base
        facets = $State.facets
    }
    $out | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
}

function Get-ExistingBase {
    param(
        [hashtable]$State,
        [string]$Key,
        [string]$EnvVar
    )
    if ($Resume -and $State.base.ContainsKey($Key) -and (Is-ValidAddress $State.base[$Key])) {
        return $State.base[$Key]
    }
    if ($EnvVar) {
        $val = [Environment]::GetEnvironmentVariable($EnvVar)
        if (Is-ValidAddress $val) {
            return $val
        }
    }
    return $null
}

function Get-ExistingFacet {
    param(
        [hashtable]$State,
        [string]$Target
    )
    if ($Resume -and $State.facets.ContainsKey($Target) -and (Is-ValidAddress $State.facets[$Target])) {
        return $State.facets[$Target]
    }
    return $null
}

$resumeState = Load-ResumeState -Path $ResumeFile

# Deploy base facets and contracts
function Deploy-Contract {
    param(
        [string]$Target,  # e.g. contracts/facets/DiamondCutFacet.sol:DiamondCutFacet
        [array]$ConstructorArgs = @(),
        [hashtable]$Libraries = @{},  # e.g. @{ "contracts/libraries/Lib.sol:Lib" = "0x..." }
        [string]$ExistingAddress
    )

    if (Is-ValidAddress $ExistingAddress) {
        Write-Host "Using existing deployment for $Target -> $ExistingAddress"
        return $ExistingAddress
    }

    if (-not $Broadcast) { 
        Write-Host "[Dry-run] Would deploy $Target"
        return "0xDRY_RUN_ADDRESS"
    }
    
    $forgeArgs = @("create", "--rpc-url", $Env:RPC_URL, "--private-key", $Env:PRIVATE_KEY, "--broadcast")
    
    # Add library links
    if ($Libraries -and $Libraries.Count -gt 0) {
        foreach ($lib in $Libraries.Keys) {
            $addr = $Libraries[$lib]
            if (-not (Is-ValidAddress $addr)) {
                throw "Invalid library address for $lib -> $addr"
            }
            $forgeArgs += "--libraries"
            $forgeArgs += "$lib`:$addr"
        }
        $libSummary = ($Libraries.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Sort-Object) -join ", "
        Write-Host "  Libraries: $libSummary"
    }
    
    $forgeArgs += $Target
    
    if ($ConstructorArgs.Count -gt 0) {
        $forgeArgs += "--constructor-args"
        $forgeArgs += $ConstructorArgs
    }
    
    Write-Host "Deploying $Target..."
    
    # Capture output as single string
    $rawOutput = & forge @forgeArgs 2>&1 | Out-String
    
    # Extract the deployed address from standard output format: "Deployed to: 0x..."
    if ($rawOutput -match 'Deployed to:\s*(0x[a-fA-F0-9]{40})') {
        $address = $Matches[1]
        Write-Host "  -> $address"
        return $address
    }
    
    Write-Host "Output: $rawOutput"
    throw "Failed to extract address for $Target from output"
}

Write-Host "Deploying DiamondCutFacet..."
$diamondCutFacet = Deploy-Contract "contracts/facets/diamond/DiamondCutFacet.sol:DiamondCutFacet" -ExistingAddress (Get-ExistingBase -State $resumeState -Key "DiamondCutFacet" -EnvVar "DIAMOND_CUT_FACET")
Write-Host "DiamondCutFacet deployed at: $diamondCutFacet"
if (Is-ValidAddress $diamondCutFacet) {
    $resumeState.base["DiamondCutFacet"] = $diamondCutFacet
    Save-ResumeState -Path $ResumeFile -State $resumeState
}

Write-Host "Deploying DiamondInit..."
$diamondInit = Deploy-Contract "contracts/upgradeInitializers/DiamondInit.sol:DiamondInit" -ExistingAddress (Get-ExistingBase -State $resumeState -Key "DiamondInit" -EnvVar "DIAMOND_INIT")
Write-Host "DiamondInit deployed at: $diamondInit"
if (Is-ValidAddress $diamondInit) {
    $resumeState.base["DiamondInit"] = $diamondInit
    Save-ResumeState -Path $ResumeFile -State $resumeState
}

# Get the selector for diamondCut function (0x1f931c1c)
$diamondCutSelector = "0x1f931c1c"

# Prepare init calldata
$initCalldata = cast calldata "init()"
Write-Host "Init calldata: $initCalldata"

Write-Host "Deploying Diamond..."
# Constructor args for Diamond:
# 1. FacetCut[] - array of (address facetAddress, uint8 action, bytes4[] functionSelectors)
# 2. DiamondArgs - struct (address owner, address init, bytes initCalldata)

# Format for forge create with complex types:
# FacetCut[]: "[($address,0,[$selector])]"
# DiamondArgs: "($owner,$init,$calldata)"

$facetCutArg = "[($diamondCutFacet,0,[$diamondCutSelector])]"
$diamondArgsArg = "($Env:DIAMOND_OWNER,$diamondInit,$initCalldata)"

Write-Host "FacetCut arg: $facetCutArg"
Write-Host "DiamondArgs arg: $diamondArgsArg"

$diamondAddress = Deploy-Contract "contracts/Diamond.sol:Diamond" @($facetCutArg, $diamondArgsArg) -ExistingAddress (Get-ExistingBase -State $resumeState -Key "Diamond" -EnvVar "DIAMOND_ADDRESS")
Write-Host "Diamond deployed at: $diamondAddress"
if (Is-ValidAddress $diamondAddress) {
    $resumeState.base["Diamond"] = $diamondAddress
    Save-ResumeState -Path $ResumeFile -State $resumeState
}

if ($diamondAddress -eq "0xDRY_RUN_ADDRESS") {
    Write-Host "Dry-run mode - stopping here. Use -Broadcast to deploy."
    exit 0
}

# Deploy RivalIntervalTreeLibrary first (required by LabFacet and reservation facets)
Write-Host "Deploying RivalIntervalTreeLibrary..."
$rivalLib = Deploy-Contract "contracts/libraries/RivalIntervalTreeLibrary.sol:RivalIntervalTreeLibrary" -ExistingAddress (Get-ExistingBase -State $resumeState -Key "RivalIntervalTreeLibrary" -EnvVar "RIVAL_INTERVAL_TREE_LIBRARY")
Write-Host "RivalIntervalTreeLibrary deployed at: $rivalLib"
if (Is-ValidAddress $rivalLib) {
    $resumeState.base["RivalIntervalTreeLibrary"] = $rivalLib
    Save-ResumeState -Path $ResumeFile -State $resumeState
}

Write-Host "Deploying LibLabTransfer..."
$labTransferLib = Deploy-Contract "contracts/libraries/LibLabTransfer.sol:LibLabTransfer" -ExistingAddress (Get-ExistingBase -State $resumeState -Key "LibLabTransfer" -EnvVar "LIB_LAB_TRANSFER")
Write-Host "LibLabTransfer deployed at: $labTransferLib"
if (Is-ValidAddress $labTransferLib) {
    $resumeState.base["LibLabTransfer"] = $labTransferLib
    Save-ResumeState -Path $ResumeFile -State $resumeState
}

$libLinksReservation = @{ "contracts/libraries/RivalIntervalTreeLibrary.sol:RivalIntervalTreeLibrary" = $rivalLib }

Write-Host "Deploying LibInstitutionalReservationConfirmation..."
$instConfirmLib = Deploy-Contract "contracts/libraries/LibInstitutionalReservationConfirmation.sol:LibInstitutionalReservationConfirmation" -Libraries $libLinksReservation -ExistingAddress (Get-ExistingBase -State $resumeState -Key "LibInstitutionalReservationConfirmation" -EnvVar "LIB_INSTITUTIONAL_RESERVATION_CONFIRMATION")
Write-Host "LibInstitutionalReservationConfirmation deployed at: $instConfirmLib"
if (Is-ValidAddress $instConfirmLib) {
    $resumeState.base["LibInstitutionalReservationConfirmation"] = $instConfirmLib
    Save-ResumeState -Path $ResumeFile -State $resumeState
}

Write-Host "Deploying LibReservationConfirmation..."
$existingReservationConfirmLib = Get-ExistingBase -State $resumeState -Key "LibReservationConfirmation" -EnvVar "LIB_RESERVATION_CONFIRMATION"
$reservationConfirmLib = Deploy-Contract "contracts/libraries/LibReservationConfirmation.sol:LibReservationConfirmation" -Libraries $libLinksReservation -ExistingAddress $existingReservationConfirmLib
Write-Host "LibReservationConfirmation deployed at: $reservationConfirmLib"
if (Is-ValidAddress $reservationConfirmLib) {
    $resumeState.base["LibReservationConfirmation"] = $reservationConfirmLib
    Save-ResumeState -Path $ResumeFile -State $resumeState
}

Write-Host "Deploying LibInstitutionalReservationRequestValidation..."
$instValidationLib = Deploy-Contract "contracts/libraries/LibInstitutionalReservationRequestValidation.sol:LibInstitutionalReservationRequestValidation" -ExistingAddress (Get-ExistingBase -State $resumeState -Key "LibInstitutionalReservationRequestValidation" -EnvVar "LIB_INSTITUTIONAL_RESERVATION_REQUEST_VALIDATION")
Write-Host "LibInstitutionalReservationRequestValidation deployed at: $instValidationLib"
if (Is-ValidAddress $instValidationLib) {
    $resumeState.base["LibInstitutionalReservationRequestValidation"] = $instValidationLib
    Save-ResumeState -Path $ResumeFile -State $resumeState
}

Write-Host "Deploying LibInstitutionalReservationRelease..."
$instReleaseLib = Deploy-Contract "contracts/libraries/LibInstitutionalReservationRelease.sol:LibInstitutionalReservationRelease" -ExistingAddress (Get-ExistingBase -State $resumeState -Key "LibInstitutionalReservationRelease" -EnvVar "LIB_INSTITUTIONAL_RESERVATION_RELEASE")
Write-Host "LibInstitutionalReservationRelease deployed at: $instReleaseLib"
if (Is-ValidAddress $instReleaseLib) {
    $resumeState.base["LibInstitutionalReservationRelease"] = $instReleaseLib
    Save-ResumeState -Path $ResumeFile -State $resumeState
}

$libLinksLab = @{ "contracts/libraries/LibLabTransfer.sol:LibLabTransfer" = $labTransferLib }
$libLinksReservationConfirm = @{ "contracts/libraries/LibReservationConfirmation.sol:LibReservationConfirmation" = $reservationConfirmLib }
$libLinksInstConfirm = @{ "contracts/libraries/LibInstitutionalReservationConfirmation.sol:LibInstitutionalReservationConfirmation" = $instConfirmLib }
$libLinksInstValidation = @{ "contracts/libraries/LibInstitutionalReservationRequestValidation.sol:LibInstitutionalReservationRequestValidation" = $instValidationLib }
$libLinksInstRelease = @{ "contracts/libraries/LibInstitutionalReservationRelease.sol:LibInstitutionalReservationRelease" = $instReleaseLib }

# Deploy facets in a structured, deterministic order:
# 1) Diamond admin/management
# 2) Core admin & governance
# 3) Labs
# 4) Provider receivable / settlement
# 5) Institutional reservations
# 6) Reservation cross-cutting
$facetPlan = @(
    # Diamond admin/management
    @{ Target = "contracts/facets/diamond/DiamondLoupeFacet.sol:DiamondLoupeFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/diamond/OwnershipFacet.sol:OwnershipFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/InitFacet.sol:InitFacet"; NeedsLib = $false },

    # Core admin & governance
    @{ Target = "contracts/facets/ProviderFacet.sol:ProviderFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/ServiceCreditFacet.sol:ServiceCreditFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/IntentRegistryFacet.sol:IntentRegistryFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/reservation/institutional/InstitutionFacet.sol:InstitutionFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/reservation/institutional/InstitutionalOrgRegistryFacet.sol:InstitutionalOrgRegistryFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/reservation/institutional/InstitutionalTreasuryFacet.sol:InstitutionalTreasuryFacet"; NeedsLib = $false },

    # Labs
    @{ Target = "contracts/facets/lab/LabFacet.sol:LabFacet"; NeedsLib = $true; Libs = $libLinksLab },
    @{ Target = "contracts/facets/lab/LabAdminFacet.sol:LabAdminFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/lab/LabIntentFacet.sol:LabIntentFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/lab/LabQueryFacet.sol:LabQueryFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/lab/LabReputationFacet.sol:LabReputationFacet"; NeedsLib = $false },

    # Provider receivable / settlement
    @{ Target = "contracts/facets/reservation/ProviderSettlementFacet.sol:ProviderSettlementFacet"; NeedsLib = $true; Libs = $libLinksReservation },

    # Institutional reservations
    @{ Target = "contracts/facets/reservation/institutional/InstitutionalReservationRequestValidationFacet.sol:InstitutionalReservationRequestValidationFacet"; NeedsLib = $true; Libs = $libLinksInstValidation },
    @{ Target = "contracts/facets/reservation/institutional/InstitutionalReservationRequestCreationFacet.sol:InstitutionalReservationRequestCreationFacet"; NeedsLib = $true; Libs = $libLinksReservation },
    @{ Target = "contracts/facets/reservation/institutional/InstitutionalReservationRequestFacet.sol:InstitutionalReservationRequestFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/reservation/institutional/InstitutionalReservationConfirmationFacet.sol:InstitutionalReservationConfirmationFacet"; NeedsLib = $true; Libs = $libLinksInstConfirm },
    @{ Target = "contracts/facets/reservation/institutional/InstitutionalReservationCancellationFacet.sol:InstitutionalReservationCancellationFacet"; NeedsLib = $true; Libs = $libLinksReservation },
    @{ Target = "contracts/facets/reservation/institutional/InstitutionalReservationQueryFacet.sol:InstitutionalReservationQueryFacet"; NeedsLib = $true; Libs = $libLinksReservation },
    @{ Target = "contracts/facets/reservation/institutional/InstitutionalReservationFacet.sol:InstitutionalReservationFacet"; NeedsLib = $true; Libs = $libLinksInstRelease },

    # Reservation cross-cutting
    @{ Target = "contracts/facets/reservation/ReservationCheckInFacet.sol:ReservationCheckInFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/reservation/ReservationSessionFacet.sol:ReservationSessionFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/reservation/ReservationStatsFacet.sol:ReservationStatsFacet"; NeedsLib = $false },
    @{ Target = "contracts/facets/reservation/ReservationDenialFacet.sol:ReservationDenialFacet"; NeedsLib = $true; Libs = $libLinksReservationConfirm },
    @{ Target = "contracts/facets/reservation/ReservationIntentFacet.sol:ReservationIntentFacet"; NeedsLib = $false }
)

$facetCuts = @()

foreach ($entry in $facetPlan) {
    $ft = $entry.Target
    $needsLib = [bool]$entry.NeedsLib
    $libs = $null
    if ($entry.ContainsKey("Libs")) {
        $libs = $entry["Libs"]
    } elseif ($needsLib) {
        $libs = $libLinksReservation
    }
    if ($libs -and $libs.Count -gt 0) {
        Write-Host "Deploying $ft (with library link)..."
        $addr = Deploy-Contract $ft -Libraries $libs -ExistingAddress (Get-ExistingFacet -State $resumeState -Target $ft)
    } else {
        Write-Host "Deploying $ft ..."
        $addr = Deploy-Contract $ft -ExistingAddress (Get-ExistingFacet -State $resumeState -Target $ft)
    }
    Write-Host "$ft deployed at: $addr"
    if (Is-ValidAddress $addr) {
        $resumeState.facets[$ft] = $addr
        Save-ResumeState -Path $ResumeFile -State $resumeState
    }
    $selectorInfo = Get-Selectors -Target $ft -Address $addr
    if ($selectorInfo.Selectors.Count -gt 0) {
        $facetCuts += [PSCustomObject]@{
            Address   = $addr
            Selectors = $selectorInfo.Selectors
        }
    }
}

# A duplicate is a manifest error; never resolve it by deployment order.
Write-Host "Validating selector uniqueness across facets..."
$seenSelectors = @{}
$filteredFacetCuts = @()

foreach ($fc in $facetCuts) {
    $uniqueSelectors = @()
    foreach ($sel in $fc.Selectors) {
        if (-not $seenSelectors.ContainsKey($sel)) {
            $seenSelectors[$sel] = $fc.Address
            $uniqueSelectors += $sel
        } else {
            throw "Duplicate selector $sel assigned to $($seenSelectors[$sel]) and $($fc.Address)"
        }
    }
    if ($uniqueSelectors.Count -gt 0) {
        $filteredFacetCuts += [PSCustomObject]@{
            Address   = $fc.Address
            Selectors = $uniqueSelectors
        }
    }
}

Write-Host "Total unique selectors: $($seenSelectors.Count)"
$facetCuts = $filteredFacetCuts

Write-Host "Performing diamondCut to add all facets..."
DiamondCut -Diamond $diamondAddress -FacetCuts $facetCuts

function Assert-SelectorLinked {
    param(
        [string]$Diamond,
        [string]$Selector,
        [string]$Label
    )
    $facet = (cast call $Diamond "facetAddress(bytes4)(address)" $Selector --rpc-url $Env:RPC_URL 2>$null).Trim()
    if (-not $facet -or $facet -eq "0x0000000000000000000000000000000000000000") {
        throw "Missing selector $Selector for $Label (facetAddress returned $facet)"
    }
    Write-Host "  [OK] $Label -> $facet"
}

function Assert-SelectorOwner {
    param(
        [string]$Diamond,
        [string]$Selector,
        [string]$ExpectedFacet,
        [string]$Label
    )
    if (-not $ExpectedFacet -or $ExpectedFacet -eq "0xDRY_RUN_ADDRESS") {
        Write-Host "  [SKIP] $Label - expected facet missing"
        return
    }
    $facet = (cast call $Diamond "facetAddress(bytes4)(address)" $Selector --rpc-url $Env:RPC_URL 2>$null).Trim()
    if (-not $facet -or $facet -eq "0x0000000000000000000000000000000000000000") {
        throw "Missing selector $Selector for $Label (facetAddress returned $facet)"
    }
    if ($facet -ine $ExpectedFacet) {
        throw "Selector $Selector for $Label linked to $facet (expected $ExpectedFacet)"
    }
    Write-Host "  [OK] $Label -> $facet"
}

function Assert-CriticalSelectors {
    param([string]$Diamond)
    if ($Diamond -eq "0xDRY_RUN_ADDRESS") {
        Write-Host "Skipping selector checks in dry-run mode."
        return
    }

    $registerActionIntentSelector = Get-FunctionSelector -Target "contracts/facets/IntentRegistryFacet.sol:IntentRegistryFacet" -FunctionName "registerActionIntent"
    $registerReservationIntentSelector = Get-FunctionSelector -Target "contracts/facets/IntentRegistryFacet.sol:IntentRegistryFacet" -FunctionName "registerReservationIntent"

    Write-Host "Validating critical selectors on Diamond..."
    Assert-SelectorLinked -Diamond $Diamond -Selector $registerActionIntentSelector -Label "registerActionIntent"
    Assert-SelectorLinked -Diamond $Diamond -Selector $registerReservationIntentSelector -Label "registerReservationIntent"

    $denialFacet = $resumeState.facets["contracts/facets/reservation/ReservationDenialFacet.sol:ReservationDenialFacet"]

    Assert-SelectorOwner -Diamond $Diamond -Selector "0x8eaf612f" -ExpectedFacet $denialFacet -Label "denyReservationRequest(bytes32)"
}

Assert-CriticalSelectors -Diamond $diamondAddress

Write-Host "============================================"
Write-Host "Diamond: $diamondAddress"
Write-Host "============================================"

# Initializers after cut
function Send-Call {
    param(
        [string]$To,
        [string]$Sig,  # e.g. 'initialize(string,string,string,address)'
        [array]$CallArgs
    )
    # Validate that no arg is null/empty (env vars missing)
    $missingArgs = @()
    for ($i = 0; $i -lt $CallArgs.Count; $i++) {
        if ([string]::IsNullOrWhiteSpace($CallArgs[$i])) {
            $missingArgs += "arg[$i]"
        }
    }
    if ($missingArgs.Count -gt 0) {
        throw "Initialization $Sig has missing/empty arguments: $($missingArgs -join ', ') (check .env)"
    }
    
    $calldataOutput = & cast calldata $Sig @CallArgs 2>&1
    $calldataExitCode = $LASTEXITCODE
    $calldata = ($calldataOutput | Out-String).Trim()
    if ($calldataExitCode -ne 0 -or -not $calldata -or $calldata -notmatch '^0x') {
        throw "Initialization $Sig failed to encode calldata (exit code $calldataExitCode): $calldata"
    }
    
    if ($Broadcast) {
        Write-Host "Calling $Sig on $To..."
        $rawResult = & cast send $To $calldata --rpc-url $Env:RPC_URL --private-key $Env:PRIVATE_KEY 2>&1
        $sendExitCode = $LASTEXITCODE
        $result = ($rawResult | Out-String).Trim()
        if ($sendExitCode -ne 0) {
            throw "Initialization $Sig transaction failed (exit code $sendExitCode): $result"
        } elseif ($result -match "already initialized") {
            Write-Host "  [OK] $Sig - already initialized (skipping)" -ForegroundColor Yellow
        } elseif ($result -match "status\s+1") {
            Write-Host "  [OK] $Sig - success" -ForegroundColor Green
        } else {
            throw "Initialization $Sig did not return a successful receipt: $result"
        }
    } else {
        Write-Output "Dry-run: cast send $To $calldata --rpc-url <RPC_URL> --private-key <PRIVATE_KEY>"
    }
}

Write-Host "Initializing Diamond facets..."

Send-Call -To $diamondAddress -Sig "initializeDiamond(string,string,string,string,string)" -CallArgs @(
    $Env:ADMIN_NAME,
    $Env:ADMIN_EMAIL,
    $Env:ADMIN_COUNTRY,
    "DecentraLabs",
    "dLAB"
)

Write-Host "============================================"
Write-Host "Deployment complete!"
Write-Host "Diamond: $diamondAddress"
Write-Host "============================================"

if (-not $SkipVerify) {
    if (-not $Broadcast) {
        Write-Host "Skipping Etherscan verification (dry-run). Use -Broadcast to verify."
    } else {
        Write-Host "Verifying facets on Etherscan..."
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\\verify_facets.ps1" -Execute -Chain $network -ResumeFile $ResumeFile
        if ($LASTEXITCODE -ne 0) {
            throw "Facet verification failed (see logs above)."
        }
    }
}

# Write deployment output file
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$outputFile = Join-Path -Path $PSScriptRoot -ChildPath "..\deployments\$network-$timestamp.json"
$outputDir = Split-Path -Parent $outputFile

if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$deployment = [ordered]@{
    network = $network
    timestamp = (Get-Date -Format "o")
    chainId = if ($network -eq "sepolia") { 11155111 } elseif ($network -eq "mainnet") { 1 } else { 0 }
    contracts = [ordered]@{
        Diamond = $diamondAddress
        DiamondCutFacet = $diamondCutFacet
        DiamondInit = $diamondInit
    }
    libraries = [ordered]@{
        RivalIntervalTreeLibrary = $rivalLib
        LibLabTransfer = $labTransferLib
        LibReservationConfirmation = $reservationConfirmLib
        LibInstitutionalReservationConfirmation = $instConfirmLib
        LibInstitutionalReservationRequestValidation = $instValidationLib
        LibInstitutionalReservationRelease = $instReleaseLib
    }
    facets = [ordered]@{
        DiamondLoupeFacet = $resumeState.facets["contracts/facets/diamond/DiamondLoupeFacet.sol:DiamondLoupeFacet"]
        OwnershipFacet = $resumeState.facets["contracts/facets/diamond/OwnershipFacet.sol:OwnershipFacet"]
        InitFacet = $resumeState.facets["contracts/facets/InitFacet.sol:InitFacet"]
        ProviderFacet = $resumeState.facets["contracts/facets/ProviderFacet.sol:ProviderFacet"]
        ServiceCreditFacet = $resumeState.facets["contracts/facets/ServiceCreditFacet.sol:ServiceCreditFacet"]
        IntentRegistryFacet = $resumeState.facets["contracts/facets/IntentRegistryFacet.sol:IntentRegistryFacet"]
        InstitutionFacet = $resumeState.facets["contracts/facets/reservation/institutional/InstitutionFacet.sol:InstitutionFacet"]
        InstitutionalOrgRegistryFacet = $resumeState.facets["contracts/facets/reservation/institutional/InstitutionalOrgRegistryFacet.sol:InstitutionalOrgRegistryFacet"]
        InstitutionalTreasuryFacet = $resumeState.facets["contracts/facets/reservation/institutional/InstitutionalTreasuryFacet.sol:InstitutionalTreasuryFacet"]
        LabFacet = $resumeState.facets["contracts/facets/lab/LabFacet.sol:LabFacet"]
        LabAdminFacet = $resumeState.facets["contracts/facets/lab/LabAdminFacet.sol:LabAdminFacet"]
        LabIntentFacet = $resumeState.facets["contracts/facets/lab/LabIntentFacet.sol:LabIntentFacet"]
        LabQueryFacet = $resumeState.facets["contracts/facets/lab/LabQueryFacet.sol:LabQueryFacet"]
        LabReputationFacet = $resumeState.facets["contracts/facets/lab/LabReputationFacet.sol:LabReputationFacet"]
        ProviderSettlementFacet = $resumeState.facets["contracts/facets/reservation/ProviderSettlementFacet.sol:ProviderSettlementFacet"]
        InstitutionalReservationRequestValidationFacet = $resumeState.facets["contracts/facets/reservation/institutional/InstitutionalReservationRequestValidationFacet.sol:InstitutionalReservationRequestValidationFacet"]
        InstitutionalReservationRequestCreationFacet = $resumeState.facets["contracts/facets/reservation/institutional/InstitutionalReservationRequestCreationFacet.sol:InstitutionalReservationRequestCreationFacet"]
        InstitutionalReservationRequestFacet = $resumeState.facets["contracts/facets/reservation/institutional/InstitutionalReservationRequestFacet.sol:InstitutionalReservationRequestFacet"]
        InstitutionalReservationConfirmationFacet = $resumeState.facets["contracts/facets/reservation/institutional/InstitutionalReservationConfirmationFacet.sol:InstitutionalReservationConfirmationFacet"]
        InstitutionalReservationCancellationFacet = $resumeState.facets["contracts/facets/reservation/institutional/InstitutionalReservationCancellationFacet.sol:InstitutionalReservationCancellationFacet"]
        InstitutionalReservationQueryFacet = $resumeState.facets["contracts/facets/reservation/institutional/InstitutionalReservationQueryFacet.sol:InstitutionalReservationQueryFacet"]
        InstitutionalReservationFacet = $resumeState.facets["contracts/facets/reservation/institutional/InstitutionalReservationFacet.sol:InstitutionalReservationFacet"]
        ReservationCheckInFacet = $resumeState.facets["contracts/facets/reservation/ReservationCheckInFacet.sol:ReservationCheckInFacet"]
        ReservationSessionFacet = $resumeState.facets["contracts/facets/reservation/ReservationSessionFacet.sol:ReservationSessionFacet"]
        ReservationStatsFacet = $resumeState.facets["contracts/facets/reservation/ReservationStatsFacet.sol:ReservationStatsFacet"]
        ReservationDenialFacet = $resumeState.facets["contracts/facets/reservation/ReservationDenialFacet.sol:ReservationDenialFacet"]
        ReservationIntentFacet = $resumeState.facets["contracts/facets/reservation/ReservationIntentFacet.sol:ReservationIntentFacet"]
    }
    deployer = $Env:DIAMOND_OWNER
    configuration = [ordered]@{
        adminName = $Env:ADMIN_NAME
        adminEmail = $Env:ADMIN_EMAIL
        adminCountry = $Env:ADMIN_COUNTRY
        diamondName = "DecentraLabs"
        diamondSymbol = "dLAB"
        deploymentModel = "credit-ledger"
        accountingBuckets = @(
            "providerReceivable"
        )
    }
}

$deployment | ConvertTo-Json -Depth 4 | Set-Content -Path $outputFile -Encoding UTF8
Write-Host ""
Write-Host "Deployment info saved to: $outputFile" -ForegroundColor Cyan

# Also write a latest symlink-style file
$latestFile = Join-Path -Path $outputDir -ChildPath "$network-latest.json"
$deployment | ConvertTo-Json -Depth 4 | Set-Content -Path $latestFile -Encoding UTF8
Write-Host "Latest deployment: $latestFile" -ForegroundColor Cyan
