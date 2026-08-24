#!/usr/bin/env nu
#
# Convenience script for QEMU and Virsh.
#
# Relevant tutorials:
#   - https://sureshjoshi.com/development/alpine-kvm-virt-install-linux

use std/log

def ask-password [] {
    let password = input --suppress-output "Password: "
    print ""
    let confirm = input --suppress-output "Confirm password: "
    print ""

    if $password == $confirm {
        $password
    } else {
        print --stderr "error: Passwords do not match."
        ask-password
    }
}

# Generate cloud init data.
def cloud-init [
    --super (-s): string = "sudo"
    domain: string
    username: string
    password: string
] {
    let pub_key = open --raw $"(path-config)/key.pub" | str trim
    let super_config = match $super {
        doas => $"doas: ['permit nopass ($username)']"
        sudo => "sudo: ['ALL=\(ALL\) NOPASSWD:ALL']"
        _ => { error make $"Super command '($super)' is not supported." }
    }

    # Some Cloud-Init systems requires a metadata file as mentioned at
    # https://github.com/virt-manager/virt-manager/issues/975#issuecomment-3246370350.
    let meta_path = mktemp --tmpdir --suffix .yaml
    let meta_data = $"hostname: '($domain)'" | save --force $meta_path

    let user_path = mktemp --tmpdir --suffix .yaml
    let user_data = $"
#cloud-config
groups:
  - ($super)
hostname: ($domain)
packages:
  - ($super)
users:
  - groups:
      - ($super)
    lock_passwd: false
    name: ($username)
    plain_text_passwd: '($password)'
    ssh_authorized_keys:
      - '($pub_key)'
    ($super_config)
"
    | str trim --left
    | save --force $user_path

    $"meta-data=($meta_path),user-data=($user_path)"
}

# Create application desktop entry.
def create-app [domain: string] {
    let config = path-config
    let title = $domain | str capitalize

    match $nu.os-info.name {
        macos => {
            let dest = $"($nu.home-dir)/Applications/($title).app/Contents"
            mkdir $"($dest)/MacOS" $"($dest)/Resources"
            cp $"($config)/icon.icns" $"($dest)/Resources/icon.icns"
            create-entry $domain $"($dest)/MacOS/main.sh"

            (
                $"
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
  <string>com.scruffaluff.vimu-($domain)</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>($domain)</string>
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
                | str trim
                | save --force $"($dest)/Info.plist"
            )
        }
        windows => { error make "Windows application is not yet supported." }
        _ => {
            let dest = $"($nu.home-dir)/.local/share/applications"
            mkdir $dest
            (
                $"
[Desktop Entry]
Exec=vimu gui ($domain)
Icon=($config)/icon.svg
Name=($title)
StartupWMClass=virt-viewer
Terminal=false
Type=Application
Version=1.0
"
                | str trim --left
                | save --force $"($dest)/($domain).desktop"
            )
        }
    }
}

# Create application entrypoint.
def create-entry [domain: string path: path] {
    const folder = path self .

    if $nu.os-info.name != "windows" {
        $"
#!/usr/bin/env sh
set -eu

export PATH=\"($folder):${PATH}\"
exec vimu gui ($domain)
"
        | str trim --left
        | save --force $path
        chmod +rx $path
    }
}

# Create SSH key.
def create-key [] {
    let config = path-config
    if not ($"($config)/key" | path exists) {
        ssh-keygen -N '' -q -f $"($config)/key" -t ed25519 -C vimu
        if $nu.os-info.name != "windows" {
            chmod 600 $"($config)/key" $"($config)/key.pub"
        }
    }
    $"($config)/key"
}

# Download Windows 11 ISO file.
def download-windows-iso [arch: string dest: path] {
    # Based on `download_windows_workstation` function from
    # https://github.com/quickemu-project/quickemu/blob/master/quickget.
    let profile = "606624d44113"
    let session = random uuid
    let product = (
        http get https://microsoft.com/en-us/software-download/windows11
        | parse --regex '<option value="(?P<id>[0-9]+)">Windows'
        | get id | first
    )

    http get $"https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=($session)"
    let sku = http get $"https://microsoft.com/software-download-connector/api/getskuinformationbyproductedition?profile=($profile)&ProductEditionId=($product)&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=($session)"
    | from json
    | get Skus
    | where Language == "English"
    | get Id
    | first

    let response = (
        http get --headers
        { Referer: "https://microsoft.com/en-us/software-download/windows11" }
        $"https://microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku?profile=($profile)&productEditionId=undefined&SKU=($sku)&friendlyFileName=undefined&Locale=en-US&sessionID=($session)"
        | from json
    )
    let errors = $response | get --optional Errors
    if ($errors | is-not-empty) {
        if ($errors | get --optional 0.Value) =~ "Sentinel marked this request as rejected" {
            "Download manually from https://www.microsoft.com/en-us/software-download/windows11."
            error make $"
Microsoft blocked the automated download request based on your IP address.
Download Windows ISO manually to ($dest)
from https://www.microsoft.com/en-us/software-download/windows11.
"
        } else {
            error make ($errors | to json --indent 2)
        }
    }

    let link = $response | get ProductDownloadOptions | get Uri | first
    http get $link | save --progress $dest
}

# Find command to elevate as super user.
def find-super [] {
    if (is-admin) {
        ""
    } else if $nu.os-info.name == "windows" {
        error make "
System level installation requires an administrator console.
Restart this script from an administrator console or install to a user directory.
"
    } else if (which doas | is-not-empty) {
        "doas"
    } else if (which sudo | is-not-empty) {
        "sudo"
    } else {
        error make "Unable to find a command for super user elevation."
    }
}

