<#
.SYNOPSIS
    Install Deno for Windows systems.
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
Installer script for Deno.

Usage: install-deno [OPTIONS]

Options:
  -d, --dest <PATH>         Directory to install Deno
  -g, --global              Install Deno for all users
  -h, --help                Print help information
  -m, --modify-env          Update system environment
  -q, --quiet               Print only error messages
  -v, --version <VERSION>   Version of Deno to install
'@
}

# Download and install Deno.
function InstallDeno($TargetEnv, $Version, $DestDir, $ModifyEnv) {
    $Arch = $Env:PROCESSOR_ARCHITECTURE -replace 'AMD64', 'x86_64' `
        -replace 'ARM64', 'aarch64'

    Log "Installing Deno to '$DestDir\deno.exe'."
    $TmpDir = [System.IO.Path]::GetTempFileName()
    Remove-Item $TmpDir | Out-Null
    New-Item -ItemType Directory -Path $TmpDir | Out-Null

    $Target = "deno-$Arch-pc-windows-msvc"
    Invoke-WebRequest -UseBasicParsing -OutFile "$TmpDir\$Target.zip" -Uri `
        "https://dl.deno.land/release/$Version/$Target.zip"

    Expand-Archive -DestinationPath "$TmpDir\$Target" -Path "$TmpDir\$Target.zip"
    Copy-Item -Destination $DestDir -Path "$TmpDir\$Target\*.exe"

    if ($ModifyEnv) {
        $Path = [Environment]::GetEnvironmentVariable('Path', $TargetEnv)
        if (-not ($Path -like "*$DestDir*")) {
            $PrependedPath = "$DestDir;$Path"
            [System.Environment]::SetEnvironmentVariable(
                'Path', "$PrependedPath", $TargetEnv
            )
            Log "Added '$DestDir' to the system path."
            Log 'Source shell profile or restart shell after installation.'
        }

        if ($TargetEnv -eq 'Machine') {
            $Registry = 'HKLM:\Software\Classes'
        }
        else {
            $Registry = 'HKCU:\Software\Classes'
        }
        if (-not (Get-ItemProperty -ErrorAction SilentlyContinue -Name '(Default)' -Path "$Registry\.js")) {
            New-Item -Force -Path "$Registry\.js" | Out-Null
            Set-ItemProperty -Name '(Default)' -Path "$Registry\.js" -Type String `
                -Value 'jsfile'

            $Command = '"' + "$DestDir\deno.exe" + '" "%1" %*'
            New-Item -Force -Path "$Registry\jsfile\shell\open\command" | Out-Null
            Set-ItemProperty -Name '(Default)' -Path "$Registry\jsfile\shell\open\command" `
                -Type String -Value $Command
            Log "Registered Deno to execute '.js' files."
        }

        $PathExt = [Environment]::GetEnvironmentVariable('PATHEXT', $TargetEnv)
        # User PATHEXT does not extend machine PATHEXT. Thus user PATHEXT must be
        # changed to machine PATHEXT + ';.NU' if prevously empty.
        if ((-not $PathExt) -and ($TargetEnv -eq 'User')) {
            $PathExt = [Environment]::GetEnvironmentVariable('PATHEXT', 'Machine')
        }
        if (-not ($PathExt -like "*.NU*")) {
            $AppendedPath = "$PathExt;.NU".TrimStart(';')
            [System.Environment]::SetEnvironmentVariable(
                'PATHEXT', $AppendedPath, $TargetEnv
            )
            $Env:PATHEXT = $AppendedPath
            Log "Registered '.js' files as executables."
        }
    }

    $Env:Path = "$DestDir;$Env:Path"
    Log "Installed $(deno --version)."
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
                Log "Run 'install-deno --help' for usage."
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

    # Find latest Deno version if not provided.
    if (-not $Version) {
        $Version = $(
            Invoke-WebRequest -UseBasicParsing -Uri https://dl.deno.land/release-latest.txt
        ).Content.Trim()
    }
    InstallDeno $TargetEnv $Version $DestDir $ModifyEnv
}

# Only run Main if invoked as script. Otherwise import functions as library.
if ($MyInvocation.InvocationName -ne '.') {
    Main $Args
}
