#!/usr/bin/env nu

# Ensure script dependencies are available.
def check-deps [] {
    if $nu.os-info.name != "windows" and (which tar | is-empty) {
        error make ("
error: Unable to find tar file archiver.
Install tar, https://gnu.org/software/tar, manually before continuing.
"       | str trim)
    }
}

# Find command to elevate as super user.
def find-super [] {
    if (is-admin) {
        ""
    } else if $nu.os-info.name == "windows" {
        error make ("
System level installation requires an administrator console.
Restart this script from an administrator console or install to a user directory.
        " | str trim)
    } else if (which doas | is-not-empty) {
        "doas"
    } else if (which sudo | is-not-empty) {
        "sudo"
    } else {
        error make "Unable to find a command for super user elevation."
    }
}

# Download and install Nushell.
def install-nushell [super: string dest: directory version: string] {
    let quiet = $env.SCRIPTS_NOLOG? | into bool --relaxed
    let archive = if $nu.os-info.name == "windows" { ".zip" } else { ".tar.gz" }
    let ext = if $nu.os-info.name == "windows" { ".exe" } else { "" }
    let target = match $nu.os-info.name {
        linux => $"nu-($version)-($nu.os-info.arch)-unknown-linux-musl"
        macos => $"nu-($version)-($nu.os-info.arch)-apple-darwin"
        windows => $"nu-($version)-($nu.os-info.arch)-pc-windows-msvc"
    }
    let dest_file = $"($dest)/nu($ext)"

    log $"Installing Nushell to '($dest_file)'."
    let temp = mktemp --directory --tmpdir
    let uri = $"https://github.com/nushell/nushell/releases/download/($version)/($target)($archive)"
    if $quiet {
        http get $uri | save $"($temp)/nu($archive)"
    } else {
        http get $uri | save --progress $"($temp)/nu($archive)"
    }

    let bins = [
        nu nu_plugin_formats nu_plugin_formats nu_plugin_gstat nu_plugin_inc
        nu_plugin_polars nu_plugin_query
    ]
    if $nu.os-info.name == "windows" {
        powershell -command $"
$ProgressPreference = 'SilentlyContinue'
Expand-Archive -DestinationPath '($temp)' -Path '($temp)/nu.zip'
"
        for bin in $bins {
            cp $"($temp)/($target)/($bin)" $"($dest)/($bin)"
        }
    } else {
        tar fx $"($temp)/nu.tar.gz" -C $temp
        if ($super | is-empty) {
            for bin in $bins {
                cp $"($temp)/($target)/($bin)" $"($dest)/($bin)"
                chmod 755 $"($dest)/($bin)"
            }
        } else {
            for bin in $bins {
                ^super cp $"($temp)/($target)/($bin)" $"($dest)/($bin)"
                ^super chmod 755 $"($dest)/($bin)"
            }
        }
    }
}

# Print message if error or logging is enabled.
def --wrapped log [
    --stderr (-e) # Print to stderr instead of stdout
    ...args: string
] {
    if $stderr {
        print --stderr ...$args
    } else if not ($env.SCRIPTS_NOLOG? | into bool --relaxed) {
        print ...$args
    }
}

# Check if super user elevation is required.
def need-super [dest: directory global: bool] {
    if $global {
        return true
    }
    try { mkdir $dest } catch { return true }
    try { touch $"($dest)/.super_check" } catch { return true }
    rm $"($dest)/.super_check"
    false
}

# Install Nushell for MacOS, Linux, and Windows systems.
def main [
    --dest (-d): directory # Directory to install Nushell
    --global (-g) # Install Nushell for all users
    --preserve-env (-p) # Do not update system environment
    --quiet (-q) # Print only error messages
    --version (-v): string # Version of Nushell to install
] {
    if $quiet { $env.SCRIPTS_NOLOG = "true" }
    # Force global if root on Unix.
    let global = $global or ((is-admin) and $nu.os-info.name != "windows")

    let dest_default = if $nu.os-info.name == "windows" {
        if $global {
            "C:\\Program Files\\Bin"
        } else {
            $"($env.LocalAppData)\\Programs\\Bin"
        }
    } else if $nu.os-info.name == "freebsd" {
        log 'FreeBSD Nushell installation requires system package manager.'
        log "Ignoring arguments and installing Nushell to '/usr/local/bin/nu'."
        let super = find-super
        ^$super pkg update
        (
            ^$super pkg install --yes nushell nu_plugin_formats nu_plugin_gstat
            nu_plugin_inc nu_plugin_polars nu_plugin_query
        )
        log $"Installed Nushell (nu --version)."
        return
    } else {
        if $global { "/usr/local/bin" } else { $"($nu.home-dir)/.local/bin" }
    }
    let dest = $dest | default $dest_default | path expand

    check-deps
    let system = need-super $dest $global
    let super = if $system { find-super } else { "" }
    let version = $version | default (
        http get "https://formulae.brew.sh/api/formula/nushell.json"
        | get versions.stable
    )

    install-nushell $super $dest $version
    if not $preserve_env and not ($dest in $env.PATH) {
        if $nu.os-info.name == "windows" {
            update-path $dest $system
        } else {
            update-shell $dest
        }
    }

    $env.PATH = $env.PATH | prepend $dest
    log $"Installed Nushell (nu --version)."
}

# Add destination path to Windows environment path.
def update-path [dest: directory global: bool] {
    let target = if $global { "Machine" } else { "User" }
    powershell -command $"
$Dest = '($dest | path expand)'
$Path = [Environment]::GetEnvironmentVariable\('Path', '($target)'\)
if \(-not \($Path -like \"*$Dest*\"\)\) {
    $PrependedPath = \"$Dest;$Path\"
    [System.Environment]::SetEnvironmentVariable\(
        'Path', \"$PrependedPath\", '($target)'
    \)
    Write-Output \"Added '$Dest' to the system path.\"
    Write-Output 'Source shell profile or restart shell after installation.'
}
"
}

# Add script to system path in shell profile.
def update-shell [dest: directory] {
    let shell = $env.SHELL? | default "" | path basename

    let command = match $shell {
        fish => $"set --export PATH \"($dest)\" $PATH"
        nu => $"$env.PATH = [\"($dest)\" ...$env.PATH]"
        _ => $"export PATH=\"($dest):${PATH}\""
    }
    let profile = match $shell {
        bash => $"($nu.home-dir)/.bashrc"
        fish => $"($nu.home-dir)/.config/fish/config.fish"
        nu => {
            if $nu.os-info.name == "macos" {
                $"($nu.home-dir)/Library/Application Support/nushell/config.nu"
            } else {
                $"($nu.home-dir)/.config/nushell/config.nu"
            }
        }
        zsh => $"($nu.home-dir)/.zshrc"
        _ => $"($nu.home-dir)/.profile"
    }

    # Create profile parent directory and add export command to profile.
    mkdir ($profile | path dirname)
    $"\n# Added by Picoware installer.\n($command)\n" | save --append $profile
    log $"Added '($command)' to the '($profile)' shell profile."
    log "Source shell profile or restart shell after installation."
}