# Create a virtual machine from an ISO disk.
def --wrapped install-cdrom [
    domain: string
    arch: string
    osinfo: string
    cdrom: path
    ...args: string
] {
    let args = virt-args $arch ...$args
    let disk = $"(path-libvirt)/cdrom/($domain).iso"
    cp $cdrom $disk

    log info $"Installing ($domain) from a CD-ROM."
    (
        virt-install --noreboot
        --arch $arch
        --boot uefi
        --cdrom $disk
        --disk bus=virtio,cache=none,format=qcow2,size=64
        --memory 4096
        --name $domain
        --osinfo $osinfo
        --vcpus 2
        ...$args
    )
}

# Create a virtual machine from a qcow2 disk.
def --wrapped install-disk [
    --super (-s): string = "sudo"
    domain: string
    arch: string
    osinfo: string
    image: path
    cloud_init: bool
    ...args: string
] {
    mut args = virt-args $arch ...$args
    if $cloud_init {
        print "Creating cloud init account for virtual machine."
        let username = $env.VIMU_USERNAME? | default { input "Username: " }
        let password = $env.VIMU_PASSWORD? | default { ask-password }
        let cloud_data = cloud-init --super $super $domain $username $password
        $args = ["--cloud-init" $cloud_data ...$args]
    }

    let disk = $"(path-libvirt)/image/($domain).qcow2"
    let size = "64G"
    log info $"Resizing disk image to ($size)."
    qemu-img convert -p -O qcow2 $image $disk
    qemu-img resize $disk $size

    log info $"Installing ($domain) from a disk image."
    (
        virt-install --noreboot
        --arch $arch
        --boot uefi
        --disk $"($disk),bus=virtio,cache=none,format=qcow2"
        --memory 4096
        --name $domain
        --osinfo $osinfo
        --vcpus 2
        ...$args
    )
}

# Create a Windows virtual machine from an ISO disk.
def --wrapped install-windows [
    domain: string
    arch: string
    cdrom: path
    drivers: string
    ...args: string
] {
    let libvirt = path-libvirt
    let args = virt-args $arch ...$args
    let disk = $"($libvirt)/cdrom/($domain).iso"
    let devices = $"($libvirt)/cdrom/($drivers | path basename)"
    cp $cdrom $disk
    cp $drivers $devices

    log info $"Installing ($domain) from a CD-ROM."
    log debug "Recommended steps for the Windows graphical installer."
    log debug "You may encounter a 'No bootable option or device was found' error message. If so press the 'Enter' key to open QEMU boot menu and select the 'QEMU DVD-ROM' option to try again. This process may need to repeat a few times."
    log debug "At the 'Where do you want to install Windows?' screen, the installer will not be able to find any hard drives. Select the 'Load driver' option and load the 'Red Hat VirtIO SCSI controller' from the path E:/amd64/w11."
    log debug "At the 'Let's connect you to a network screen' screen, press 'Shift+F10' and enter `OOBE\\BYPASSNRO` into the command prompt."
    log debug "In the account creation form, enter your account username instead of your full name and skip entering a password to avoid the additional security questions."
    log debug "Once the installer completes, press 'Ctrl+Alt+Del' to create a password."
    log debug "Run the QEMU guest agent installer at E:/guest-agent/qemu-ga-x86_64.msi."
    log debug "Run the VirtIO installer at E:/virtio-win-gt-x64.msi."
    log debug "Shutdown the virtual machine and run 'vimu detach-cdroms windows'."

    (
        virt-install --noreboot
        --arch $arch
        --boot uefi
        --cdrom $disk
        --disk bus=virtio,cache=none,format=qcow2,size=64
        --disk $"bus=sata,device=cdrom,path=($devices)"
        --memory 4096
        --name $domain
        --osinfo win11
        --tpm backend.type=emulator,backend.version=2.0,model=tpm-tis
        --vcpus 2
        ...$args
    )
}

# Convenience script for QEMU and Virsh.
def --wrapped main [
    --log-level (-l): string = "debug" # Log level
    --version (-v) # Print version information
    ...args: path # Virsh arguments
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase
    if $version {
        print "Vimu 0.1.7"
    } else if $args == ["-h"] or $args == ["--help"] {
        (
            print
"Convenience script for QEMU and Virsh.

Usage: vimu [OPTIONS] <SUBCOMMAND>

Options:
  -h, --help        Print help information
  -v, --version     Print version information

Subcommands:
  bootstrap         Bootstrap virtual machine with Bootware
  create            Create virutal machine from default options
  detach-cdroms     Remove all cdrom disks from virtual machine
  forget            Clear history files
  gui               Connect to virtual machine as desktop
  install           Create a virtual machine from a cdrom or disk file
  port              Get host port mapping to domain
  remove            Delete virtual machine and its disk images
  setup             Configure machine for emulation
  snapshot-table    List snapshots for all virtual machines
  scp               Copy files between host and virtual machine
  ssh               Connect to virtual machine with SSH
  upload            Upload Vimu to guest machine"
        )
        if (which virsh | is-not-empty) {
            print "\nVirsh Options:\n"
            virsh ...$args
        }
    } else {
        virsh ...$args
    }
}

# Connect to virtual machine with Android debug bridge.
def --wrapped "main adb" [
    --log-level (-l): string = "debug" # Log level
    domain: string # Virtual machine name
    ...args: path # Android debug bridge arguments.
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase
    if not (virsh list --name | str contains $domain) {
        virsh start $domain
    }
    let port = main port $domain 5555
    adb -P $port connect ...$args
}

# Bootstrap virtual machine with Bootware.
def --wrapped "main bootstrap" [
    --log-level (-l): string = "debug" # Log level
    domain: string # Virtual machine name
    ...args: path # Bootware arguments.
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase
    if not (virsh list --name | str contains $domain) {
        virsh start $domain
    }
    let key = $"(path-config)/key"
    let port = main port $domain 22

    (
        bootware bootstrap --port $port --inventory localhost --temp-key $key
        ...$args
    )
}

