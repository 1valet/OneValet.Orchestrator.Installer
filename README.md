# 1VALET Orchestrator installer

Sets up the 1VALET orchestrator on a new machine: git, SSH access to Azure DevOps, a clone of the orchestrator
(private, on Azure DevOps: `1Valet-BAS/OneValet.Orchestrator`), a launcher, then its start script. You need an
Azure DevOps account in the `onevalet` organization.

macOS, Linux or WSL:

```sh
curl -fsSL https://raw.githubusercontent.com/1valet/OneValet.Orchestrator.Installer/main/install.sh | bash
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/1valet/OneValet.Orchestrator.Installer/main/install.ps1 | iex
```

These files are copies: the source is `install.sh` and `install.ps1` in the orchestrator repo. Change them there.
