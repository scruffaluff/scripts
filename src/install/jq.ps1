<#
.SYNOPSIS
    Install Jq for Windows systems.
#>

# If unable to execute due to policy rules, run
# Set-ExecutionPolicy RemoteSigned -Scope CurrentUser.

# Exit immediately if a PowerShell cmdlet encounters an error.
$ErrorActionPreference = 'Stop'
# Disable progress bar for PowerShell cmdlets.
$ProgressPreference = 'SilentlyContinue'
# Exit immediately when an native executable encounters an error.
$PSNativeCommandUseErrorActionPreference = $True

# Show CLI help information.
function Usage() {
    Write-Output @'
Installer script for Jq.

Usage: install-jq [OPTIONS]

Options:
  -d, --dest <PATH>         Directory to install Jq
  -g, --global              Install Jq for all users
  -h, --help                Print help information
  -m, --modify-env          Update system environment
  -q, --quiet               Print only error messages
  -v, --version <VERSION>   Version of Jq to install
'@
}

# Download and install Jq.
function InstallJq($TargetEnv, $Version, $DestDir, $ModifyEnv) {
    $Arch = $Env:PROCESSOR_ARCHITECTURE.ToLower()

    if ($version) {
        $Subpath = "download/jq-$Version"
    }
    else {
        $Subpath = 'latest/download'
    }

    Log "Installing Jq to '$DestDir\jq.exe'."
    $TmpDir = [System.IO.Path]::GetTempFileName()
    Remove-Item $TmpDir | Out-Null
    New-Item -ItemType Directory -Path $TmpDir | Out-Null
    Invoke-WebRequest -UseBasicParsing -OutFile "$DestDir\jq.exe" -Uri `
        "https://github.com/jqlang/jq/releases/$Subpath/jq-windows-$Arch.exe"

    if ($ModifyEnv) {
        $Path = [Environment]::GetEnvironmentVariable('Path', $TargetEnv)
        if (-not ($Path -like "*$DestDir*")) {
            $PrependedPath = "$DestDir;$Path"
            [System.Environment]::SetEnvironmentVariable(
                'Path', "$PrependedPath", $TargetEnv
            )
            Log "Added '$DestDir' to the system path."
            $Env:Path = $PrependedPath
        }
    }

    $Env:Path = "$DestDir;$Env:Path"
    Log "Installed Jq $(jq --version)."
}

# Print message if logging is enabled.
function Log($Text) {
    if (!"$Env:SCRIPTS_NOLOG") {
        Write-Output $Text
    }
}

# Script entrypoint.
function Main() {
    $ArgIdx = 0
    $DestDir = ''
    $ModifyEnv = $False
    $Version = ''

    while ($ArgIdx -lt $Args[0].Count) {
        switch ($Args[0][$ArgIdx]) {
            { $_ -in '-d', '--dest' } {
                $DestDir = $Args[0][$ArgIdx + 1]
                $ArgIdx += 2
                break
            }
            { $_ -in '-g', '--global' } {
                if (-not $DestDir) {
                    $DestDir = 'C:\Program Files\Bin'
                }
                $ArgIdx += 1
                break
            }
            { $_ -in '-h', '--help' } {
                Usage
                exit 0
            }
            { $_ -in '-m', '--modify-env' } {
                $ModifyEnv = $True
                $ArgIdx += 1
                break
            }
            { $_ -in '-q', '--quiet' } {
                $Env:SCRIPTS_NOLOG = 'true'
                $ArgIdx += 1
                break
            }
            { $_ -in '-v', '--version' } {
                $Version = $Args[0][$ArgIdx + 1]
                $ArgIdx += 2
                break
            }
            default {
                Log "error: No such option '$($Args[0][$ArgIdx])'."
                Log "Run 'install-jq --help' for usage."
                exit 2
            }

        }
    }

    # Create destination folder if it does not exist for Resolve-Path.
    if (-not $DestDir) {
        $DestDir = "$Env:LocalAppData\Programs\Bin"
    }
    New-Item -Force -ItemType Directory -Path $DestDir | Out-Null

    # Set environment target on whether destination is inside user home folder.
    $DestDir = $(Resolve-Path -Path $DestDir).Path
    $HomeDir = $(Resolve-Path -Path $HOME).Path
    if ($DestDir.StartsWith($HomeDir)) {
        $TargetEnv = 'User'
    }
    else {
        $TargetEnv = 'Machine'
    }

    InstallJq $TargetEnv $Version $DestDir $ModifyEnv
}

# Only run Main if invoked as script. Otherwise import functions as library.
if ($MyInvocation.InvocationName -ne '.') {
    Main $Args
}