# Create virutal machine from default options.
def "main create" [
    --log-level (-l): string = "debug" # Log level
    domain: string # Virtual machine name
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase
    let arch = match $nu.os-info.arch {
        aarch64 => "arm64"
        x86_64 => "amd64"
    }
    let config = path-config
    main fetch $domain

    # To find all osinfo options, run "virt-install --osinfo list".
    match $domain {
        alpine => {
            (
                main install --cloud-init --domain alpine --log-level
                $log_level --osinfo alpinelinux3.23 --super doas
                $"($config)/image/alpine_($arch).qcow2"
            )
        }
        android => {
            let cdrom = $"($config)/cdrom/android_amd64.iso"
            let image = $"($config)/image/android_amd64.qcow2"
            let disk = if ($image | path exists) { $image } else { $cdrom }
            print "Follow instructions at https://youtu.be/MG7-S_88nDg?t=120 during first boot."
            (
                main install --arch x86_64 --domain android --log-level
                $log_level --osinfo android-x86-9.0
                $"($config)/cdrom/android_amd64.iso"
            )
        }
        arch => {
            (
                main install --cloud-init --arch x86_64 --domain arch
                --log-level $log_level --osinfo archlinux
                $"($config)/image/arch_amd64.qcow2"
            )
        }
        debian => {
            (
                main install --cloud-init --domain debian --log-level
                $log_level --osinfo debian13
                $"($config)/image/debian_($arch).qcow2"
            )
        }
        fedora => {
            (
                main install --cloud-init --domain fedora --log-level
                $log_level --osinfo fedora43
                $"($config)/image/fedora_($arch).qcow2"
            )
        }
        freebsd => {
            (
                main install --cloud-init --domain freebsd --log-level
                $log_level --osinfo freebsd15.0
                $"($config)/image/freebsd_($arch).qcow2"
            )
        }
        nixos => {
            let cdrom = $"($config)/cdrom/nixos_($arch).iso"
            let image = $"($config)/image/nixos_($arch).qcow2"
            let disk = if ($image | path exists) { $image } else { $cdrom }
            (
                main install --domain nixos --log-level $log_level --osinfo
                nixos-25.11 $disk
            )
        }
        proxmox => {
            (
                main install --arch x86_64 --domain proxmox
                --log-level $log_level --osinfo debian13
                $"($config)/cdrom/proxmox_amd64.iso"
            )
        }
        redox => {
            (
                main install --domain redox --log-level $log_level
                $"($config)/image/redox_amd64.img"
            )
        }
        windows => {
            let cdrom = $"($config)/cdrom/windows_($arch).iso"
            let drivers = $"($config)/cdrom/winvirt_drivers.iso"
            let image = $"($config)/image/windows_($arch).qcow2"
            if ($image | path exists) {
                (
                    main install --domain windows --log-level $log_level
                    --osinfo win11 $image --autoconsole none --tpm
                    backend.type=emulator,backend.version=2.0,model=tpm-tis
                )
            } else {
                create-app "windows"
                install-windows windows $nu.os-info.arch $cdrom $drivers
            }
        }
        _ => { error make $"Domain '($domain)' is not supported." }
    }
}

# Remove all cdrom disks from virtual machine.
def "main detach-cdroms" [
    --log-level (-l): string = "debug" # Log level
    domain: string # Virtual machine name
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase
    let cdroms = virsh domblklist --details $domain
    | from ssv
    | reject 0
    | where Device == "cdrom"
    | get Source

    for cdrom in $cdroms {
        log info $"Removing disk ($cdrom)."
        virsh detach-disk --persistent $domain $cdrom
    }
}

