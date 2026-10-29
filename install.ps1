# Install the 1VALET orchestrator on a new Windows machine: Git for Windows, SSH access to Azure DevOps, a clone of
# this repo, Start menu and Desktop shortcuts, then start.ps1. macOS/Linux/WSL: install.sh. A copy is published in
# the public GitHub repo 1valet/OneValet.Orchestrator.Installer, so it runs without git or an Azure DevOps sign-in:
#
#   irm https://raw.githubusercontent.com/1valet/OneValet.Orchestrator.Installer/main/install.ps1 | iex
#
# Run again, it updates the clone (fast-forward only) and runs start. $env:ONEVALET_DIR sets the folder.
# Native commands report failure through $LASTEXITCODE; ErrorActionPreference stays at Continue (see start.ps1).

& {
$RepoUrl = 'onevalet@vs-ssh.visualstudio.com:v3/onevalet/1Valet-BAS/OneValet.Orchestrator'
$VstsKey = Join-Path $HOME '.ssh\onevalet_vsts_rsa'
$VstsKeysUrl = 'https://dev.azure.com/onevalet/_usersSettings/keys'
$AppName = '1VALET Orchestrator'

function Die($message) { Write-Host "error: $message" -ForegroundColor Red; throw $message }
function Info($message) { Write-Host "==> $message" }
function Update-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
}

function Install-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) { return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die 'git is missing and so is winget: install Git for Windows (https://git-scm.com/download/win), then run this again'
    }
    Info 'Installing Git for Windows (winget)'
    winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements
    Update-Path
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die 'git installed but not found; open a new terminal and run this again' }
}

# The same order as start.ps1: the user's own SSH setup, then $VstsKey, created and registered if needed.
function Get-SshCommand($mode) {
    if ($mode -eq 'key') { return "ssh -i '$($VstsKey -replace '\\', '/')' -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" }
    return 'ssh -o StrictHostKeyChecking=accept-new'
}
function Test-Access($mode) {
    $env:GIT_SSH_COMMAND = "$(Get-SshCommand $mode) -o BatchMode=yes"
    git ls-remote $RepoUrl HEAD 2>&1 | Out-Null
    $ok = $LASTEXITCODE -eq 0
    Remove-Item Env:GIT_SSH_COMMAND
    return $ok
}
function Find-SshKeygen {
    $cmd = Get-Command ssh-keygen -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path (Split-Path (Split-Path (Get-Command git).Source)) 'usr\bin\ssh-keygen.exe'
    if (Test-Path $candidate) { return $candidate }
    Die 'ssh-keygen not found; install OpenSSH Client (Settings > Optional features)'
}
function Confirm-Access {
    if (Test-Access 'default') { return 'default' }
    while (-not ((Test-Path $VstsKey) -and (Test-Access 'key'))) {
        if (-not (Test-Path $VstsKey)) {
            New-Item -ItemType Directory -Force (Split-Path $VstsKey) | Out-Null
            Info "Creating an SSH key for Azure DevOps: $VstsKey"
            # One argument string, passed verbatim, so the empty passphrase survives every PowerShell version.
            $keygenArgs = "-q -t rsa -b 4096 -N `"`" -C `"$env:USERNAME@$env:COMPUTERNAME 1VALET Azure DevOps`" -f `"$VstsKey`""
            $p = Start-Process -FilePath (Find-SshKeygen) -ArgumentList $keygenArgs -NoNewWindow -Wait -PassThru
            if ($p.ExitCode -ne 0) { Die 'ssh-keygen failed' }
        } else {
            Write-Host "Azure DevOps doesn't accept $VstsKey yet."
        }
        $pub = (Get-Content -Raw "$VstsKey.pub").Trim()
        Write-Host ''
        Write-Host 'Add this public key to Azure DevOps (VSTS):'
        Write-Host "  1. Open $VstsKeysUrl"
        Write-Host '  2. New Key, any name, paste the key below, Add'
        Write-Host ''
        Write-Host $pub
        Write-Host ''
        try { Set-Clipboard -Value $pub; Write-Host '(also copied to the clipboard)' } catch { }
        Start-Process $VstsKeysUrl
        Read-Host 'Press Enter once the key is added (Ctrl+C to stop)' | Out-Null
    }
    return 'key'
}

function Sync-Clone($dir) {
    if (Test-Path (Join-Path $dir '.git')) {
        Info "Updating $dir"
        if (-not (git -C $dir status --porcelain --untracked-files=no)) {
            git -C $dir pull --ff-only -q
            if ($LASTEXITCODE -ne 0) { Write-Host "     (couldn't fast-forward; left as is)" }
        } else {
            Write-Host '     (local changes; left as is)'
        }
        return
    }
    if ((Test-Path $dir) -and (Get-ChildItem -Force $dir)) { Die "$dir exists and isn't a clone of the orchestrator" }
    $mode = Confirm-Access
    Info "Cloning the orchestrator into $dir"
    # Only when it's missing: New-Item can't create a drive root (D:\ for D:\orca).
    $parent = Split-Path $dir
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
    $env:GIT_SSH_COMMAND = Get-SshCommand $mode
    git clone -q $RepoUrl $dir
    $ok = $LASTEXITCODE -eq 0
    Remove-Item Env:GIT_SSH_COMMAND
    if (-not $ok) { Die 'git clone failed' }
    # Like start.ps1: a clone made with the key keeps using it, without an ssh config.
    if ($mode -eq 'key') { git -C $dir config core.sshCommand "ssh -i '$($VstsKey -replace '\\', '/')' -o IdentitiesOnly=yes" }
}

# Start menu (searchable) and Desktop shortcuts that open PowerShell running start.ps1.
function Add-Shortcuts($dir) {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
        $path = Join-Path $folder "$AppName.lnk"
        if (Test-Path $path) { continue }
        $link = $shell.CreateShortcut($path)
        $link.TargetPath = (Get-Command powershell).Source
        $link.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$(Join-Path $dir 'start.ps1')`""
        $link.WorkingDirectory = $dir
        $link.Save()
    }
    Info "Added `"$AppName`" to the Start menu and the Desktop"
}

Write-Host "Installing the $AppName"
Install-Git
$dir = $env:ONEVALET_DIR
if (-not $dir) {
    $dir = Join-Path $HOME '1valet\OneValet.Orchestrator'
    if (-not (Test-Path (Join-Path $dir '.git'))) {
        # Keys pressed earlier (say, during the git install) mustn't become the answer: drop them, strip control
        # characters, and ask again when nothing usable is left.
        while ($true) {
            try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
            $raw = Read-Host "Install into ${dir}? (Enter, or type another folder)"
            $reply = ($raw -replace '\x1b\[[0-9;?]*[A-Za-z~]', '' -replace '[\x00-\x1f\x7f]', '').Trim()
            if (-not $raw) { break }
            if ($reply -match '^([A-Za-z]:\\|\\\\|~)') { $dir = $reply -replace '^~', $HOME; break }
            Write-Host 'Type a full path (like C:\Users\you\1valet), or just press Enter.'
        }
        Info "Folder: $dir"
    }
}
Sync-Clone $dir
try { Add-Shortcuts $dir } catch { Write-Host "     (no shortcuts: $_)" }
Info "Starting (next time: open `"$AppName`" from the Start menu, or run start.ps1 in $dir)"
Set-Location $dir
powershell -ExecutionPolicy Bypass -File (Join-Path $dir 'start.ps1')
}
