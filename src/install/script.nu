#!/usr/bin/env nu

# Copy and configure file.
def deploy [
    --mode (-m): string
    --super (-s): string
    source: string
    dest: string
] {
    let quiet = $env.SCRIPTS_NOLOG? | into bool --relaxed
    let folder = $dest | path dirname

    # Download to temporary file to avoid permission restrictions.
    let file = if ($source | path exists) {
        $source
    } else {
        let temp = mktemp --tmpdir
        if $quiet {
            http get $source | save --force $temp
        } else {
            http get $source | save --force --progress $temp
        }
        $temp
    }

    # Copy file instead of move to ensure correct ownership.
    if ($super | is-empty) {
        mkdir $folder
        cp $file $dest
        if ($mode | is-not-empty) and $nu.os-info.name != "windows" {
            chmod $mode $dest
        }
    } else {
        ^$super mkdir -p $folder
        ^$super cp $file $dest
        if ($mode | is-not-empty) and $nu.os-info.name != "windows" {
            ^$super chmod $mode $dest
        }
    }
}

# Find all installable completions inside repository.
def find-completions [version: string = "main"] {
    let exts = if $nu.os-info.name == "windows" { [] } else { ["fish"] }

    if ($version | path exists) {
        ls $"($version)/src/completion" | get name
    } else {
        http get $"https://api.github.com/repos/scruffaluff/picoware/git/trees/($version)?recursive=true"
        | get tree
        | where type == blob
        | get path
        | where { $in | str starts-with "src/completion/" }
    }
    | where { ($in | path parse | get extension) in $exts }
    | path basename
}

