<#
.SYNOPSIS
  Generates Terraform tfvars in the new `vms` map format and runs Terraform for Proxmox clones.

.DESCRIPTION
  This script writes `infra/tf/clones.auto.tfvars` that matches `infra/tf/variables.tf`:
  - static values: proxmox_endpoint, proxmox_api_token, proxmox_insecure, node_name, datastore_id, tags
  - per-VM map: vms = { ... }

  Per-VM definitions are loaded from a JSON file so each VM can define its own template ID,
  VMID, name, bridge(s), IP, DNS, credentials, and optional tags.

.EXAMPLE
  .\Invoke-TfClones.ps1 \
    -ProxmoxApiToken "root@pam!terraform=xxxxxxxx" \
    -VmSpecPath ".\vm-specs.json"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$ProxmoxApiToken,

  [Parameter(Mandatory)]
  [string]$VmSpecPath,

  [Parameter()]
  [string]$TerraformPath = "terraform", # Assumes terraform is in the Path

  [Parameter()]
  [string]$ProxmoxEndpoint = "https://ccdcpve.eku.edu",

  [Parameter()]
  [bool]$ProxmoxInsecure = $true,

  [Parameter()]
  [string]$NodeName = "ccdcpve",

  [Parameter()]
  [string]$DatastoreId = "local-lvm",

  [Parameter()]
  [string[]]$DefaultTags = @("terraform"),

  [Parameter()]
  [string]$TerraformDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'infra', 'tf')),

  [Parameter()]
  [switch]$AutoApprove
)

$ErrorActionPreference = "Stop"

function Test-Executable {
  param([Parameter(Mandatory)][string]$CommandOrPath)

  $onWindows = if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) {
    $IsWindows
  } else {
    $env:OS -eq 'Windows_NT'
  }

  if ($onWindows -and (Test-Path -LiteralPath $CommandOrPath)) {
    if ([IO.Path]::GetExtension($CommandOrPath) -ne '.exe') {
      throw "Expected a .exe at: $CommandOrPath"
    }
    return
  }

  $cmd = Get-Command -Name $CommandOrPath -ErrorAction SilentlyContinue
  if (-not $cmd -and -not (Test-Path -LiteralPath $CommandOrPath)) {
    throw "Command not found in PATH and file not found at: $CommandOrPath"
  }
}

function Escape-HclString {
  param([Parameter(Mandatory)][string]$Value)
  return ($Value -replace '\\', '\\\\' -replace '"', '\\"')
}

function ConvertTo-HclStringList {
  param([Parameter(Mandatory)][string[]]$Values)
  $quoted = $Values | ForEach-Object { '"{0}"' -f (Escape-HclString -Value $_) }
  return "[{0}]" -f ($quoted -join ", ")
}

function Get-RequiredProperty {
  param(
    [Parameter(Mandatory)]$Object,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$VmKey
  )

  $prop = $Object.PSObject.Properties[$Name]
  if (-not $prop -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
    throw "VM '$VmKey' is missing required property '$Name' in $VmSpecPath"
  }

  return $prop.Value
}

Test-Executable -CommandOrPath $TerraformPath

if (-not (Test-Path -LiteralPath $TerraformDir)) {
  throw "TerraformDir not found: $TerraformDir"
}
if (-not (Test-Path -LiteralPath $VmSpecPath)) {
  throw "VmSpecPath not found: $VmSpecPath"
}

$specRaw = Get-Content -LiteralPath $VmSpecPath -Raw
$vmSpecs = $specRaw | ConvertFrom-Json

if ($null -eq $vmSpecs) {
  throw "No VM specs found in $VmSpecPath"
}

if ($vmSpecs -isnot [System.Collections.IEnumerable] -or $vmSpecs -is [string]) {
  $vmSpecs = @($vmSpecs)
}

if ($vmSpecs.Count -eq 0) {
  throw "VM spec list is empty in $VmSpecPath"
}

