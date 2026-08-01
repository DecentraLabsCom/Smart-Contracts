# powershell -File scripts/prepare-align-sepolia.ps1 -Diamond 0x... -RpcUrl https://...

param(
    [Parameter(Mandatory = $true)]
    [string]$Diamond,
    [string]$RpcUrl,
    [string]$ResumeFile,
    [string]$OutDir = "out"
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
    }
}

function Is-ValidAddress {
    param([string]$Address)
    return $Address -match '^0x[a-fA-F0-9]{40}$'
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content -Path $Path -Raw
    if ($raw.StartsWith([char]0xFEFF)) { $raw = $raw.TrimStart([char]0xFEFF) }
    if (-not $raw.Trim()) { return $null }
    return $raw | ConvertFrom-Json
}

function Get-CanonicalType {
    param($node)
    $type = $node.type
    if ($type -like "tuple*") {
        $suffix = $type.Substring(5)
        $components = @()
        foreach ($component in $node.components) {
            $components += (Get-CanonicalType $component)
        }
        return "(" + ($components -join ",") + ")" + $suffix
    }
    return $type
}

function Get-Selectors {
    param([string]$Target)
    $manifestOutput = node scripts/selector-manifest.cjs --target $Target 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not load selector manifest for $Target: $manifestOutput"
    }
    $manifestEntries = $manifestOutput | ConvertFrom-Json
    return @($manifestEntries | ForEach-Object { $_.selector })
}

Load-Env

if ($RpcUrl) {
    $Env:RPC_URL = $RpcUrl
}

if (-not $Env:RPC_URL) {
    throw "RPC_URL must be defined (or pass -RpcUrl)."
}
if (-not (Is-ValidAddress $Diamond)) {
    throw "Invalid diamond address: $Diamond"
}

$resumePath = $ResumeFile
if (-not $resumePath) { $resumePath = "deployments\\sepolia-resume.json" }
$resume = Read-JsonFile -Path $resumePath
if (-not $resume) {
    throw "Could not read resume file: $resumePath"
}

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$facetMap = @{}
if ($resume.facets) {
    foreach ($prop in $resume.facets.PSObject.Properties) {
        $facetMap[$prop.Name] = $prop.Value
    }
}

# Canonical facet order (matches scripts/upgrade-diamond.ps1)
$simpleFacets = @(
    "contracts/facets/diamond/DiamondCutFacet.sol:DiamondCutFacet",
    "contracts/facets/diamond/DiamondLoupeFacet.sol:DiamondLoupeFacet",
    "contracts/facets/diamond/OwnershipFacet.sol:OwnershipFacet",
    "contracts/facets/InitFacet.sol:InitFacet",
    "contracts/facets/ProviderFacet.sol:ProviderFacet",
    "contracts/facets/IntentRegistryFacet.sol:IntentRegistryFacet",
    "contracts/facets/reservation/institutional/InstitutionFacet.sol:InstitutionFacet",
    "contracts/facets/reservation/institutional/InstitutionalOrgRegistryFacet.sol:InstitutionalOrgRegistryFacet",
    "contracts/facets/reservation/institutional/InstitutionalTreasuryFacet.sol:InstitutionalTreasuryFacet",
    "contracts/facets/lab/LabAdminFacet.sol:LabAdminFacet",
    "contracts/facets/lab/LabIntentFacet.sol:LabIntentFacet",
    "contracts/facets/lab/LabQueryFacet.sol:LabQueryFacet",
    "contracts/facets/lab/LabReputationFacet.sol:LabReputationFacet",
    "contracts/facets/reservation/ReservationCheckInFacet.sol:ReservationCheckInFacet"
)

$linkedFacets = @(
    "contracts/facets/lab/LabFacet.sol:LabFacet",
    "contracts/facets/reservation/ProviderSettlementFacet.sol:ProviderSettlementFacet",
    "contracts/facets/reservation/ReservationDenialFacet.sol:ReservationDenialFacet",
    "contracts/facets/reservation/institutional/InstitutionalReservationConfirmationFacet.sol:InstitutionalReservationConfirmationFacet",
    "contracts/facets/reservation/institutional/InstitutionalReservationRequestValidationFacet.sol:InstitutionalReservationRequestValidationFacet",
    "contracts/facets/reservation/institutional/InstitutionalReservationRequestCreationFacet.sol:InstitutionalReservationRequestCreationFacet",
    "contracts/facets/reservation/institutional/InstitutionalReservationCancellationFacet.sol:InstitutionalReservationCancellationFacet",
    "contracts/facets/reservation/ReservationIntentFacet.sol:ReservationIntentFacet",
    "contracts/facets/reservation/institutional/InstitutionalReservationQueryFacet.sol:InstitutionalReservationQueryFacet",
    "contracts/facets/reservation/institutional/InstitutionalReservationFacet.sol:InstitutionalReservationFacet"
)

