<div align="center">

<p>
  <img src=".github/images/environment.png" width="300" alt="Environment reference">
</p>

<p align="center">
  <a href="https://developer.hashicorp.com/terraform">
   <img src="https://img.shields.io/badge/Terraform-844FBA?logo=terraform&logoColor=fff"
   class="d-inline-block mb-2"
   alt="Terraform logo badge"
   loading="lazy" decoding="async" />
  </a>
  <a href="https://microsoft.com/powershell">
    <img src="https://custom-icon-badges.demolab.com/badge/PowerShell-5391FE?logo=powershell-white&logoColor=fff" class="d-inline-block mb-2" alt="PowerShell logo badge" loading="lazy" decoding="async" />
  </a>
</p>

# CCDC at EKU's Terraform Lab Automation (Proxmox)
</div>

## Disclaimer
This repository contains configurations specific to how our Proxmox environment is set up, and is developed for the sole purposes of cloning and tearing down *our* working environment for practice competitions. This will not work on other systems. It is open-source as a potential reference for other teams or colleagues down the line.

## Repo Layout

```text
ccdc-lab-tf/
├─ scripts/
│  ├─ Invoke-TfClones.ps1        # Helper: generate inputs + run creation workflow
│  └─ Invoke-TfTeardown.ps1      # Helper: tear down workflow
├─ tf/
│  ├─ clones.auto.tfvars         # Auto-loaded variable values (generated or maintained)
│  ├─ main.tf                    # Primary Terraform definitions
│  ├─ provider.tf                # Provider configuration
│  ├─ variables.tf               # Input variables (types/defaults/descriptions)
│  └─ versions.tf                # Terraform/provider version artifacts
├─ .gitignore
└─ README.md
```

## What Does it Do?

Replicates (and tears down!) our entire virtualized competition environment via the Proxmox API using the [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest/docs) Terraform provider by using a series of "golden" virtual machines. These "golden" machines are powered off, with the sole purpose of being cloned. Their VM ID's, our node name, and our datastore name are hardcoded within the Invoke-TfClones.ps1 script.

The Invoke-TfClones.ps1 script will generate the necessary .tfvars file that Terraform needs to init and plan its changes against the server, and will then prompt you to apply said changes.

The Invoke-TfTeardown.ps1 script will revert those changes, destroying the clones, returning the environment as it was before.

Please read over the documentation and comments within the PowerShell scripts, as it may provide a better understanding of how this process works.

## Usage

- This process has been tested and works both on Linux (pwsh 7.0) and Windows (PowerShell 5.1 & pwsh 7.0) clients
- Must have API access to Proxmox server (e.g. ensure you can hit https://pve.example.com/api2/json)
- Must have an API key with proper permissions to authenticate with Proxmox server (formatted like root@pam!terraform=xxxxxxxx)

## Commands

If on Linux:
```powershell
pwsh
```
Clone this repository, then:
```powershell
cd .\ccdc-lab-tf\scripts
# To Create Clones
.\Invoke-TfClones.ps1 -VmIdStart 200 -TeamNumber 2 `
    -TerraformPath "D:\terraform_1.14.5_windows_amd64\terraform.exe" `
    -ProxmoxEndpoint "https://pve.example.com:8006/" `
    -ProxmoxApiToken "root@pam!terraform=xxxxxxxx"
# To Teardown
.\Invoke-TfTeardown.ps1 -TerraformPath "terraform" # If terraform is in your path, this is fine
```

## To-Do

- Add scripts to this or another repository that help with automating standing up the environment
- Make multiple environments stand at the same time with new, separate network bridges