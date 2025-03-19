<#
.SYNOPSIS
    SSH for one time remote connections.
#>

# Exit immediately if a PowerShell cmdlet encounters an error.
$ErrorActionPreference = 'Stop'
# Disable progress bar for PowerShell cmdlets.
$ProgressPreference = 'SilentlyContinue'
# Exit immediately when an native executable encounters an error.
$PSNativeCommandUseErrorActionPreference = $True

# Show CLI help information.
function Usage() {
    Write-Output @'
SSH for one time remote connections.

Usage: tssh [OPTIONS] [SSH_ARGS]...

Options:
  -h, --help      Print help information
  -v, --version   Print version information
'@
}

# Print Tssh version string.
function Version() {
    Write-Output 'Tssh 0.2.1'
}

# Script entrypoint.
function Main() {
    $ArgIdx = 0
    $CmdArgs = @()

    while ($ArgIdx -lt $Args[0].Count) {
        switch ($Args[0][$ArgIdx]) {
            { $_ -in '-h', '--help' } {
                Usage
                exit 0
            }
            { $_ -in '-v', '--version' } {
                Version
                exit 0
            }
            default {
                $CmdArgs += $Args[0][$ArgIdx]
                $ArgIdx += 1
            }
        }
    }

    # Don't use PowerShell $Null for UserKnownHostsFile. It causes SSH to use
    # ~/.ssh/known_hosts as a backup.
    ssh `
        -o IdentitiesOnly=yes `
        -o LogLevel=ERROR `
        -o PreferredAuthentications='publickey,password' `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=NUL `
        $CmdArgs
}

# Only run Main if invoked as script. Otherwise import functions as library.
if ($MyInvocation.InvocationName -ne '.') {
    Main $Args
}
