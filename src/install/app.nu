#!/usr/bin/env nu

# Capitalize application name.
def capitalize [name: string] {
    $name
    | str replace --regex "[_-]" " "
    | split words
    | str capitalize
    | str join " "
}

# Create application entrypoint script.
def create-entry [super: string script: path folder: string entry: path] {
    let name = $script | path basename
    let shebang = open --raw $script | lines | first
    let command = $shebang
    | str replace "#!/usr/bin/env -S " ""
    | str replace "#!/usr/bin/env " ""

    if $nu.os-info.name == "windows" {
        $"@echo off\n($command) %*\n" | save --force $entry
    } else {
        let text = $"
#!/usr/bin/env sh
set -eu

# Add interpreter to system path.
export PATH=\"($folder):${PATH}\"
# Resolve symlinks to find script folder.
folder=\"$\(dirname \"$\(realpath \"${0}\"\)\"\)\"
# Use interpeter to avoid env shebang conflicts.
exec ($command) \"${folder}/($name)\" \"\$@\"
"
        | str trim

        if ($super | is-empty) {
            $text | save --force $entry
            chmod 755 $entry
        } else {
            let temp = mktemp --tmpdir
            $text | save --force $temp
            ^$super cp $temp $entry
            ^$super chmod 755 $entry
            rm $temp
        }
    }
}

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

# Download application files from repository.
def fetch-app [
    version: string
    name: string
    dest: directory
] {
    let url = $"https://raw.githubusercontent.com/scruffaluff/picoware/refs/heads/($version)/src/app/($name)"
    let files = http get $"https://api.github.com/repos/scruffaluff/picoware/git/trees/($version)?recursive=true"
    | get tree
    | where type == "blob"
    | get path
    | where { $in | str starts-with $"src/app/($name)" }
    | str replace $"src/app/($name)" ""

    mkdir $dest
    mut script = ""
    for file in $files {
        let dest_file = $"($dest)/($file)"
        let ext = $file | path parse | get extension

        if $ext in ["nu" "py" "sh" "ts"] {
            if ($file | path parse | get stem) == "main" {
                $script = $dest_file
            }
            deploy --mode 755 $"($url)/($file)" $dest_file
        } else {
            deploy $"($url)/($file)" $dest_file
        }
    }

    if ($script | is-empty) {
        error make $"error: No entry point found in app ($name)."
    }
    $script
}

# Find all apps inside repository.
def find-apps [version: string = "main"] {
    if ($version | path exists) {
        ls $"($version)/src/app" | get name | path basename
    } else {
        http get $"https://api.github.com/repos/scruffaluff/picoware/git/trees/($version)?recursive=true"
        | get tree
        | where type == "tree"
        | get path
        | where { $in | str starts-with "src/app/" }
        | str replace "src/app/" ""
    }
}

