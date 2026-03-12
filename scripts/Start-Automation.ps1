<#
.SYNOPSIS
    This is a placeholder for the time being!
    Eventually, this will take in a team number and invoke the terraform -> ansible pipeline
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 99)]
    [int]$TeamNumber,

    [string]$BlueprintPath,
    [string]$RepoRoot,

    [string]$ProxmoxEndpoint = $env:PROXMOX_ENDPOINT,
    [string]$ProxmoxApiToken = $env:PROXMOX_API_TOKEN,
    [string]$NodeName        = $env:PROXMOX_NODE_NAME,
    [string]$DatastoreId     = $env:PROXMOX_DATASTORE_ID,

    [switch]$SkipTerraformInit,
    [switch]$SkipTerraformApply,
    [switch]$SkipCollectionsInstall,
    [switch]$SkipReadinessChecks,
    [switch]$SkipAnsible
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ----------------------------
# Path setup
# ----------------------------
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
} else {
    $RepoRoot = (Resolve-Path $RepoRoot).Path
}

if (-not $BlueprintPath) {
    $BlueprintPath = Join-Path $RepoRoot "environments/blue-team.yaml"
}

$TerraformDir    = Join-Path $RepoRoot "infra/terraform"
$AnsibleDir      = Join-Path $RepoRoot "infra/ansible"
$RequirementsYml = Join-Path $AnsibleDir "requirements.yaml"

$TeamLabel = "team{0:D2}" -f $TeamNumber
$BuildDir  = Join-Path $RepoRoot "build/$TeamLabel"

$ResolvedEnvironmentPath = Join-Path $BuildDir "resolved-environment.yaml"
$InventoryPath           = Join-Path $BuildDir "hosts.yaml"
$TeamVarsPath            = Join-Path $BuildDir "team-vars.yaml"

# ----------------------------
# Helpers
# ----------------------------
function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Required command '$Name' was not found in PATH."
    }

    $cmd.Source
}

function Import-YamlFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "YAML file not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw

    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        throw "ConvertFrom-Yaml is not available. Install a YAML-capable PowerShell module or use a PowerShell version that provides ConvertFrom-Yaml/ConvertTo-Yaml."
    }

    $raw | ConvertFrom-Yaml -Ordered
}

function Export-YamlFile {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Path
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (-not (Get-Command ConvertTo-Yaml -ErrorAction SilentlyContinue)) {
        throw "ConvertTo-Yaml is not available. Install a YAML-capable PowerShell module or use a PowerShell version that provides ConvertFrom-Yaml/ConvertTo-Yaml."
    }

    $yaml = $Object | ConvertTo-Yaml
    Set-Content -LiteralPath $Path -Value $yaml -Encoding UTF8
}

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$WorkingDirectory
    )

    Write-Host ""
    Write-Host ">>> $FilePath $($ArgumentList -join ' ')"

    $oldLocation = Get-Location
    try {
        if ($WorkingDirectory) {
            Set-Location -LiteralPath $WorkingDirectory
        }

        & $FilePath @ArgumentList
        $exitCode = $LASTEXITCODE
    }
    finally {
        Set-Location -LiteralPath $oldLocation
    }

    if ($exitCode -ne 0) {
        throw "Command failed with exit code $exitCode: $FilePath"
    }
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$TargetPath
    )

    [System.IO.Path]::GetRelativePath($BasePath, $TargetPath).Replace("\", "/")
}

function Resolve-TokenString {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory)][hashtable]$Tokens
    )

    if ($null -eq $Value) { return $null }

    $result = $Value
    foreach ($key in $Tokens.Keys) {
        $result = $result.Replace("{{ $key }}", [string]$Tokens[$key])
        $result = $result.Replace("{{${key}}}", [string]$Tokens[$key])
    }

    return $result
}

function Resolve-Deep {
    param(
        $InputObject,
        [Parameter(Mandatory)][hashtable]$Tokens
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [string]) {
        return (Resolve-TokenString -Value $InputObject -Tokens $Tokens)
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $out[$key] = Resolve-Deep -InputObject $InputObject[$key] -Tokens $Tokens
        }
        return $out
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $list = @()
        foreach ($item in $InputObject) {
            $list += ,(Resolve-Deep -InputObject $item -Tokens $Tokens)
        }
        return $list
    }

    if ($InputObject.PSObject -and $InputObject.PSObject.Properties.Count -gt 0) {
        $out = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $out[$prop.Name] = Resolve-Deep -InputObject $prop.Value -Tokens $Tokens
        }
        return $out
    }

    return $InputObject
}

