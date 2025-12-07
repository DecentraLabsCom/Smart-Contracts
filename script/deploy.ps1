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
                [Environment]::SetEnvironmentVariable($key, $val)
            }
        }
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

function DiamondCut {
    param(
        [string]$Diamond,
        [array]$FacetCuts  # array of objects { Address, Selectors }
    )

    $facetsJson = @()
    foreach ($fc in $FacetCuts) {
        $selectorsJson = ($fc.Selectors | ForEach-Object { '"{0}"' -f $_ }) -join ","
        $facetJson = ('{{"facetAddress":"{0}","action":0,"functionSelectors":[{1}]}}' -f $fc.Address, $selectorsJson)
        $facetsJson += $facetJson
    }
    $facetsStr = $facetsJson -join ","
    $cutJson = "[${facetsStr}]"

    $calldata = cast calldata "diamondCut((address,uint8,bytes4[])[],address,bytes)" $cutJson 0x0000000000000000000000000000000000000000 0x
    $cmd = "cast send $Diamond `"$calldata`" --rpc-url $Env:RPC_URL --private-key $Env:PRIVATE_KEY"
    if ($Broadcast) {
        Invoke-Expression $cmd
    } else {
        Write-Output "Dry-run diamondCut command:"
        Write-Output $cmd
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
$diamondCutFacet = Deploy-Contract "contracts/facets/DiamondCutFacet.sol:DiamondCutFacet"
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
    "contracts/facets/DiamondLoupeFacet.sol:DiamondLoupeFacet",
    "contracts/facets/OwnershipFacet.sol:OwnershipFacet",
    "contracts/facets/ProviderFacet.sol:ProviderFacet",
    "contracts/facets/StakingFacet.sol:StakingFacet",
    "contracts/facets/IntentRegistryFacet.sol:IntentRegistryFacet",
    "contracts/facets/InstitutionFacet.sol:InstitutionFacet",
    "contracts/facets/InstitutionalOrgRegistryFacet.sol:InstitutionalOrgRegistryFacet",
    "contracts/facets/InstitutionalTreasuryFacet.sol:InstitutionalTreasuryFacet",
    "contracts/facets/DistributionFacet.sol:DistributionFacet"
)

# Deploy facets that NEED the library
$linkedFacets = @(
    "contracts/facets/LabFacet.sol:LabFacet",
    "contracts/facets/WalletReservationFacet.sol:WalletReservationFacet",
    "contracts/facets/InstitutionalReservationFacet.sol:InstitutionalReservationFacet"
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
        [array]$Args
    )
    $calldata = cast calldata $Sig @Args
    if ($Broadcast) {
        Write-Host "Calling $Sig on $To..."
        cast send $To $calldata --rpc-url $Env:RPC_URL --private-key $Env:PRIVATE_KEY
    } else {
        Write-Output "Dry-run: cast send $To $calldata --rpc-url $Env:RPC_URL --private-key $Env:PRIVATE_KEY"
    }
}

Write-Host "Initializing Diamond facets..."
Send-Call -To $diamondAddress -Sig "initialize(string,string,string,address)" -Args @($Env:ADMIN_NAME, $Env:ADMIN_EMAIL, $Env:ADMIN_COUNTRY, $labToken)
Send-Call -To $diamondAddress -Sig "initialize(string,string)" -Args @("DecentraLabs Labs", "DLAB")
Send-Call -To $diamondAddress -Sig "initializeRevenueRecipients(address,address,address)" -Args @($Env:TREASURY_WALLET, $Env:SUBSIDIES_WALLET, $Env:GOVERNANCE_WALLET)
Send-Call -To $diamondAddress -Sig "initializeTokenPools(address,address,address,address,address,address,uint256)" -Args @(
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