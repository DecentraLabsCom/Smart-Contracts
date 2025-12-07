#powershell -File script/deploy.ps1 -Broadcast 2>&1

param(
    [switch]$Broadcast
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

# Returns a PowerShell object with .Address and .Selectors (array of bytes4 hex strings)
function Get-Selectors {
    param(
        [string]$Target,   # e.g. contracts/facets/LabFacet.sol:LabFacet
        [string]$Address   # deployed address of that facet
    )

    # Get ABI JSON and filter out warning lines
    $rawAbi = forge inspect $Target abi --json 2>&1 | Out-String
    # Extract just the JSON array part (starts with [ and ends with ])
    if ($rawAbi -match '(\[[\s\S]*\])') {
        $abiJson = $Matches[1] | ConvertFrom-Json
    } else {
        Write-Warning "Could not parse ABI for $Target"
        return [PSCustomObject]@{ Address = $Address; Selectors = @() }
    }
    
    $selectors = @()
    foreach ($item in $abiJson) {
        if ($item.type -eq "function") {
            $inputs = $item.inputs | ForEach-Object { $_.type }
            $sig = "{0}({1})" -f $item.name, ($inputs -join ",")
            $selector = (cast sig $sig 2>$null).Trim()
            if ($selector) { $selectors += $selector }
        }
    }
    return [PSCustomObject]@{
        Address   = $Address
        Selectors = $selectors
    }
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
        cast send $Diamond $calldata --rpc-url $Env:RPC_URL --private-key $Env:PRIVATE_KEY
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

# Deploy base facets and contracts
function Deploy-Contract {
    param(
        [string]$Target,  # e.g. contracts/facets/DiamondCutFacet.sol:DiamondCutFacet
        [array]$ConstructorArgs = @(),
        [hashtable]$Libraries = @{}  # e.g. @{ "contracts/libraries/Lib.sol:Lib" = "0x..." }
    )
    
    if (-not $Broadcast) { 
        Write-Host "[Dry-run] Would deploy $Target"
        return "0xDRY_RUN_ADDRESS"
    }
    
    $forgeArgs = @("create", "--rpc-url", $Env:RPC_URL, "--private-key", $Env:PRIVATE_KEY, "--broadcast")
    
    # Add library links
    foreach ($lib in $Libraries.Keys) {
        $forgeArgs += "--libraries"
        $forgeArgs += "$lib`:$($Libraries[$lib])"
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
$diamondCutFacet = Deploy-Contract "contracts/facets/diamond/DiamondCutFacet.sol:DiamondCutFacet"
Write-Host "DiamondCutFacet deployed at: $diamondCutFacet"

Write-Host "Deploying DiamondInit..."
$diamondInit = Deploy-Contract "contracts/upgradeInitializers/DiamondInit.sol:DiamondInit"
Write-Host "DiamondInit deployed at: $diamondInit"

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

$diamondAddress = Deploy-Contract "contracts/Diamond.sol:Diamond" @($facetCutArg, $diamondArgsArg)
Write-Host "Diamond deployed at: $diamondAddress"

if ($diamondAddress -eq "0xDRY_RUN_ADDRESS") {
    Write-Host "Dry-run mode - stopping here. Use -Broadcast to deploy."
    exit 0
}

Write-Host "Deploying LabERC20..."
$labToken = Deploy-Contract "contracts/external/LabERC20.sol:LabERC20"
Write-Host "LabERC20 deployed at: $labToken"

Write-Host "Initializing LabERC20 with diamond minter..."
$labInitData = cast calldata "initialize(string,address)" "LAB" $diamondAddress
if ($Broadcast) {
    cast send $labToken $labInitData --rpc-url $Env:RPC_URL --private-key $Env:PRIVATE_KEY
} else {
    Write-Output "Dry-run init token:"
    Write-Output "cast send $labToken $labInitData --rpc-url $Env:RPC_URL --private-key $Env:PRIVATE_KEY"
}

# Deploy RivalIntervalTreeLibrary first (required by LabFacet and reservation facets)
Write-Host "Deploying RivalIntervalTreeLibrary..."
$rivalLib = Deploy-Contract "contracts/libraries/RivalIntervalTreeLibrary.sol:RivalIntervalTreeLibrary"
Write-Host "RivalIntervalTreeLibrary deployed at: $rivalLib"

$libLinks = @{ "contracts/libraries/RivalIntervalTreeLibrary.sol:RivalIntervalTreeLibrary" = $rivalLib }

# Deploy facets that DON'T need the library first
$simpleFacets = @(
    "contracts/facets/diamond/DiamondLoupeFacet.sol:DiamondLoupeFacet",
    "contracts/facets/diamond/OwnershipFacet.sol:OwnershipFacet",
    "contracts/facets/ProviderFacet.sol:ProviderFacet",
    "contracts/facets/StakingFacet.sol:StakingFacet",
    "contracts/facets/IntentRegistryFacet.sol:IntentRegistryFacet",
    "contracts/facets/reservation/institutional/InstitutionFacet.sol:InstitutionFacet",
    "contracts/facets/reservation/institutional/InstitutionalOrgRegistryFacet.sol:InstitutionalOrgRegistryFacet",
    "contracts/facets/reservation/institutional/InstitutionalTreasuryFacet.sol:InstitutionalTreasuryFacet",
    "contracts/facets/DistributionFacet.sol:DistributionFacet",
    "contracts/facets/lab/LabAdminFacet.sol:LabAdminFacet",
    "contracts/facets/lab/LabIntentFacet.sol:LabIntentFacet",
    "contracts/facets/lab/LabQueryFacet.sol:LabQueryFacet",
    "contracts/facets/lab/LabIntentFacet.sol:LabIntentFacet",
    "contracts/facets/lab/LabQueryFacet.sol:LabQueryFacet"
)

# Deploy facets that NEED the library
$linkedFacets = @(
    "contracts/facets/lab/LabFacet.sol:LabFacet",
    "contracts/facets/reservation/wallet/WalletReservationFacet.sol:WalletReservationFacet",
    "contracts/facets/reservation/wallet/WalletCancellationFacet.sol:WalletCancellationFacet",
    "contracts/facets/reservation/wallet/WalletPayoutFacet.sol:WalletPayoutFacet",
    "contracts/facets/reservation/wallet/WalletReservationCoreFacet.sol:WalletReservationCoreFacet",
    "contracts/facets/reservation/wallet/WalletConfirmationFacet.sol:WalletConfirmationFacet",
    "contracts/facets/reservation/institutional/InstitutionalConfirmationFacet.sol:InstitutionalConfirmationFacet",
    "contracts/facets/reservation/institutional/InstitutionalReservationCoreFacet.sol:InstitutionalReservationCoreFacet",
    "contracts/facets/reservation/institutional/InstitutionalRequestFacet.sol:InstitutionalRequestFacet",
    "contracts/facets/reservation/institutional/InstitutionalRequestValidationFacet.sol:InstitutionalRequestValidationFacet",
    "contracts/facets/reservation/institutional/InstitutionalRequestCreationFacet.sol:InstitutionalRequestCreationFacet",
    "contracts/facets/reservation/institutional/InstitutionalDenialFacet.sol:InstitutionalDenialFacet",
    "contracts/facets/reservation/institutional/InstitutionalCancellationFacet.sol:InstitutionalCancellationFacet",
    "contracts/facets/reservation/institutional/InstitutionalIntentFacet.sol:InstitutionalIntentFacet",
    "contracts/facets/reservation/institutional/InstitutionalQueryFacet.sol:InstitutionalQueryFacet",
    "contracts/facets/reservation/institutional/InstitutionalReservationFacet.sol:InstitutionalReservationFacet"
)

$facetCuts = @()

foreach ($ft in $simpleFacets) {
    Write-Host "Deploying $ft ..."
    $addr = Deploy-Contract $ft
    Write-Host "$ft deployed at: $addr"
    $facetCuts += Get-Selectors -Target $ft -Address $addr
}

foreach ($ft in $linkedFacets) {
    Write-Host "Deploying $ft (with library link)..."
    $addr = Deploy-Contract $ft -Libraries $libLinks
    Write-Host "$ft deployed at: $addr"
    $facetCuts += Get-Selectors -Target $ft -Address $addr
}

# Filter out duplicate selectors - keep only first occurrence
Write-Host "Filtering duplicate selectors across facets..."
$seenSelectors = @{}
$filteredFacetCuts = @()

foreach ($fc in $facetCuts) {
    $uniqueSelectors = @()
    foreach ($sel in $fc.Selectors) {
        if (-not $seenSelectors.ContainsKey($sel)) {
            $seenSelectors[$sel] = $fc.Address
            $uniqueSelectors += $sel
        } else {
            Write-Host "  Skipping duplicate selector $sel (already in $($seenSelectors[$sel]))"
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

Write-Host "============================================"
Write-Host "Diamond: $diamondAddress"
Write-Host "LabERC20: $labToken"
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
        Write-Warning "SKIPPING $Sig - missing/empty arguments: $($missingArgs -join ', ') (check .env)"
        return
    }
    
    # Build argument list for cast calldata - join with spaces and quote strings
    $quotedArgs = $CallArgs | ForEach-Object { 
        if ($_ -match '^0x[a-fA-F0-9]+$' -or $_ -match '^\d+$') {
            $_  # addresses and numbers don't need quotes
        } else {
            "`"$_`""  # strings need quotes
        }
    }
    $argString = $quotedArgs -join ' '
    $cmd = "cast calldata `"$Sig`" $argString"
    Write-Host "DEBUG CMD: $cmd"
    $calldata = Invoke-Expression $cmd 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $calldata -or $calldata -notmatch '^0x') {
        Write-Warning "SKIPPING $Sig - failed to encode calldata: $calldata"
        return
    }
    
    if ($Broadcast) {
        Write-Host "Calling $Sig on $To..."
        $result = cast send $To $calldata --rpc-url $Env:RPC_URL --private-key $Env:PRIVATE_KEY 2>&1 | Out-String
        if ($result -match "already initialized") {
            Write-Host "  [OK] $Sig - already initialized (skipping)" -ForegroundColor Yellow
        } elseif ($result -match "status\s+1") {
            Write-Host "  [OK] $Sig - success" -ForegroundColor Green
        } elseif ($result -match "error|revert|failed") {
            Write-Warning "  [WARN] $Sig may have failed: check transaction"
            Write-Host $result
        } else {
            Write-Host $result
        }
    } else {
        Write-Output "Dry-run: cast send $To $calldata --rpc-url $Env:RPC_URL --private-key $Env:PRIVATE_KEY"
    }
}

Write-Host "Initializing Diamond facets..."

# Debug: show env vars to verify they loaded
Write-Host "DEBUG ENV: ADMIN_NAME='$Env:ADMIN_NAME' ADMIN_EMAIL='$Env:ADMIN_EMAIL' ADMIN_COUNTRY='$Env:ADMIN_COUNTRY'"
Write-Host "DEBUG ENV: TREASURY_WALLET='$Env:TREASURY_WALLET' SUBSIDIES_WALLET='$Env:SUBSIDIES_WALLET' GOVERNANCE_WALLET='$Env:GOVERNANCE_WALLET'"
Write-Host "DEBUG ENV: PROJECT_TREASURY='$Env:PROJECT_TREASURY' LIQUIDITY_WALLET='$Env:LIQUIDITY_WALLET' ECOSYSTEM_WALLET='$Env:ECOSYSTEM_WALLET'"
Write-Host "DEBUG ENV: TEAM_BENEFICIARY='$Env:TEAM_BENEFICIARY' TIMELOCK_DELAY='$Env:TIMELOCK_DELAY'"

Send-Call -To $diamondAddress -Sig "initialize(string,string,string,address)" -CallArgs @($Env:ADMIN_NAME, $Env:ADMIN_EMAIL, $Env:ADMIN_COUNTRY, $labToken)
Send-Call -To $diamondAddress -Sig "initialize(string,string)" -CallArgs @("DecentraLabs Labs", "DLAB")
Send-Call -To $diamondAddress -Sig "initializeRevenueRecipients(address,address,address)" -CallArgs @($Env:TREASURY_WALLET, $Env:SUBSIDIES_WALLET, $Env:GOVERNANCE_WALLET)
Send-Call -To $diamondAddress -Sig "initializeTokenPools(address,address,address,address,address,address,uint256)" -CallArgs @(
    $Env:PROJECT_TREASURY,
    $Env:SUBSIDIES_WALLET,
    $Env:GOVERNANCE_WALLET,
    $Env:LIQUIDITY_WALLET,
    $Env:ECOSYSTEM_WALLET,
    $Env:TEAM_BENEFICIARY,
    [int]$Env:TIMELOCK_DELAY
)

Write-Host "============================================"
Write-Host "Deployment complete!"
Write-Host "Diamond: $diamondAddress"
Write-Host "LabERC20: $labToken"
Write-Host "============================================"

# Write deployment output file
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$network = if ($Env:RPC_URL -match "sepolia") { "sepolia" } elseif ($Env:RPC_URL -match "mainnet") { "mainnet" } else { "unknown" }
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
        LabERC20 = $labToken
        DiamondCutFacet = $diamondCutFacet
        DiamondInit = $diamondInit
        RivalIntervalTreeLibrary = $rivalLib
    }
    deployer = $Env:DIAMOND_OWNER
    configuration = [ordered]@{
        adminName = $Env:ADMIN_NAME
        adminEmail = $Env:ADMIN_EMAIL
        adminCountry = $Env:ADMIN_COUNTRY
        treasuryWallet = $Env:TREASURY_WALLET
        subsidiesWallet = $Env:SUBSIDIES_WALLET
        governanceWallet = $Env:GOVERNANCE_WALLET
        projectTreasury = $Env:PROJECT_TREASURY
        liquidityWallet = $Env:LIQUIDITY_WALLET
        ecosystemWallet = $Env:ECOSYSTEM_WALLET
        teamBeneficiary = $Env:TEAM_BENEFICIARY
        timelockDelay = [int]$Env:TIMELOCK_DELAY
    }
}

$deployment | ConvertTo-Json -Depth 4 | Set-Content -Path $outputFile -Encoding UTF8
Write-Host ""
Write-Host "Deployment info saved to: $outputFile" -ForegroundColor Cyan

# Also write a latest symlink-style file
$latestFile = Join-Path -Path $outputDir -ChildPath "$network-latest.json"
$deployment | ConvertTo-Json -Depth 4 | Set-Content -Path $latestFile -Encoding UTF8
Write-Host "Latest deployment: $latestFile" -ForegroundColor Cyan