$orderedContracts = @()
foreach ($c in ($simpleFacets + $linkedFacets)) {
    if ($facetMap.ContainsKey($c)) { $orderedContracts += $c }
}
foreach ($c in $facetMap.Keys) {
    if ($orderedContracts -notcontains $c) { $orderedContracts += $c }
}

$desiredSelectors = @{}
$facetSelectors = @{}

foreach ($contract in $orderedContracts) {
    $addr = $facetMap[$contract]
    if (-not (Is-ValidAddress $addr)) {
        Write-Warning "Skipping $contract (invalid address: $addr)"
        continue
    }
    $selectors = Get-Selectors -Target $contract
    $facetSelectors[$contract] = $selectors
    foreach ($sel in $selectors) {
        if (-not $desiredSelectors.ContainsKey($sel)) {
            $desiredSelectors[$sel] = $addr
        }
    }
}

$facetCuts = @()

foreach ($contract in $facetSelectors.Keys) {
    $addr = $facetMap[$contract]
    $selectors = $facetSelectors[$contract]
    $add = @()
    $replace = @()
    foreach ($sel in $selectors) {
        if (-not $desiredSelectors.ContainsKey($sel)) { continue }
        if ($desiredSelectors[$sel] -ne $addr) { continue }
        $currentFacet = (cast call $Diamond "facetAddress(bytes4)(address)" $sel --rpc-url $Env:RPC_URL 2>$null).Trim()
        if (-not $currentFacet -or $currentFacet -eq "0x0000000000000000000000000000000000000000") {
            $add += $sel
        } elseif ($currentFacet -ieq $addr) {
            continue
        } else {
            $replace += $sel
        }
    }
    if ($replace.Count -gt 0) {
        $facetCuts += [PSCustomObject]@{ Address = $addr; Action = 1; Selectors = $replace }
    }
    if ($add.Count -gt 0) {
        $facetCuts += [PSCustomObject]@{ Address = $addr; Action = 0; Selectors = $add }
    }
}

# Remove selectors that exist on-chain but are not in local desired set
$onchain = cast call $Diamond "facets()((address,bytes4[])[])" --rpc-url $Env:RPC_URL 2>$null | Out-String
$facetAddresses = @()
if ($onchain) {
    $addrMatches = [regex]::Matches($onchain, '0x[a-fA-F0-9]{40}')
    foreach ($m in $addrMatches) { $facetAddresses += $m.Value }
}
$facetAddresses = $facetAddresses | Select-Object -Unique

$onchainSelectors = @()
foreach ($addr in $facetAddresses) {
    $selsRaw = (cast call $Diamond "facetFunctionSelectors(address)(bytes4[])" $addr --rpc-url $Env:RPC_URL 2>$null).Trim()
    if (-not $selsRaw) { continue }
    $selMatches = [regex]::Matches($selsRaw, '0x[a-fA-F0-9]{8}')
    foreach ($m in $selMatches) { $onchainSelectors += $m.Value }
}

$remove = @()
foreach ($sel in ($onchainSelectors | Select-Object -Unique)) {
    if (-not $desiredSelectors.ContainsKey($sel)) {
        $remove += $sel
    }
}
if ($remove.Count -gt 0) {
    $facetCuts += [PSCustomObject]@{
        Address   = "0x0000000000000000000000000000000000000000"
        Action    = 2
        Selectors = $remove
    }
}

$outJson = Join-Path $OutDir "diamondCut-align.json"
$facetCuts | ConvertTo-Json -Depth 8 | Out-File -FilePath $outJson -Encoding utf8

Write-Host "Facet cuts: $($facetCuts.Count)"
Write-Host "Saved: $outJson"

if ($facetCuts.Count -gt 0) {
    $tuples = @()
    foreach ($fc in $facetCuts) {
        $sels = $fc.Selectors -join ","
        $tuples += "($($fc.Address),$($fc.Action),[$sels])"
    }
    $cutArg = "[" + ($tuples -join ",") + "]"
    $calldata = cast calldata "diamondCut((address,uint8,bytes4[])[],address,bytes)" $cutArg 0x0000000000000000000000000000000000000000 0x 2>&1
    $outCalldata = Join-Path $OutDir "diamondCut-align-calldata.txt"
    $calldata | Out-File -FilePath $outCalldata -Encoding ascii
    Write-Host "Saved calldata: $outCalldata"
} else {
    Write-Host "No facet cuts required."
}