# Download default virtual machine disks.
def "main fetch" [
    --log-level (-l): string = "debug" # Log level
    domain: string # Virtual machine name
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase
    let arch = match $nu.os-info.arch {
        aarch64 => "arm64"
        x86_64 => "amd64"
    }
    let config = path-config
    setup-host

    match $domain {
        alpine => {
            let image = $"($config)/image/alpine_($arch).qcow2"
            if not ($image | path exists) {
                log info "Downloading Alpine image."
                http get $"https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/generic_alpine-3.23.4-($nu.os-info.arch)-uefi-cloudinit-r0.qcow2"
                | save --progress $image
            }
        }
        android => {
            let cdrom = $"($config)/cdrom/android_amd64.iso"
            let image = $"($config)/image/android_amd64.qcow2"
            if not (($image | path exists) or ($cdrom | path exists)) {
                log info "Downloading Android image."
                http get "https://gigenet.dl.sourceforge.net/project/android-x86/Release%209.0/android-x86_64-9.0-r2.iso"
                | save --progress $cdrom
            }
        }
        arch => {
            let image = $"($config)/image/arch_amd64.qcow2"
            if not ($image | path exists) {
                log info "Downloading Arch image."
                http get "https://mirror.pkgbuild.com/images/v20260601.539459/Arch-Linux-x86_64-cloudimg.qcow2"
                | save --progress $image
            }
        }
        debian => {
            let image = $"($config)/image/debian_($arch).qcow2"
            if not ($image | path exists) {
                log info "Downloading Debian image."
                http get $"https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-($arch).qcow2"
                | save --progress $image
            }
        }
        fedora => {
            let image = $"($config)/image/fedora_($arch).qcow2"
            if not ($image | path exists) {
                log info "Downloading Fedora image."
                http get $"https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/($nu.os-info.arch)/images/Fedora-Cloud-Base-Generic-44-1.7.($nu.os-info.arch).qcow2"
                | save --progress $image
            }
        }
        freebsd => {
            let image = $"($config)/image/freebsd_($arch).qcow2"
            if not ($image | path exists) {
                let url = match $nu.os-info.arch {
                    aarch64 => "https://download.freebsd.org/releases/VM-IMAGES/15.0-RELEASE/aarch64/Latest/FreeBSD-15.0-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-zfs.qcow2.xz"
                    x86_64 => "https://download.freebsd.org/releases/VM-IMAGES/15.0-RELEASE/amd64/Latest/FreeBSD-15.0-RELEASE-amd64-BASIC-CLOUDINIT-zfs.qcow2.xz"
                }
                log info "Downloading FreeBSD image."
                http get $url | save --progress $"($image).xz"
                xz --decompress $"($image).xz"
            }
        }
        nixos => {
            let cdrom = $"($config)/cdrom/nixos_($arch).iso"
            let image = $"($config)/image/nixos_($arch).qcow2"
            if not (($image | path exists) or ($cdrom | path exists)) {
                log info "Downloading NixOS image."
                http get $"https://channels.nixos.org/nixos-25.11/latest-nixos-minimal-($nu.os-info.arch)-linux.iso"
                | save --progress $cdrom
            }
        }
        proxmox => {
            let cdrom = $"($config)/cdrom/proxmox_amd64.iso"
            let image = $"($config)/image/proxmox_amd64.qcow2"
            if not (($image | path exists) or ($cdrom | path exists)) {
                log info "Downloading Proxmox image."
                http get "https://enterprise.proxmox.com/iso/proxmox-ve_9.1-1.iso"
                | save --progress $cdrom
            }
        }
        redox => {
            let image = $"($config)/image/redox_amd64.img"
            if not ($image | path exists) {
                let url = "https://static.redox-os.org/releases/0.9.0/x86_64/redox_demo_x86_64_2024-09-07_1225_harddrive.img.zst"
                log info "Downloading Redox image."
                http get $url | save --progress $"($image).zst"
                zstd --decompress --rm $"($image).zst"
            }
        }
        windows => {
            let cdrom = $"($config)/cdrom/windows_($arch).iso"
            let drivers = $"($config)/cdrom/winvirt_drivers.iso"
            let image = $"($config)/image/windows_($arch).qcow2"

            if ($image | path exists) {
                return
            }
            if not ($cdrom | path exists) {
                download-windows-iso $arch $cdrom
            }
            if not ($drivers | path exists) {
                log info "Downloading Windows drivers."
                http get "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
                | save --progress $drivers
            }
        }
        _ => { error make $"Domain '($domain)' is not supported." }
    }
}

# Clear history files.
def "main forget" [
    --dry (-d) # Only print actions to be taken
    --log-level (-l): string = "debug" # Log level
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase
    for file in [
        ".ansible"
        ".bash_history"
        ".cache"
        ".config/nushell/history.sqlite3"
        ".config/nushell/history.sqlite3-shm"
        ".config/nushell/history.sqlite3-wal"
        ".config/nushell/history.txt"
        ".lesshst"
        ".local/share/fish/fish_history"
        ".local/state/lesshst"
        ".python_history"
        ".viminfo"
        ".wget-hsts"
        ".zsh_history"
        "AppData/Roaming/nushell/history.sqlite3"
        "AppData/Roaming/nushell/history.sqlite3-shm"
        "AppData/Roaming/nushell/history.sqlite3-wal"
        "AppData/Roaming/nushell/history.txt"
        "AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt"
        "Library/Application Support/nushell/history.sqlite3"
        "Library/Application Support/nushell/history.sqlite3-shm"
        "Library/Application Support/nushell/history.sqlite3-wal"
        "Library/Application Support/nushell/history.txt"
    ] {
        let path = $"($nu.home-dir)/($file)"
        if ($path | path exists) {
            log info $"Deleting file ($path)."
            if not $dry {
                rm --force --recursive $path
            }
        }
    }
}

# Connect to virtual machine as desktop.
def "main gui" [
    --log-level (-l): string = "debug" # Log level
    domain: string # Virtual machine name
    ...args: path # Virt Viewer arguments
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase
    if not (virsh list --name | str contains $domain) {
        virsh start $domain
    }

    virt-viewer $domain ...$args
}

# Create a virtual machine from a cdrom or disk file.
def --wrapped "main install" [
    --arch (-a): string # Virtual machine architecture
    --cloud-init # Configure cloud init if possible
    --domain (-d): string # Virtual machine name
    --log-level (-l): string = "debug" # Log level
    --osinfo (-o): string = "generic" # Virt-install osinfo
    --super (-s): string = "sudo" # Virtual machine super user command
    uri: string # Machine image URL or file path
    ...args: string
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase
    setup-host
    let arch = $arch | default $nu.os-info.arch
    let config = path-config

    # Check if domain is already used by libvirt.
    if (virsh list --all --name | str contains $domain) {
        error make $"Domain '($domain)' is already in use."
    }
    let path = if ($uri | str starts-with "https://") {
        let image = $"($config)/image/($uri | path basename)"
        log info $"Downloading image from ($uri)."
        http get $uri | save --progress $image
        $image
    } else {
        $uri
    }

    let parts = $path | path parse
    let extension = $parts | get extension
    match $extension {
        iso => {
            create-app $domain
            install-cdrom $domain $arch $osinfo $path ...$args
        }
        "img" | "qcow2" | "raw" | vmdk => {
            create-app $domain
            (
                install-disk --super $super $domain $arch $osinfo $path
                $cloud_init ...$args
            )
        }
        _ => { error make $"Unsupported extension for disk '($path)'." }
    }
}