# Find all installable scripts inside repository.
def find-scripts [version: string = "main"] {
    let exts = if $nu.os-info.name == "windows" {
        ["nu" "ps1" "py" "rs" "ts"]
    } else {
        ["nu" "py" "rs" "sh" "ts"]
    }

    if ($version | path exists) {
        ls $"($version)/src/script" | get name
    } else {
        http get $"https://api.github.com/repos/scruffaluff/picoware/git/trees/($version)?recursive=true"
        | get tree
        | where type == blob
        | get path
        | where {$in | str starts-with "src/script/" }
    }
    | where { ($in | path parse | get extension) in $exts }
    | path basename
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

# Create entrypoint script if necessary.
def handle-shebang [super: string path: path extension: string] {
    let split_env = "#!/usr/bin/env -S "
    let shebang = open --raw $path | lines | first
    let script = $"($path).($extension)"

    # Exit early if `env` can handle the shebang arguments.
    if ($shebang | str contains $split_env) {
        let result = env -S echo test | complete
        if $result.exit_code == 0 { return }
    } else {
        return
    }

    # Add entrypoint replacement for script.
    let command = $shebang | str replace "#!/usr/bin/env -S " ""
    let temp = mktemp --tmpdir
    $"
#!/usr/bin/env sh
set -eu

exec ($command) '($script)' \"$@\"
"
    | str trim --left
    | save --force $temp
    chmod +rx $temp

    # Move script to new location.
    if ($super | is-empty) {
        cp $path $script
        cp $temp $path
        chmod -x $script
    } else {
        ^$super cp $path $script
        ^$super cp $temp $path
        ^$super chmod -x $script
    }
}

# Install completion scripts.
def install-completion [
    super: string
    global: bool
    version: string
    script: string
] {
    let quiet = $env.SCRIPTS_NOLOG? | into bool --relaxed
    let name = $script | path parse | get stem
    let completions = find-completions $version
    | where { ($in | path parse | get stem) == $name }

    let source = if ($version | path exists) {
        $"($version)/src/completion/($name)"
    } else {
        $"https://raw.githubusercontent.com/scruffaluff/picoware/($version)/src/completion/($name)"
    }
    let dest = if $global {
        match $nu.os-info.name {
            freebsd => {fish: $"/usr/local/etc/fish/completions/($name).fish"}
            macos => {
                let prefix = if $nu.os-info.arch == "aarch64" {
                    "/opt/homebrew"
                } else {
                    "/usr/local"
                }
                {fish: $"($prefix)/etc/fish/completions/($name).fish"}
            }
            windows => { }
            _ => {fish: $"/etc/fish/completions/($name).fish"}
        }
    } else {
        {fish: $"($nu.home-dir)/.config/fish/completions/($name).fish"}
    }

    for completion in $completions {
        let ext = $completion | path parse | get extension
        deploy --super $super --mode 644 $"($source).($ext)" ($dest | get $ext)
    }
}

# Install script to destination folder.
def install-script [
    super: string
    system: bool
    preserve_env: bool
    version: string
    dest: directory
    script: string
] {
    let quiet = $env.SCRIPTS_NOLOG? | into bool --relaxed
    let parts = $script | path parse
    let ext = $parts | get extension | str replace --regex "^ts$" "tsx"
    let name = $parts | get stem
    let source = if ($version | path exists) {
        $"($version)/src/script/($script)"
    } else {
        $"https://raw.githubusercontent.com/scruffaluff/picoware/($version)/src/script/($script)"
    }

    mut args = []
    if $preserve_env {
        $args = [...$args "--preserve-env"]
    }
    if $system {
        $args = [...$args "--global"]
    }
    if $ext == "py" and (which uv | is-empty) {
        http get https://scruffaluff.github.io/picoware/install/uv.nu
        | nu --commands $in --quiet ...$args
    } else if $ext == "rs" and (which rust-script | is-empty) {
        http get https://scruffaluff.github.io/picoware/install/rust-script.nu
        | nu --commands $in --quiet ...$args
    } else if $ext in ["ts" "tsx"] and (which deno | is-empty) {
        http get https://scruffaluff.github.io/picoware/install/deno.nu
        | nu --commands $in --quiet ...$args
    }

    let program = if $nu.os-info.name == "windows" {
        $"($dest)/($script)"
    } else {
        $"($dest)/($name)"
    }

    log $"Installing script ($script) to '($program | path expand)'."
    deploy --mode 755 --super $super $source $program
    install-completion $super $system $version $script

    if $nu.os-info.name == "windows" {
        let path_exts = $env.PATHEXT | str lowercase | split row ";."
        if not ($ext in $path_exts) {
            install-wrapper $ext $"($dest)/($name)"
        }
        if not $preserve_env and not ($dest in $env.PATH) {
            update-path $dest $system
        }
    } else {
        handle-shebang $super $program $ext
        if not $preserve_env and not ($dest in $env.PATH) {
            update-shell $dest
        }
    }

    $env.PATH = [$dest ...$env.PATH]
    log $"Installed (^$name --version)."
}

# Install wrapper script for Windows.
def install-wrapper [ext: string dest: path] {
    let wrapper = match $ext {
        nu => 'nu "%~dnp0.nu" %*'
        ps1 => 'powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%~dnp0.ps1" %*'
        py => 'uv --no-config --quiet run --script "%~dnp0.py" %*'
        rs => 'rust-script "%~dnp0.rs" %*'
        ts => 'deno run --allow-all --no-config --quiet --node-modules-dir=none "%~dnp0.ts" %*'
    }

    $"@echo off\n($wrapper)\n" | save --force $"($dest).cmd"
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

# Installer script for Picoware scripts.
def main [
    --dest (-d): directory # Directory to install scripts
    --global (-g) # Install scripts for all users
    --list (-l) # List all available scripts
    --preserve-env (-p) # Do not update system environment
    --quiet (-q) # Print only error messages
    --version (-v): string = "main" # Version of scripts to install
    ...scripts: string # Scripts names
] {
    if $quiet { $env.SCRIPTS_NOLOG = "true" }
    # Force global if root on Unix.
    let global = $global or ((is-admin) and $nu.os-info.name != "windows")

    let names = if $list {
        for script in (find-scripts $version) {
            print ($script | path parse | get stem)
        }
        return
    } else if ($scripts | is-empty) {
        log --stderr "error: Script argument required."
        log --stderr "Run 'install-scripts --help' for usage."
        exit 2
    } else {
        find-scripts $version
    }

    let dest_default = if $nu.os-info.name == "windows" {
        if $global {
            "C:\\Program Files\\Bin"
        } else {
            $"($env.LocalAppData)\\Programs\\Bin"
        }
    } else {
        if $global { "/usr/local/bin" } else { $"($nu.home-dir)/.local/bin" }
    }
    let dest = $dest | default $dest_default | path expand

    let system = need-super $dest $global
    let super = if $system { find-super } else { "" }
    for script in $scripts {
        mut match = false
        for name in $names {
            let stem = $name | path parse | get stem
            if $script == $stem {
                $match = true
                install-script $super $system $preserve_env $version $dest $name
            }
        }

        if not $match {
            log --stderr $"error: No script found for '($script)'."
        }
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
