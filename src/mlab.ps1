<#
.SYNOPSIS
    Wrapper script for running Matlab programs from the command line.
#>

# Exit immediately if a PowerShell Cmdlet encounters an error.
$ErrorActionPreference = 'Stop'

# Show CLI help information.
Function Usage() {
    Switch ($Args[0]) {
        'main' {
            Write-Output @'
Wrapper script for running Matlab programs from the command line

Usage: mlab [OPTIONS] [SUBCOMMAND]

Options:
  -h, --help        Print help information
  -v, --version     Print version information

Subcommands:
  jupyter   Launch Jupyter Lab with Matlab kernel
  run       Execute Matlab code
'@
        }
        'run' {
            Write-Output @'
Execute Matlab code

Usage: mlab [OPTIONS] [SCRIPT] [ARGS]

Options:
  -a, --addpath <PATH>        Add folder to Matlab path
  -c, --license <LOCATION>    Set location of Matlab license file
  -d, --debug                 Start script with Matlab debugger
  -e, --echo                  Print Matlab command and exit
  -h, --help                  Print help information
  -l, --log <PATH>            Copy command window output to logfile
  -s, --sd <PATH>             Set the Matlab startup folder
'@
        }
        Default {
            ErrorUsage "No such usage option '$($Args[0])'"
        }
    }
}

# Print error message and exit script with usage error code.
Function ErrorUsage($Message) {
    Throw "Error: $Message"
    Exit 2
}

# Find Matlab executable on system.
Function FindMatlab() {
    $InstallPath = 'C:/Program Files/MATLAB'
    $Program = ''

    If ($Env:MLAB_PROGRAM) {
        $Program = $Env:MLAB_PROGRAM
    }
    ElseIf (Test-Path -Path $InstallPath -PathType Container) {
        $Folders = $(Get-ChildItem -Filter 'R*' -Path $InstallPath)
        ForEach ($Folder In $Folders) {
            $Program = "$InstallPath/$Folder/bin/matlab.exe"
            Break
        }
    }

    # Throw error if Matlab was not found.
    If ($Program) {
        Return $Program
    }
    Else {
        Throw 'Unable to find a Matlab installation'
    }
}

# Convert Matlab script into a module call.
Function GetModule($Path) {
    Switch ($Path) {
        { $_ -Like "*.m" } {
            Return [System.IO.Path]::GetFileNameWithoutExtension($Path)
        }
        Default {
            Return $Path
        }
    }
}

# Get parameters for subcommands.
Function GetParameters($Params, $Index) {
    If ($Params.Length -GT $Index) {
        Return $Params[$Index..($Params.Length - 1)]
    }
    Else {
        Return @()
    }
}

# Launch Jupyter Lab with Matlab kernel.
Function LaunchJupyter() {
    $LocalDir = "$Env:LOCALAPPDATA/mlab"
    $MatlabDir = "$(FindMatlab)"

    If (-Not (Test-Path -Path "$LocalDir/venv" -PathType Container)) {
        New-Item -Force -ItemType Directory -Path $LocalDir | Out-Null
        python3 -m venv "$LocalDir/venv"
        & "$LocalDir/venv/Scripts/pip.exe" install jupyter-matlab-proxy jupyterlab
    }

    & "$LocalDir/venv/Scripts/activate.ps1"
    $Env:Path = $MatlabDir + ";$Env:Path"
    jupyter lab $Args
}

# Subcommand to execute Matlab code.
Function Run() {
    $ArgIdx = 0
    $BinaryArgs = @()
    $Debug = $False
    $Display = '-nodesktop'
    $Flag = '-r'
    $PathCmd = ''
    $Print = $False
    $Script = ''

    While ($ArgIdx -LT $Args[0].Count) {
        Switch ($Args[0][$ArgIdx]) {
            { $_ -In '-a', '--addpath' } {
                $PathCmd = "addpath('"+ $Args[0][$ArgIdx + 1]+ "'); "
                $ArgIdx += 2
            }
            { $_ -In '-c', '--license' } {
                $BinaryArgs += '-c'
                $BinaryArgs += $Args[0][$ArgIdx + 1]
                $ArgIdx += 2
            }
            { $_ -In '-d', '--debug' } {
                $Debug = $True
                $ArgIdx += 1
            }
            { $_ -In '-e', '--echo' } {
                $Print = $True
                $ArgIdx += 1
            }
            { $_ -In '-g', '--genpath' } {
                $PathCmd = "addpath(genpath('" + $Args[0][$ArgIdx + 1] + "')); "
                $ArgIdx += 2
            }
            { $_ -In '-h', '--help' } {
                Usage 'run'
                Exit 0
            }
            { $_ -In '-l', '-logfile', '--logfile' } {
                $BinaryArgs += '-logfile'
                $BinaryArgs += $Args[0][$ArgIdx + 1]
                $ArgIdx += 2
            }
            { $_ -In '-s', '-sd', '--sd' } {
                $BinaryArgs += '-sd'
                $BinaryArgs += $Args[0][$ArgIdx + 1]
                $ArgIdx += 2
            }
            Default {
                $Script = $Args[0][$ArgIdx]
                $ArgIdx += 1
                Break
            }
        }
    }

    # Build Matlab command for script execution.
    $Module = "$(GetModule $Script)"
    If ($Debug) {
        $Display = '-nodisplay'
        If ($Script) {
            $Command = "dbstop if error; dbstop in $Module; $Module; exit"
        }
        Else {
            $Command = 'dbstop if error;'
        }
    }
    ElseIf ($Script) {
        $Command = "$Module"
        $Flag = '-batch'
    }

    # Add parent path to Matlab if command is a script.
    If ($Script -And ($Module -NE $Script)) {
        $Folder = [System.IO.Path]::GetDirectoryName($Script)
        If ($Folder -NotLike "+*") {
            $Command = "addpath('$Folder'); $Command"
        }
    }

    $Command = "$PathCmd$Command"
    If ($Command) {
        $FlagArgs = '-nosplash',$Flag,$Command
    }
    Else {
        $FlagArgs = @('-nosplash')
    }

    $Program = "$(FindMatlab)"
    If ($Print -And ($BinaryArgs.Count -GT 0)) {
        Write-Output "& $Program $BinaryArgs $Display $FlagArgs"
    }
    ElseIf ($Print) {
        Write-Output "& $Program $Display $FlagArgs"
    }
    ElseIf ($BinaryArgs.Count -GT 0) {
        & $Program $BinaryArgs $Display $FlagArgs
    }
    Else {
        & $Program $Display $FlagArgs
    }
}

# Print Mlab version string.
Function Version() {
    Write-Output 'Mlab 0.0.3'
}

# Script entrypoint.
Function Main() {
    $ArgIdx = 0

    While ($ArgIdx -LT $Args[0].Count) {
        Switch ($Args[0][$ArgIdx]) {
            { $_ -In '-h', '--help' } {
                Usage 'main'
                Exit 0
            }
            { $_ -In '-v', '--version' } {
                Version
                Exit 0
            }
            'jupyter' {
                $ArgIdx += 1
                LaunchJupyter @(GetParameters $Args[0] $ArgIdx)
                Exit 0
            }
            'run' {
                $ArgIdx += 1
                Run @(GetParameters $Args[0] $ArgIdx)
                Exit 0
            }
            Default {
                ErrorUsage "No such subcommand or option '$($Args[0][0])'"
            }
        }
    }

    Usage 'main'
}

# Only run Main if invoked as script. Otherwise import functions as library.
If ($MyInvocation.InvocationName -NE '.') {
    Main $Args
}