# Find application runner.
def find-runner [global: bool script: path] {
    let ext = $script | path parse | get extension
    mut args = ["--preserve-env"]
    if $global {
        $args = [...$args "--global"]
    }

    match $ext {
        nu => { which nu | get 0.path }
        py => {
            if (which uv | is-empty) {
                http get https://scruffaluff.github.io/picoware/install/uv.nu
                | nu --commands $in ...$args
            }
            which uv | get 0.path
        }
        rs => {
            if (which rust-script | is-empty) {
                http get https://scruffaluff.github.io/picoware/install/rust-script.nu
                | nu --commands $in ...$args
            }
            which rust-script | get 0.path
        }
        ts | tsx => {
            if (which deno | is-empty) {
                http get https://scruffaluff.github.io/picoware/install/deno.nu
                | nu --commands $in ...$args
            }
            which deno | get 0.path
        }
        _ => {
            error make $"Unable to find an application runner for ($script)."
        }
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

# Install single application.
def install-app [
    super: string
    global: bool
    version: string
    name: string
] {
    let title = capitalize $name
    log $"Installing application ($title)."

    let src = mktemp --directory --tmpdir
    let script = fetch-app $version $name $src
    let runner = find-runner $global $script

    match $nu.os-info.name {
        linux => {
            chmod 755 $src
            (
                install-app-linux $super $global $version $name $src
                $script $runner
            )
        }
        macos => {
            chmod 755 $src
            (
                install-app-macos $super $global $version $name $src
                $script $runner
            )
        }
        windows => {
            install-app-windows $global $version $name $src $script $runner
        }
    }
}

# Install application on Linux.
def install-app-linux [
    super: string
    global: bool
    version: string
    name: string
    src: string
    script: string
    runner: string
] {
    let title = capitalize $name
    let url = $"https://raw.githubusercontent.com/scruffaluff/picoware/refs/heads/($version)"
    let icon_url = $"($url)/data/image/icon.svg"

    let cli_dir = if $global {
        "/usr/local/bin"
    } else {
        $"($nu.home-dir)/.local/bin"
    }
    let dest = if $global {
        $"/usr/local/app/($name)"
    } else {
        $"($nu.home-dir)/.local/app/($name)"
    }
    let manifest = if $global {
        $"/usr/local/share/applications/($name).desktop"
    } else {
        $"($nu.home-dir)/.local/share/applications/($name).desktop"
    }
    let entry = $"($dest)/main.sh"

    if not ($"($src)/icon.svg" | path exists) {
        http get $icon_url | save $"($src)/icon.svg"
    }
    remove-icons $src "icon.svg"
    create-entry $super $script $runner $"($src)/main.sh"
    if ($super | is-empty) {
        cp --recursive $"($src)/" $"($dest)/"
        chmod -R a+rX $dest
    } else {
        ^$super cp -r $"($src)/" $"($dest)/"
        ^$super chmod -R a+rX $dest
    }
    rm --force --recursive $src

    if ($super | is-empty) {
        mkdir $cli_dir
        ln -fs $entry $"($cli_dir)/($name)"
    } else {
        ^$super mkdir -p $cli_dir
        ^$super ln -fs $entry $"($cli_dir)/($name)"
    }

    # Find window class for dock icon.
    let wmclass = match ($runner | path basename) {
        deno => "GTK Application"
        rust-script => "GTK Application"
        uv => "python3"
        _ => ""
    }

    let desktop = $"
[Desktop Entry]
Exec=($entry)
Icon=($dest)/icon.svg
Name=($title)
StartupWMClass=($wmclass)
Terminal=false
Type=Application
"
    if ($super | is-empty) {
        $desktop | save --force $manifest
    } else {
        let temp = mktemp --tmpdir
        $desktop | save --force $temp
        ^$super cp $temp $manifest
        rm $temp
    }

    if ($super | is-empty) {
        update-desktop-database ($manifest | path dirname)
    } else {
        ^$super update-desktop-database ($manifest | path dirname)
    }

    # Update shell profile if CLI is not in system path.
    if not ($cli_dir in $env.PATH) {
        update-shell $cli_dir
    }

    $env.PATH = [$cli_dir ...$env.PATH]
    log $"Installed (^$name --version)"
}

# Install application on macOS.
def install-app-macos [
    super: string
    global: bool
    version: string
    name: string
    src: string
    script: string
    runner: string
] {
    let title = capitalize $name
    let identifier = $"com.scruffaluff.app-($name | str replace '_' '-')"
    let url = $"https://raw.githubusercontent.com/scruffaluff/picoware/refs/heads/($version)"
    let icon_url = $"($url)/data/image/icon.icns"

    let bundle = if $global {
        $"/Applications/($title).app/Contents"
    } else {
        $"($nu.home-dir)/Applications/($title).app/Contents"
    }
    let cli_dir = if $global {
        "/usr/local/bin"
    } else {
        $"($nu.home-dir)/.local/bin"
    }
    let dest = $"($bundle)/MacOS"
    let entry = $"($dest)/main.sh"
    let icon = $"($bundle)/Resources/icon.icns"
    let manifest = $"($bundle)/Info.plist"

    if not ($"($src)/icon.icns" | path exists) {
        http get $icon_url | save $"($src)/icon.icns"
    }
    remove-icons $src "icon.icns"
    create-entry $super $script $runner $"($src)/main.sh"
    if ($super | is-empty) {
        mkdir $"($bundle)/Resources"
        mv $"($src)/icon.icns" $icon
        cp --recursive $"($src)/" $"($dest)/"
        chmod -R a+rX $bundle
    } else {
        ^$super mkdir -p $"($bundle)/Resources"
        ^$super cp $"($src)/icon.icns" $icon
        ^$super rm $"($src)/icon.icns"
        ^$super cp -r $"($src)/" $"($dest)/"
        ^$super chmod -R a+rX $bundle
    }
    rm --force --recursive $src

    if ($super | is-empty) {
        mkdir $cli_dir
        ln -fs $entry $"($cli_dir)/($name)"
    } else {
        ^$super mkdir -p $cli_dir
        ^$super ln -fs $entry $"($cli_dir)/($name)"
    }

    let plist = $"
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>English</string>
  <key>CFBundleDisplayName</key>
  <string>($title)</string>
  <key>CFBundleExecutable</key>
  <string>main.sh</string>
  <key>CFBundleIconFile</key>
  <string>icon.icns</string>
  <key>CFBundleIdentifier</key>
  <string>($identifier)</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>($name)</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>0.1.0</string>
  <key>CSResourcesFileMapped</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>10.13</string>
  <key>LSRequiresCarbon</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
"
    if ($super | is-empty) {
        $plist | save --force $manifest
    } else {
        let temp = mktemp --tmpdir
        $plist | save --force $temp
        ^$super cp $temp $manifest
        rm $temp
    }

    # Update shell profile if CLI is not in system path.
    if not ($cli_dir in $env.PATH) {
        update-shell $cli_dir
    }

    $env.PATH = [$cli_dir ...$env.PATH]
    log $"Installed (^$name --version)"
}

# Install application on Windows.
def install-app-windows [
    global: bool
    version: string
    name: string
    src: string
    script: string
    runner: string
] {
    let title = capitalize $name
    let url = $"https://raw.githubusercontent.com/scruffaluff/picoware/refs/heads/($version)"
    let icon_url = $"($url)/data/image/favicon.ico"

    let cli_dir = if $global {
        "C:\\Program Files\\Bin"
    } else {
        $"($env.LocalAppData)\\Programs\\Bin"
    }
    let dest = if $global {
        $"C:\\Program Files\\App\\($name)"
    } else {
        $"($env.LocalAppData)\\Programs\\App\\($name)"
    }
    let menu_dir = if $global {
        "C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\App"
    } else {
        $"($env.AppData)\\Microsoft\\Windows\\Start Menu\\Programs\\App"
    }

    if not ($"($src)/icon.ico" | path exists) {
        http get $icon_url | save $"($src)/icon.ico"
    }
    remove-icons $src "icon.ico"
    mv $src $dest

    mkdir $cli_dir
    let args = runner-args $script $runner
    $"@echo off\n\"($runner)\" ($args) %*\n"
    | save --force $"($cli_dir)/($name).cmd"

    # Create Start Menu shortcut via PowerShell based on guide at
    # https://learn.microsoft.com/en-us/troubleshoot/windows-client/admin-development/create-desktop-shortcut-with-wsh.
    powershell -command $"
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut('($menu_dir)/($title).lnk')
$Shortcut.TargetPath = '($runner)'
$Shortcut.Arguments = '($args)'
$Shortcut.IconLocation = '($dest)/icon.ico'
$Shortcut.WindowStyle = 7
$Shortcut.Save()
"

    # Update path variable if CLI is not in system path.
    if not ($cli_dir in $env.PATH) {
        update-path $cli_dir $global
    }

    $env.PATH = [$cli_dir ...$env.PATH]
    log $"Installed (^$name --version)."
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

# Installer script for Picoware apps.
def main [
    --global (-g) # Install apps for all users
    --list (-l) # List all available apps
    --quiet (-q) # Print only error messages
    --version (-v): string = "main" # Version of apps to install
    ...apps: string # App names
] {
    if $quiet { $env.SCRIPTS_NOLOG = "true" }
    # Force global if root on Unix.
    let global = $global or ((is-admin) and $nu.os-info.name != "windows")

    let names = if $list {
        for app in (find-apps $version) {
            print $app
        }
        return
    } else if ($apps | is-empty) {
        log --stderr "error: App argument required."
        log --stderr "Run 'install-apps --help' for usage."
        exit 2
    } else {
        find-apps $version
    }

    let super = if $global { find-super } else { "" }
    for app in $apps {
        mut match = false
        for name in $names {
            if $app == $name {
                $match = true
                install-app $super $global $version $name
            }
        }

        if not $match {
            log --stderr $"error: No app found for '($app)'."
        }
    }
}

# Delete all icons except for given filename from fold.er
def remove-icons [folder: path name: string] {
    glob $"($folder)/icon.*"
    | where ($it | path basename) != $name
    | each { rm --force $in }
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