# Get host port mapping to domain.
def "main port" [
    domain: string # Virtual machine name
    to: int # Destination port
] {
    # QEMU monitor commands are taken from
    # https://qemu-project.gitlab.io/qemu/system/monitor.html.
    let maps = virsh qemu-monitor-command --domain $domain --hmp "info usernet"
    | str trim
    | lines
    | skip 2
    | str join "\n"
    | from ssv --minimum-spaces 1 --noheaders
    | where column0 == "TCP[HOST_FORWARD]"
    | select column3 column5
    | rename from to
    | into int from to

    let match = $maps | where to == $to | get --optional 0
    if $match == null {
        let rand_port = port
        (
            virsh qemu-monitor-command --domain $domain --hmp
            $"hostfwd_add tcp::($rand_port)-:($to)"
        )
        $rand_port
    } else {
        $match.from
    }
}

# Delete virtual machine and its disk images.
def "main remove" [
    --log-level (-l): string = "debug" # Log level
    domain: string # Virtual machine name
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase
    let libvirt = path-libvirt
    let title = $domain | str capitalize

    # Stop domain if running.
    if (virsh list --name | str contains $domain) {
        virsh destroy $domain
    }

    # Delete domain snapshots and then domain itself.
    if (virsh list --all --name | str contains $domain) {
        for snapshot in (
            virsh snapshot-list --name --domain $domain | split words
        ) {
            virsh snapshot-delete --domain $domain $snapshot
        }
        virsh undefine --nvram --remove-all-storage $domain
    }

    match $nu.os-info.name {
        linux => {
            (
                rm --force --recursive
                $"($nu.home-dir)/.local/share/applications/($domain).desktop"
                $"($libvirt)/cdrom/($domain).iso"
            )
        }
        macos => {
            (
                rm --force --recursive
                $"($nu.home-dir)/Applications/($title).app"
                $"($libvirt)/cdrom/($domain).iso"
            )
        }
    }
}

# Copy files between host and virtual machine.
def --wrapped "main scp" [
    --log-level (-l): string = "debug" # Log level
    ...args: path # Secure copy arguments
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase

    mut domain = ""
    mut params = $args
    for iter in ($args | enumerate) {
        let match = $iter.item | parse --regex '^(\w+@)?(?P<domain>\w+):.*$'
        if ($match | is-not-empty) {
            $domain = $match | get domain.0
            $params = $params | update $iter.index (
                $iter.item | str replace $"($domain):" "localhost:"
            )
        }
    }
    if ($domain | is-empty) {
        error make $"No domain found in '($args | str join ' ')'."
    }

    if not (virsh list --name | str contains $domain) {
        virsh start $domain
    }
    let port = main port $domain 22
    tscp -i $"(path-config)/key" -P $port ...$params
}

# Configure machine for emulation.
def "main setup" [
    --log-level (-l): string = "debug" # Log level
    --desktop (-d): string = "gnome" # Desktop environment
    ...commands: string # Setup commands (desktop,guest,host)
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase

    for command in $commands {
        match $command {
            desktop => { setup-desktop $desktop }
            guest => { setup-guest }
            host => { setup-host }
            rustdesk => { setup-rustdesk }
            tailscale => { setup-tailscale }
            _ => { error make $"Invalid setup command '($command)'." }
        }
    }
}

# List snapshots for all virtual machines.
def "main snapshot-table" [
    --log-level (-l): string = "debug" # Log level
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase
    virsh list --all --name | str trim | lines | each {|domain|
        virsh snapshot-list --parent $domain | str trim | lines | drop nth 1
        | str join "\n" | from ssv | insert Domain $domain | move Domain --first
    } | flatten
}

# Connect to virtual machine with SSH.
def --wrapped "main ssh" [
    --log-level (-l): string = "debug" # Log level
    domain: string # Virtual machine name
    ...args: path # Secure shell arguments
]: [nothing -> nothing string -> string] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase
    let key = $"(path-config)/key"
    if not (virsh list --name | str contains $domain) {
        virsh start $domain
    }
    let port = main port $domain 22

    # Appears that `$in` needs to be saved to a variable for mutliple uses.
    let pipe = $in
    if ($pipe | is-empty) {
        tssh -t -i $key -p $port localhost ...$args
    } else {
        $pipe | tssh -i $key -p $port localhost ...$args
    }
}

