# Helper Scripts

## Disclaimer:

This is still in an extremely early testing stage. This documentation is not complete nor is it fully accurate in its current state.

## What Do They Do?

Replicate (and tear down!) our entire virtualized competition environment via the Proxmox API using the [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest/docs) Terraform provider by using a series of template machines. These templates were generalized versions of the operating systems used within the CCDC competitio environment. Their VM ID's, our node name, and our datastore name are hardcoded within the Invoke-TfClones.ps1 script.

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