function Get-PublicIp {
    param(
        [Parameter(Mandatory)]$PublicConfig,
        [Parameter(Mandatory)][int]$TeamNumber,
        [Parameter(Mandatory)][int]$LastOctet
    )

    $oct1 = [int]$PublicConfig.octet_1
    $oct2 = [int]$PublicConfig.octet_2
    $oct3 = [int]$PublicConfig.third_octet_base + $TeamNumber

    return "$oct1.$oct2.$oct3.$LastOctet"
}

function Resolve-EnvironmentManifest {
    param(
        [Parameter(Mandatory)]$Blueprint,
        [Parameter(Mandatory)][int]$TeamNumber
    )

    $vmIdStride = if ($Blueprint.globals.vm_id_stride) { [int]$Blueprint.globals.vm_id_stride } else { 100 }
    $teamTagPrefix = if ($Blueprint.globals.team_tag_prefix) { [string]$Blueprint.globals.team_tag_prefix } else { "team" }
    $teamTag = "$teamTagPrefix$TeamNumber"

    $resolvedVms = @()

    foreach ($vm in $Blueprint.vms) {
        if ($vm.enabled -eq $false) {
            continue
        }

        $tokens = @{
            team        = $TeamNumber
            team_padded = "{0:D2}" -f $TeamNumber
            team_tag    = $teamTag
        }

        $resolved = Resolve-Deep -InputObject $vm -Tokens $tokens

        if ($resolved.Contains("vm_id_base")) {
            $resolved.vm_id = [int]$resolved.vm_id_base + (($TeamNumber - 1) * $vmIdStride)
            $resolved.Remove("vm_id_base")
        }

        if (-not $resolved.Contains("vm_id")) {
            throw "VM '$($resolved.key)' must define either vm_id or vm_id_base."
        }

        if (-not $resolved.Contains("tags")) {
            $resolved.tags = @()
        }

        if ($resolved.tags -notcontains $teamTag) {
            $resolved.tags = @($resolved.tags) + $teamTag
        }

        if ($resolved.Contains("inventory")) {
            if ($resolved.inventory.Contains("public_ip_override")) {
                $resolved.inventory.ansible_host = [string]$resolved.inventory.public_ip_override
            }
            elseif ($resolved.inventory.Contains("public_ip_last_octet")) {
                $resolved.inventory.ansible_host = Get-PublicIp `
                    -PublicConfig $Blueprint.globals.public_ip_formula `
                    -TeamNumber $TeamNumber `
                    -LastOctet ([int]$resolved.inventory.public_ip_last_octet)
            }

            if (-not $resolved.inventory.Contains("ansible_user") -and $resolved.Contains("admin_username")) {
                $resolved.inventory.ansible_user = $resolved.admin_username
            }

            if (-not $resolved.inventory.Contains("ansible_password") -and $resolved.Contains("admin_password")) {
                $resolved.inventory.ansible_password = $resolved.admin_password
            }
        }

        $resolvedVms += ,$resolved
    }

    return [ordered]@{
        meta = [ordered]@{
            source_blueprint = $BlueprintPath
            team_number      = $TeamNumber
            team_tag         = $teamTag
            generated_at     = (Get-Date).ToString("s")
        }
        globals = Resolve-Deep -InputObject $Blueprint.globals -Tokens @{
            team        = $TeamNumber
            team_padded = "{0:D2}" -f $TeamNumber
            team_tag    = $teamTag
        }
        vms = $resolvedVms
    }
}

function New-AnsibleInventory {
    param([Parameter(Mandatory)]$ResolvedManifest)

    $children = [ordered]@{}

    foreach ($vm in $ResolvedManifest.vms) {
        if (-not $vm.Contains("inventory")) {
            continue
        }

        if (-not $vm.inventory.Contains("ansible_host")) {
            continue
        }

        $hostName = if ($vm.inventory.Contains("inventory_name")) {
            [string]$vm.inventory.inventory_name
        } else {
            [string]$vm.vm_name
        }

        $hostVars = [ordered]@{
            ansible_host = $vm.inventory.ansible_host
        }

        if ($vm.inventory.Contains("ansible_user")) {
            $hostVars.ansible_user = $vm.inventory.ansible_user
        }

        if ($vm.inventory.Contains("ansible_password")) {
            $hostVars.ansible_password = $vm.inventory.ansible_password
        }

        $groups = @()
        if ($vm.inventory.Contains("groups")) {
            $groups = @($vm.inventory.groups)
        }

        foreach ($group in $groups) {
            if (-not $children.Contains($group)) {
                $children[$group] = [ordered]@{
                    hosts = [ordered]@{}
                }
            }

            $children[$group].hosts[$hostName] = $hostVars
        }
    }

    # Group-level defaults from blueprint globals
    if ($ResolvedManifest.globals.ansible_defaults.windows) {
        if (-not $children.Contains("windows")) {
            $children["windows"] = [ordered]@{ hosts = [ordered]@{} }
        }
        $children["windows"]["vars"] = [ordered]$ResolvedManifest.globals.ansible_defaults.windows
    }

    if ($ResolvedManifest.globals.ansible_defaults.linux) {
        if (-not $children.Contains("linux")) {
            $children["linux"] = [ordered]@{ hosts = [ordered]@{} }
        }
        $children["linux"]["vars"] = [ordered]$ResolvedManifest.globals.ansible_defaults.linux
    }

    return [ordered]@{
        all = [ordered]@{
            children = $children
        }
    }
}

function New-TeamVars {
    param(
        [Parameter(Mandatory)]$ResolvedManifest,
        [Parameter(Mandatory)][int]$TeamNumber
    )

    return [ordered]@{
        team_number = $TeamNumber
        team_tag    = "team$TeamNumber"
    }
}

function Get-UniquePlaybooks {
    param([Parameter(Mandatory)]$ResolvedManifest)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $playbooks = New-Object 'System.Collections.Generic.List[string]'

    foreach ($vm in $ResolvedManifest.vms) {
        if (-not $vm.Contains("ansible")) { continue }
        if (-not $vm.ansible.Contains("playbooks")) { continue }

        foreach ($playbook in @($vm.ansible.playbooks)) {
            if ($seen.Add([string]$playbook)) {
                $playbooks.Add([string]$playbook) | Out-Null
            }
        }
    }

    return $playbooks
}

function Wait-ForAnsibleGroup {
    param(
        [Parameter(Mandatory)][string]$AnsibleExe,
        [Parameter(Mandatory)][string]$InventoryPath,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][string]$ModuleName,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 900,
        [int]$PollSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $oldLocation = Get-Location
        try {
            Set-Location -LiteralPath $WorkingDirectory
            & $AnsibleExe $GroupName "-i" $InventoryPath "-m" $ModuleName
            $exitCode = $LASTEXITCODE
        }
        finally {
            Set-Location -LiteralPath $oldLocation
        }

        if ($exitCode -eq 0) {
            return
        }

        Start-Sleep -Seconds $PollSeconds
    }

    throw "Timed out waiting for Ansible group '$GroupName' to become reachable."
}

# ----------------------------
# Preconditions
# ----------------------------
if (-not (Test-Path -LiteralPath $BlueprintPath)) {
    throw "Blueprint file not found: $BlueprintPath"
}

if ([string]::IsNullOrWhiteSpace($ProxmoxEndpoint)) { throw "Missing Proxmox endpoint." }
if ([string]::IsNullOrWhiteSpace($ProxmoxApiToken)) { throw "Missing Proxmox API token." }
if ([string]::IsNullOrWhiteSpace($NodeName))        { throw "Missing Proxmox node name." }
if ([string]::IsNullOrWhiteSpace($DatastoreId))     { throw "Missing datastore ID." }

$terraformExe       = Assert-Command "terraform"
$ansibleExe         = $null
$ansiblePlaybookExe = $null
$ansibleGalaxyExe   = $null

if (-not $SkipAnsible) {
    $ansibleExe         = Assert-Command "ansible"
    $ansiblePlaybookExe = Assert-Command "ansible-playbook"

    if (-not $SkipCollectionsInstall) {
        $ansibleGalaxyExe = Assert-Command "ansible-galaxy"
    }
}

# ----------------------------
# Resolve blueprint -> concrete team manifest
# ----------------------------
$blueprint = Import-YamlFile -Path $BlueprintPath
$resolvedManifest = Resolve-EnvironmentManifest -Blueprint $blueprint -TeamNumber $TeamNumber
$inventory = New-AnsibleInventory -ResolvedManifest $resolvedManifest
$teamVars  = New-TeamVars -ResolvedManifest $resolvedManifest -TeamNumber $TeamNumber

Export-YamlFile -Object $resolvedManifest -Path $ResolvedEnvironmentPath
Export-YamlFile -Object $inventory        -Path $InventoryPath
Export-YamlFile -Object $teamVars         -Path $TeamVarsPath

Write-Host ""
Write-Host "Blueprint            : $BlueprintPath"
Write-Host "Resolved environment : $ResolvedEnvironmentPath"
Write-Host "Inventory            : $InventoryPath"
Write-Host "Team vars            : $TeamVarsPath"

# ----------------------------
# Terraform
# ----------------------------
$oldTfVars = @{
    TF_VAR_proxmox_endpoint  = $env:TF_VAR_proxmox_endpoint
    TF_VAR_proxmox_api_token = $env:TF_VAR_proxmox_api_token
    TF_VAR_node_name         = $env:TF_VAR_node_name
    TF_VAR_datastore_id      = $env:TF_VAR_datastore_id
}

$env:TF_VAR_proxmox_endpoint  = $ProxmoxEndpoint
$env:TF_VAR_proxmox_api_token = $ProxmoxApiToken
$env:TF_VAR_node_name         = $NodeName
$env:TF_VAR_datastore_id      = $DatastoreId

try {
    $relativeResolvedEnvironmentPath = Get-RelativePath -BasePath $TerraformDir -TargetPath $ResolvedEnvironmentPath

    if (-not $SkipTerraformInit) {
        Invoke-External -FilePath $terraformExe -ArgumentList @("init", "-input=false") -WorkingDirectory $TerraformDir
    }

    if (-not $SkipTerraformApply) {
        Invoke-External `
            -FilePath $terraformExe `
            -ArgumentList @(
                "apply",
                "-auto-approve",
                "-input=false",
                "-var", "vm_specs_file=$relativeResolvedEnvironmentPath"
            ) `
            -WorkingDirectory $TerraformDir
    }

    # ----------------------------
    # Ansible
    # ----------------------------
    if (-not $SkipAnsible) {
        if ((-not $SkipCollectionsInstall) -and (Test-Path -LiteralPath $RequirementsYml)) {
            Invoke-External `
                -FilePath $ansibleGalaxyExe `
                -ArgumentList @("collection", "install", "-r", $RequirementsYml) `
                -WorkingDirectory $AnsibleDir
        }

        if (-not $SkipReadinessChecks) {
            $inventoryObject = Import-YamlFile -Path $InventoryPath
            $groups = @()
            if ($inventoryObject.all.children.Contains("windows")) { $groups += "windows" }
            if ($inventoryObject.all.children.Contains("linux"))   { $groups += "linux" }

            if ($groups -contains "windows") {
                Wait-ForAnsibleGroup `
                    -AnsibleExe $ansibleExe `
                    -InventoryPath $InventoryPath `
                    -GroupName "windows" `
                    -ModuleName "ansible.windows.win_ping" `
                    -WorkingDirectory $AnsibleDir
            }

            if ($groups -contains "linux") {
                Wait-ForAnsibleGroup `
                    -AnsibleExe $ansibleExe `
                    -InventoryPath $InventoryPath `
                    -GroupName "linux" `
                    -ModuleName "ansible.builtin.ping" `
                    -WorkingDirectory $AnsibleDir
            }
        }

        $playbooks = Get-UniquePlaybooks -ResolvedManifest $resolvedManifest

        foreach ($playbook in $playbooks) {
            $playbookPath = Join-Path $AnsibleDir $playbook

            Invoke-External `
                -FilePath $ansiblePlaybookExe `
                -ArgumentList @(
                    "-i", $InventoryPath,
                    "-e", "@$TeamVarsPath",
                    $playbookPath
                ) `
                -WorkingDirectory $AnsibleDir
        }
    }
}
finally {
    $env:TF_VAR_proxmox_endpoint  = $oldTfVars.TF_VAR_proxmox_endpoint
    $env:TF_VAR_proxmox_api_token = $oldTfVars.TF_VAR_proxmox_api_token
    $env:TF_VAR_node_name         = $oldTfVars.TF_VAR_node_name
    $env:TF_VAR_datastore_id      = $oldTfVars.TF_VAR_datastore_id
}