# Upload Vimu to guest machine.
def "main upload" [
    --log-level (-l): string = "debug" # Log level
    domain: string # Virtual machine name
] {
    $env.NU_LOG_LEVEL = $log_level | str uppercase
    const vimu = path self
    let info = os-info $domain

    # Copy Vimu to remote machine and install with super command.
    if $info.name == "windows" {
        # Using command 'powershell -file' instead of 'powershell -command' to
        # run the following code since the latter runs into quoting errors.
        let temp = mktemp --tmpdir --suffix ".ps1"
        '
if (-not (Get-Command -ErrorAction SilentlyContinue nu)) {
    $NushellScript = Invoke-WebRequest -UseBasicParsing -Uri `
        https://scruffaluff.github.io/picoware/install/nushell.ps1
    Invoke-Expression "& { $NushellScript } --global"
}
New-Item -Force -ItemType Directory -Path "C:\Program Files\Bin" | Out-Null
if (-not (($Env:PathExt -Split ";") -contains "NU")) {
    Set-Content -Path "C:\Program Files\Bin\vimu.cmd" -Value @"
@echo off
nu "%~dnp0.nu" %*
"@
};
        '
        | str trim
        | save --force $temp
        main scp $temp $"($domain):C:/Windows/Temp/vimu_upload.ps1"
        main ssh $domain powershell -file "C:/Windows/Temp/vimu_upload.ps1"
        main scp $vimu $"($domain):C:/Program Files/Bin/vimu.nu"
    } else {
        let check = main ssh $domain command -v nu | complete
        if $check.exit_code != 0 {
            http get https://scruffaluff.github.io/picoware/install/nushell.sh
            | main ssh $domain sh -s -- --global
        }

        main scp $vimu $"($domain):/tmp/vimu"
        main ssh $domain "
if command -v doas > /dev/null 2>&1; then
    doas install /tmp/vimu /usr/local/bin/vimu
else
    sudo install /tmp/vimu /usr/local/bin/vimu
fi
"
    }
}

# Get operating system information about a domain.
def os-info [domain: string] {
    # Windows shell check based on https://stackoverflow.com/a/34480405.
    let command = "(dir 2>&1 *`|echo commandprompt);&<# rem #>echo powershell"
    let process = main ssh $domain $command | complete
    let windows = (
        $process.exit_code == 0 and ("commandprompt" in $process.stdout or
        "powershell" in $process.stdout)
    )

    if $windows {
        {arch: "x86_64" name: "windows"}
    } else {
        let query = (main ssh $domain uname -ms)
        | str trim
        | str lowercase
        | split row " "
        {
            arch: ($query | get 1)
            name: ($query | get 0)
        }
    }
}

# Get Vimu configuration folder.
def path-config [] {
    match $nu.os-info.name {
        macos => $"($nu.home-dir)/Library/Application Support/vimu"
        windows => $"($nu.home-dir)/AppData/Roaming/vimu"
        _ => $"($nu.home-dir)/.config/vimu"
    }
}

# Get Libvirt folder.
def path-libvirt [] {
    $"($nu.home-dir)/.config/libvirt"
}

# Configure desktop environment on guest filesystem.
def setup-desktop [desktop: string = "gnome"] {
    let super = find-super

    match $nu.os-info.name {
        freebsd => {
            ^$super pkg update
            # Based on instructions at
            # https://docs.freebsd.org/en/books/handbook/desktop.
            match $desktop {
                gnome => {
                    ^$super pkg install --yes gnome
                    (
                        ^$super nu --commands
                        "'proc /proc procfs rw 0 0' | save --append /etc/fstab"
                    )
                    ^$super sysrc dbus_enable="YES"
                    ^$super sysrc gdm_enable="YES"
                    ^$super sysrc gnome_enable="YES"
                }
                plasma => {
                    ^$super pkg install --yes kde sddm
                    ^$super sysrc dbus_enable="YES"
                    ^$super sysrc sddm_enable="YES"
                }
                _ => { error make $"Unsupported desktop environment '($desktop)'." }
            }
        }
        linux => {
            if (which apk | is-not-empty) {
                ^$super apk update
                ^$super setup-desktop $desktop
            } else if (which apt-get | is-not-empty) {
                # Avoid APT interactive configuration requests.
                $env.DEBIAN_FRONTEND = "noninteractive"
                ^$super -E apt-get update
                match $desktop {
                    gnome => { ^$super -E apt-get install --yes task-gnome-desktop }
                    hyprland => { ^$super -E apt-get install --yes hyprland }
                    plasma => { ^$super -E apt-get install --yes task-kde-desktop }
                    _ => { error make $"Unsupported desktop environment '($desktop)'." }
                }
            } else if (which dnf | is-not-empty) {
                ^$super dnf makecache
                match $desktop {
                    cosmic => { ^$super dnf group install --assumeyes cosmic-desktop }
                    gnome => { ^$super dnf group install --assumeyes gnome-desktop }
                    hyprland => {
                        ^$super dnf copr enable --assumeyes solopasha/hyprland
                        ^$super dnf install --assumeyes hyprland
                    }
                    plasma => { ^$super dnf group install --assumeyes kde-desktop }
                    _ => { error make $"Unsupported desktop environment '($desktop)'." }
                }
                ^$super systemctl set-default graphical.target
            } else if (which pacman | is-not-empty) {
                ^$super pacman --noconfirm --refresh --sync --sysupgrade
                match $desktop {
                    cosmic => {
                        ^$super pacman --noconfirm --sync cosmic
                        ^$super systemctl enable --now cosmic-greeter.service
                    }
                    gnome => {
                        ^$super pacman --noconfirm --sync gnome
                        ^$super systemctl enable --now gdm.service
                    }
                    hyprland => {
                        ^$super pacman --noconfirm --sync hyprland
                    }
                    plasma => {
                        ^$super pacman --noconfirm --sync plasma-meta
                        ^$super systemctl enable --now plasmalogin.service
                    }
                    _ => {
                        error make $"Unsupported desktop environment '($desktop)'."
                    }
                }
            }

            (
                ^$super rm -f
                /usr/share/wayland-sessions/gnome-classic.desktop
                /usr/share/wayland-sessions/gnome-classic-wayland.desktop
                /usr/share/wayland-sessions/gnome-wayland.desktop
            )
        }
    }
}

# Configure guest filesystem.
def setup-guest [] {
    let super = find-super

    match $nu.os-info.name {
        freebsd => {
            ^$super pkg update
            # Seems as though openssh-server is builtin to FreeBSD.
            (
                ^$super pkg install --yes curl ncurses qemu-guest-agent rclone
                rsync topgrade
            )
            try { ^$super service qemu-guest-agent start }
            ^$super sysrc qemu_guest_agent_enable="YES"

            # Enable serial console on next boot.
            for option in ({
                "boot_multicons": "YES" "boot_serial": "YES"
                "comconsole_speed": "115200" "console": "comconsole,vidconsole"
            } | transpose key value) {
                let lines = open "/boot/loader.conf"
                | lines
                | where { not ($in | str contains $"($option.key)=") }

                let content = [...$lines $'($option.key)="($option.value)"']
                | str join "\n"
                ^$super nu --commands $"
'($content)' | save --force /boot/loader.conf
"
            }

            (
                mkdir $"($nu.home-dir)/.config/rclone"
                $"($nu.home-dir)/.config/rstash"
            )
            (
                chmod 700 $"($nu.home-dir)/.config/rclone"
                $"($nu.home-dir)/.config/rstash"
            )
        }
        linux => { setup-guest-linux $super }
        windows => { setup-guest-windows }
    }

    http get https://scruffaluff.github.io/bootware/install.nu
    | nu --commands $in --global

    let programs = ["clear-cache" "fdi" "rgi" "rstash" "vimu"]
    http get https://scruffaluff.github.io/picoware/install/script.nu
    | nu --commands $in --global ($programs | str join ' ')

    let nushell_folder = match $nu.os-info.name {
        macos => $"($nu.home-dir)/Library/Application Support/nushell"
        windows => $"($nu.home-dir)/AppData/Roaming/nushell"
        _ => $"($nu.home-dir)/.config/nushell"
    }
    mkdir $nushell_folder
    http get https://raw.githubusercontent.com/scruffaluff/bootware/refs/heads/main/ansible_collections/scruffaluff/bootware/roles/nushell/files/config.nu
    | save --force $"($nushell_folder)/config.nu"

    '
# Topgrade configuration file for updating system packages.
#
# For more infomation, visit
# https://github.com/topgrade-rs/topgrade/blob/main/config.example.toml.

[misc]
assume_yes = true
disable = ["certbot", "containers", "gem", "git_repos", "helm", "ruby_gems", "uv"]
no_retry = true
notify_each_step = false
skip_notify = true
'
    | str trim --left
    | save --force $"($nu.home-dir)/.config/topgrade.toml"
}

# Configure guest filesystem for Linux.
def setup-guest-linux [super: string] {
    if (which apk | is-not-empty) {
        ^$super apk update
        (
            ^$super apk add curl ncurses openssh-server python3 qemu-guest-agent
            rclone rsync spice-vdagent
        )
        ^$super rc-update add qemu-guest-agent
        ^$super service qemu-guest-agent start
        # Starting spice-vdagentd service causes an error.
        ^$super rc-update add spice-vdagentd
        ^$super rc-update add sshd
        ^$super service sshd start
    } else if (which apt-get | is-not-empty) {
        # Avoid APT interactive configuration requests.
        $env.DEBIAN_FRONTEND = "noninteractive"
        ^$super -E apt-get update
        (
            ^$super -E apt-get install --yes curl libncurses6 openssh-server
            qemu-guest-agent rclone rsync spice-vdagent
        )
    } else if (which dnf | is-not-empty) {
        ^$super dnf makecache
        (
            ^$super dnf install --assumeyes curl ncurses openssh-server
            qemu-guest-agent rclone rsync spice-vdagent
        )
    } else if (which pacman | is-not-empty) {
        ^$super pacman --noconfirm --refresh --sync --sysupgrade
        (
            ^$super pacman --noconfirm --sync curl ncurses openssh
            qemu-guest-agent rclone rsync spice-vdagent
        )
    } else if (which zypper | is-not-empty) {
        ^$super zypper update --no-confirm
        (
            ^$super zypper install --no-confirm curl ncurses openssh-server
            qemu-guest-agent rclone rsync spice-vdagent
        )
    }

    # Services qemu-guest-agnet and spice-vdagentd appear to only available as
    # on demand services.
    if (which systemctl | is-not-empty) {
        let services = systemctl list-units --type=service --all
        for service in ["serial-getty@ttyS0" "ssh" "sshd"] {
            if ($services | str contains $"($service).service") {
                log debug $"Enabling ($service) service."
                ^$super systemctl enable --now $"($service).service"
            }
        }
    }

    let temp = mktemp --directory --tmpdir
    let version = http get https://formulae.brew.sh/api/formula/topgrade.json
    | get versions.stable
    let file_name = (
        $"topgrade-v($version)-($nu.os-info.arch)-unknown-linux-musl.tar.gz"
    )

    http get $"https://github.com/topgrade-rs/topgrade/releases/download/v($version)/($file_name)"
    | save --progress $"($temp)/topgrade.tar.gz"
    tar xf $"($temp)/topgrade.tar.gz" -C $temp
    ^$super install $"($temp)/topgrade" /usr/local/bin/topgrade

    mkdir $"($nu.home-dir)/.config/rclone" $"($nu.home-dir)/.config/rstash"
    chmod 700 $"($nu.home-dir)/.config/rclone" $"($nu.home-dir)/.config/rstash"
}

# Configure guest filesystem for Windows.
def setup-guest-windows [] {
    let config = path-config
    mkdir $config

    powershell -command '
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
'

    if not ($"($config)/.ssh_server" | path exists) {
        powershell -command '
if (
    (Get-WindowsCapability -Online -Name OpenSSH.Server).State -ne "Installed"
) {
    Add-WindowsCapability -Online -Name OpenSSH.Server
}
if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Action Allow -Direction Inbound -DisplayName SSHD `
        -Enabled True -LocalPort 22 -Name sshd -Protocol TCP
}
if ((Get-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH).DefaultShell -eq $Null) {
    New-ItemProperty -Name DefaultShell -Path HKLM:\SOFTWARE\OpenSSH `
        -PropertyType String -Value `
        C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
}
$Key = "C:\ProgramData\ssh\administrators_authorized_keys"
if (-not (Test-Path -Path $Key -PathType Leaf)) {
    New-Item -ItemType File -Path $Key
    icacls $Key /Grant Administrators:F /Grant SYSTEM:F /Inheritance:r
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
'
        touch $"($config)/.ssh_server"
    }

    if not ($"($config)/.win_debloat" | path exists) {
        powershell -command '
Invoke-WebRequest -UseBasicParsing -Uri `
    https://scruffaluff.github.io/picoware/action/debloat-windows.ps1 `
    | Invoke-Expression
'
        touch $"($config)/.win_debloat"
    }

    if (which rclone | is-empty) {
        let temp = mktemp --directory --tmpdir | str replace --all '\' '/'
        let rclone_uri = http get https://raw.githubusercontent.com/ScoopInstaller/Main/refs/heads/master/bucket/rclone.json
        | get architecture.64bit.url
        http get $rclone_uri | save --progress $"($temp)/rclone.zip"
        powershell -command $"
$ProgressPreference = 'SilentlyContinue'
Expand-Archive -DestinationPath '($temp)' -Path '($temp)/rclone.zip'
"
        let rclone = glob $"($temp)/**/rclone.exe" | first
        cp $rclone "C:/Program Files/Bin/rclone.exe"
    }

    (
        mkdir $"($nu.home-dir)/.config/rclone"
        $"($nu.home-dir)/AppData/Roaming/rstash"
    )
}

# Configure host machine.
def setup-host [] {
    let config = path-config
    let libvirt = path-libvirt

    (
        mkdir $"($config)/cdrom" $"($config)/image" $"($libvirt)/cdrom"
        $"($libvirt)/image"
    )

    if not ($"($config)/icon.icns" | path exists) {
        http get https://raw.githubusercontent.com/scruffaluff/picoware/refs/heads/main/data/image/icon.icns
        | save $"($config)/icon.icns"
    }
    if not ($"($config)/icon.ico" | path exists) {
        http get https://raw.githubusercontent.com/scruffaluff/picoware/refs/heads/main/data/image/icon.ico
        | save $"($config)/icon.ico"
    }
    if not ($"($config)/icon.png" | path exists) {
        http get https://raw.githubusercontent.com/scruffaluff/picoware/refs/heads/main/data/image/icon.png
        | save $"($config)/icon.png"
    }
    if not ($"($config)/icon.svg" | path exists) {
        http get https://raw.githubusercontent.com/scruffaluff/picoware/refs/heads/main/data/image/icon.svg
        | save $"($config)/icon.svg"
    }

    create-key
    let programs = ["tscp" "tssh"]
    | where { which $in | is-empty }
    if ($programs | is-not-empty) {
        http get https://scruffaluff.github.io/picoware/install/script.nu
        | nu --commands $in --global ($programs | str join ' ')
    }
}

# Install RustDesk.
def setup-rustdesk [] {
    let super = find-super
    let version = http get https://formulae.brew.sh/api/cask/rustdesk.json
    | get version
    let target = $"rustdesk-($version)-($nu.os-info.arch)"
    let url = $"https://github.com/rustdesk/rustdesk/releases/download/($version)"

    match $nu.os-info.name {
        freebsd => {
            ^$super pkg update
            ^$super pkg install --yes rustdesk-server
        }
        linux => {
            if (which apk | is-not-empty) {
                let temp = mktemp --tmpdir --suffix ".apk"
                http get $"($url)/($target)-signed.apk" | save --force --progress $temp
                ^$super apk add $temp
            } else if (which apt-get | is-not-empty) {
                # Avoid APT interactive configuration requests.
                $env.DEBIAN_FRONTEND = "noninteractive"
                let temp = mktemp --tmpdir --suffix ".deb"
                http get $"($url)/($target).deb" | save --force --progress $temp
                ^$super -E apt install --yes $temp
            } else if (which dnf | is-not-empty) {
                let temp = mktemp --tmpdir --suffix ".rpm"
                http get $"($url)/rustdesk-($version)-0.($nu.os-info.arch).rpm"
                | save --force --progress $temp
                ^$super dnf install --assumeyes $temp
            } else if (which pacman | is-not-empty) {
                let temp = mktemp --tmpdir --suffix ".pkg.tar.zst"
                http get $"($url)/rustdesk-($version)-0-($nu.os-info.arch).pkg.tar.zst"
                | save --force --progress $temp
                ^$super pacman --noconfirm --upgrade $temp
            } else if (which zypper | is-not-empty) {
                let temp = mktemp --tmpdir --suffix ".rpm"
                http get $"($url)/($target)-suse.rpm" | save --force --progress $temp
                ^$super zypper install --no-confirm $temp
            }
        }
        macos => {
            let temp = mktemp --tmpdir --suffix ".dmg"
            http get $"($url)/($target).dmg" | save --force --progress $temp
            hdiutil attach $temp
            sudo cp -R $"/Volumes/rustdesk-($version)/RustDesk.app" /Applications/
            hdiutil detach $"/Volumes/rustdesk-($version)"
        }
        windows => {
            let temp = mktemp --tmpdir --suffix ".msi"
            http get $"($url)/($target).msi" | save --force --progress $temp
            msiexec /quiet /i $temp
        }
    }
}

# Install Tailscale.
def setup-tailscale [] {
    if $nu.os-info.name == "windows" {
        let version = http get https://formulae.brew.sh/api/formula/tailscale.json
        | get versions.stable
        let temp = mktemp --tmpdir --suffix ".msi"
        http get $"https://pkgs.tailscale.com/stable/tailscale-setup-($version)-amd64.msi"
        | save --force --progress $temp
        msiexec /quiet /i $temp
    } else if (which tailscale | is-empty) {
        http get https://tailscale.com/install.sh | sh
    }
}

# Find recommended virtualization parameters.
def virt-args [arch: string ...args: string] {
    match $nu.os-info.name {
        linux => [
            "--hvm"
            "--cpu" "host-passthrough"
            "--graphics" "spice"
            "--video" "qxl"
            "--virt-type" "kvm"
            ...$args
        ]
        macos => {
            if $nu.os-info.arch == $arch {
                [
                    "--graphics" "vnc"
                    "--video" "virtio"
                    "--virt-type" "hvf"
                    ...$args
                ]
            } else {
                ["--graphics" "vnc" "--video" "virtio" ...$args]
            }
        }
        _ => [
            "--cpu" "host-passthrough"
            "--graphics" "spice"
            "--video" "qxl"
            ...$args
        ]
    }
}
