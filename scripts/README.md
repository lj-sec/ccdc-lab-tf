# Helper Scripts

## Disclaimer:

This is still in an extremely early testing stage. This documentation is not complete nor is it fully accurate in its current state.

## What Do They Do?

Replicate (and tear down!) our entire virtualized competition environment via the Proxmox API using the [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest/docs) Terraform provider by using a series of template machines. These templates were generalized versions of the operating systems used within the CCDC competition environment.

## Usage

- This process has been tested and works both on Linux (pwsh 7.0) and Windows (PowerShell 5.1 & pwsh 7.0) clients
- Must have API access to Proxmox server (e.g. ensure you can hit https://pve.example.com/api2/json)
- Must have an API key with proper permissions to authenticate with Proxmox server (formatted like root@pam!terraform=xxxxxxxx)