$vmBlocks = New-Object System.Collections.Generic.List[string]
foreach ($vm in $vmSpecs) {
  $key = Get-RequiredProperty -Object $vm -Name "key" -VmKey "unknown"

  $templateVmId = [int](Get-RequiredProperty -Object $vm -Name "template_vm_id" -VmKey $key)
  $vmId         = [int](Get-RequiredProperty -Object $vm -Name "vm_id" -VmKey $key)
  $vmName       = [string](Get-RequiredProperty -Object $vm -Name "vm_name" -VmKey $key)
  $ipv4Address  = [string](Get-RequiredProperty -Object $vm -Name "ipv4_address" -VmKey $key)
  $ipv4Prefix   = [int](Get-RequiredProperty -Object $vm -Name "ipv4_prefix" -VmKey $key)
  $ipv4Gateway  = [string](Get-RequiredProperty -Object $vm -Name "ipv4_gateway" -VmKey $key)
  $dnsServer    = [string](Get-RequiredProperty -Object $vm -Name "dns_server" -VmKey $key)

  $bridge = $null
  if ($vm.PSObject.Properties['bridge']) {
    $bridge = [string]$vm.bridge
  }

  $bridges = @()
  if ($vm.PSObject.Properties['bridges'] -and $null -ne $vm.bridges) {
    $bridges = @($vm.bridges | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }

  if ([string]::IsNullOrWhiteSpace($bridge) -and $bridges.Count -eq 0) {
    throw "VM '$key' must define either 'bridge' or at least one item in 'bridges'"
  }

  $adminUsername = if ($vm.PSObject.Properties['admin_username'] -and -not [string]::IsNullOrWhiteSpace([string]$vm.admin_username)) {
    [string]$vm.admin_username
  } else {
    "Administrator"
  }

  $defaultPassword = if ($vm.PSObject.Properties['default_password'] -and -not [string]::IsNullOrWhiteSpace([string]$vm.default_password)) {
    [string]$vm.admin_username
  } else {
    "!Password123"
  }

  $vmTags = if ($vm.PSObject.Properties['tags'] -and $null -ne $vm.tags) {
    @($vm.tags | ForEach-Object { [string]$_ })
  } else {
    @()
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("    `"$(Escape-HclString -Value $key)`" = {")
  $lines.Add("      template_vm_id = $templateVmId")
  $lines.Add("      vm_id          = $vmId")
  $lines.Add("      vm_name        = `"$(Escape-HclString -Value $vmName)`"")

  if (-not [string]::IsNullOrWhiteSpace($bridge)) {
    $lines.Add("      bridge         = `"$(Escape-HclString -Value $bridge)`"")
  }
  if ($bridges.Count -gt 0) {
    $lines.Add("      bridges        = $(ConvertTo-HclStringList -Values $bridges)")
  }

  $lines.Add("      ipv4_address   = `"$(Escape-HclString -Value $ipv4Address)`"")
  $lines.Add("      ipv4_prefix    = $ipv4Prefix")
  $lines.Add("      ipv4_gateway   = `"$(Escape-HclString -Value $ipv4Gateway)`"")
  $lines.Add("      dns_server     = `"$(Escape-HclString -Value $dnsServer)`"")
  $lines.Add("      admin_username = `"$(Escape-HclString -Value $adminUsername)`"")
  $lines.Add("      admin_password = `"$(Escape-HclString -Value $defaultPassword)`"")

  if ($vmTags.Count -gt 0) {
    $lines.Add("      tags           = $(ConvertTo-HclStringList -Values $vmTags)")
  }

  $lines.Add("    }")
  $vmBlocks.Add(($lines -join [Environment]::NewLine))
}

$tfvarsPath = Join-Path $TerraformDir "clones.auto.tfvars"
$planPath   = Join-Path $TerraformDir "tfplan"

$tfvarsContent = @"
proxmox_endpoint  = "$(Escape-HclString -Value $ProxmoxEndpoint)"
proxmox_api_token = "$(Escape-HclString -Value $ProxmoxApiToken)"
proxmox_insecure  = $($ProxmoxInsecure.ToString().ToLowerInvariant())

node_name    = "$(Escape-HclString -Value $NodeName)"
datastore_id = "$(Escape-HclString -Value $DatastoreId)"
tags         = $(ConvertTo-HclStringList -Values $DefaultTags)

vms = {
$($vmBlocks -join [Environment]::NewLine)
}
"@

$tfvarsContent | Out-File -FilePath $tfvarsPath -Encoding utf8 -Force -NoNewline
Write-Host "Wrote $tfvarsPath"

& $TerraformPath -chdir="$TerraformDir" init
if ($LASTEXITCODE -ne 0) { throw "terraform init failed" }

& $TerraformPath -chdir="$TerraformDir" plan -var-file="$tfvarsPath" -out="$planPath"
if ($LASTEXITCODE -ne 0) { throw "terraform plan failed" }

if ($AutoApprove) {
  & $TerraformPath -chdir="$TerraformDir" apply -auto-approve "$planPath"
  if ($LASTEXITCODE -ne 0) { throw "terraform apply failed" }
  exit 0
}

$confirmation = Read-Host "Apply changes? (y/N)"
if ($confirmation -ine "y") {
  Write-Host "Cancelled before apply."
  exit 0
}

& $TerraformPath -chdir="$TerraformDir" apply "$planPath"
if ($LASTEXITCODE -ne 0) { throw "terraform apply failed" }

exit 0