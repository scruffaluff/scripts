# Just configuration file for running commands.
#
# For more information, visit https://just.systems.

[windows]
set shell := ["powershell.exe", "-NoLogo", "-Command"]

export DENO_INSTALL_ROOT := justfile_directory() / ".vendor/lib/deno"
export PATH := if os() == "windows" {
  join(justfile_directory(), ".vendor\\bin;") + join(justfile_directory(),
  ".vendor\\lib\\deno\\bin;") + env("PATH")
} else {
  justfile_directory() / ".vendor/bin:" + justfile_directory() /
  ".vendor/lib/bats-core/bin:" + justfile_directory() / ".vendor/lib/deno/bin:"
  + env("PATH")
}
export PSModulePath := if os() == "windows" {
  join(justfile_directory(), ".vendor\\lib\\powershell\\modules;") +
  env("PSModulePath", "")
} else { "" }
export UV_PYTHON_INSTALL_DIR :=  justfile_directory() / ".vendor/lib/uv/python"
export UV_TOOL_BIN_DIR := justfile_directory() / ".vendor/bin"
export UV_TOOL_DIR := justfile_directory() / ".vendor/lib/uv/tool"

# Run continuous integration pipeline.
ci: setup lint test doc

# Build documentation.
[unix]
doc:
  cp -r src/action src/install data/public/
  deno run --allow-all npm:vitepress build .

# Build documentation.
[windows]
doc:

# Format project files.
[unix]
format +paths=".":
  prettier --write {{paths}}
  shfmt --write src test
  uv tool run ruff format {{paths}}

# Format project files.
[windows]
format +paths=".":
  #!powershell.exe
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  $PSNativeCommandUseErrorActionPreference = $True
  prettier --write {{paths}}
  Invoke-ScriptAnalyzer -Fix -Recurse -Path src -Settings CodeFormatting
  Invoke-ScriptAnalyzer -Fix -Recurse -Path test -Settings CodeFormatting
  $Scripts = Get-ChildItem -Recurse -Filter *.ps1 -Path src, test
  foreach ($Script in $Scripts) {
    $Text = Get-Content -Raw $Script.FullName
    [System.IO.File]::WriteAllText($Script.FullName, $Text)
  }
  uv tool run ruff format {{paths}}

# Install project applications and scripts.
[script("nu")]
install +programs="all": setup
  let repo = "{{justfile_directory()}}"
  let apps = ls src/app | where type == dir | get name | path basename
  let scripts = ls src/script | where type == file | get name | path parse
  | get stem | uniq
  let programs = if "{{programs}}" == "all" {
    [...$apps ...$scripts]
  } else {
    "{{programs}}" | split words
  }
  for program in $programs {
    if $program in $apps {
      nu src/install/app.nu --version $repo $program
    } else if $program in $scripts {
      nu src/install/script.nu --version $repo $program
    } else {
      error make $"No program found for '($program)'."
    }
  }

# Analyze files for issues.
[unix]
lint +paths=".":
  #!/usr/bin/env sh
  set -eu
  prettier --check {{paths}}
  shfmt --diff src test
  files="$(find src test -name '*.sh' -or -name '*.bats')"
  for file in ${files}; do
    shellcheck "${file}"
  done
  deno lint {{paths}}
  uv tool run ruff format --check {{paths}}
  uv tool run ruff check {{paths}}
  uv tool run ty check --config-file ty.toml {{paths}}

# Analyze files for issues.
[windows]
lint +paths=".":
  prettier --check {{paths}}
  Invoke-ScriptAnalyzer -EnableExit -Recurse -Path src -Settings CodeFormatting
  Invoke-ScriptAnalyzer -EnableExit -Recurse -Path test -Settings CodeFormatting
  Invoke-ScriptAnalyzer -EnableExit -Recurse -Path src -Settings \
    data/config/script_analyzer.psd1
  Invoke-ScriptAnalyzer -EnableExit -Recurse -Path test -Settings \
    data/config/script_analyzer.psd1
  deno lint {{paths}}
  uv tool run ruff format --check {{paths}}
  uv tool run ruff check {{paths}}
  uv tool run ty check --config-file ty.toml {{paths}}

# List available commands.
[default]
@list:
  just --list

# Run Nushell in project environment.
[no-exit-message]
@nu *args="nu --login":
  nu --commands "{{args}}"

# Install development tools and dependencies.
[unix]
setup:
  #!/usr/bin/env sh
  set -eu
  arch='{{replace(replace(arch(), "x86_64", "amd64"), "aarch64", "arm64")}}'
  os='{{replace(os(), "macos", "darwin")}}'
  mkdir -p .vendor/bin .vendor/lib
  if ! command -v jq > /dev/null 2>&1; then
    echo 'Installing Jq.'
    src/install/jq.sh --preserve-env --dest .vendor/bin
  fi
  echo "Using $(jq --version)."
  if ! command -v nu > /dev/null 2>&1; then
    echo 'Installing Nushell.'
    src/install/nushell.sh --preserve-env --dest .vendor/bin
  fi
  echo "Using Nushell $(nu --version)."
  if ! command -v deno > /dev/null 2>&1; then
    echo 'Installing Deno.'
    src/install/deno.sh --preserve-env --dest .vendor/bin
  fi
  echo "Using $(deno -V)."
  if ! command -v uv > /dev/null 2>&1; then
    echo 'Installing Uv.'
    src/install/uv.sh --preserve-env --dest .vendor/bin
  fi
  echo "Using $(uv --version)."
  for spec in 'assert:v2.1.0' 'core:v1.11.1' 'file:v0.4.0' 'support:v0.3.0'; do
    bats_check=''
    pkg="${spec%:*}"
    tag="${spec#*:}"
    if [ ! -d ".vendor/lib/bats-${pkg}" ]; then
      if [ -z "${bats_check}" ]; then
        echo 'Installing Bats.'
        bats_check='1'
      fi
      git clone -c advice.detachedHead=false --branch "${tag}" --depth 1 \
        "https://github.com/bats-core/bats-${pkg}.git" ".vendor/lib/bats-${pkg}"
    fi
  done
  echo "Using $(bats --version)."
  if [ ! -d .vendor/lib/nutest ]; then
    echo 'Installing Nutest.'
    git clone -c advice.detachedHead=false --branch main \
      --depth 1 https://github.com/vyadh/nutest.git .vendor/lib/nutest
  fi
  echo "Using Nutest $(git -C .vendor/lib/nutest rev-parse HEAD)."
  if ! command -v prettier > /dev/null 2>&1; then
    echo 'Installing Prettier.'
    deno install --allow-all --global npm:prettier
  fi
  echo "Using Prettier $(prettier --version)."
  if ! command -v shellcheck > /dev/null 2>&1; then
    echo 'Installing ShellCheck.'
    shellcheck_arch='{{arch()}}'
    shellcheck_version="$(curl --fail --location --show-error \
      https://formulae.brew.sh/api/formula/shellcheck.json |
      jq --exit-status --raw-output .versions.stable)"
    curl --fail --location --show-error --output /tmp/shellcheck.tar.xz \
      "https://github.com/koalaman/shellcheck/releases/download/v${shellcheck_version}/shellcheck-v${shellcheck_version}.${os}.${shellcheck_arch}.tar.xz"
    tar fx /tmp/shellcheck.tar.xz -C /tmp
    install "/tmp/shellcheck-v${shellcheck_version}/shellcheck" .vendor/bin/
  fi
  echo "Using $(shellcheck --version)."
  if ! command -v shfmt > /dev/null 2>&1; then
    echo 'Installing Shfmt.'
    shfmt_version="$(curl --fail --location --show-error \
      https://formulae.brew.sh/api/formula/shfmt.json |
      jq --exit-status --raw-output .versions.stable)"
    curl --fail --location --show-error --output .vendor/bin/shfmt \
      "https://github.com/mvdan/sh/releases/download/v${shfmt_version}/shfmt_v${shfmt_version}_${os}_${arch}"
    chmod 755 .vendor/bin/shfmt
  fi
  echo "Using Shfmt $(shfmt --version)."
  echo 'Installing packages with Deno.'
  if [ -n "${INIT:-}" ]; then
    deno install
    just format
  else
    deno install --frozen
  fi

# Install development tools and dependencies.
[windows]
setup:
  #!powershell.exe
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  $PSNativeCommandUseErrorActionPreference = $True
  $ModulePath = '.vendor\lib\powershell\modules'
  New-Item -Force -ItemType Directory -Path $ModulePath | Out-Null
  if (-not (Get-Command -ErrorAction SilentlyContinue jq)) {
    Write-Output 'Installing Jq.'
    src/install/jq.ps1 --preserve-env --dest .vendor/bin
  }
  Write-Output "Using $(jq --version)."
  if (-not (Get-Command -ErrorAction SilentlyContinue nu)) {
    Write-Output 'Installing Nushell.'
    src/install/nushell.ps1 --preserve-env --dest .vendor/bin
  }
  Write-Output "Using Nushell $(nu --version)"
  if (-not (Get-Command -ErrorAction SilentlyContinue deno)) {
    Write-Output 'Installing Deno.'
    src/install/deno.ps1 --preserve-env --dest .vendor/bin
  }
  Write-Output "Using $(deno -V)."
  if (-not (Get-Command -ErrorAction SilentlyContinue uv)) {
    Write-Output 'Installing Uv.'
    src/install/uv.ps1 --preserve-env --dest .vendor/bin
  }
  Write-Output "Using $(uv --version)."
  if (-not (Test-Path -Path .vendor/lib/nutest -PathType Container)) {
    Write-Output 'Installing Nutest.'
    git clone -c advice.detachedHead=false --branch main --depth 1 `
      https://github.com/vyadh/nutest.git .vendor/lib/nutest
  }
  Write-Output "Using Nutest $(git -C .vendor/lib/nutest rev-parse HEAD)."
  if (-not (Get-Command -ErrorAction SilentlyContinue prettier)) {
    Write-Output 'Installing Prettier.'
    deno install --allow-all --global npm:prettier
  }
  Write-Output "Using Prettier $(prettier --version)."
  # If executing task from PowerShell Core, error such as "'Install-Module'
  # command was found in the module 'PowerShellGet', but the module could not be
  # loaded" unless earlier versions of PackageManagement and PowerShellGet are
  # imported.
  Import-Module -MaximumVersion 1.1.0 -MinimumVersion 1.0.0 PackageManagement
  Import-Module -MaximumVersion 1.9.9 -MinimumVersion 1.0.0 PowerShellGet
  Get-PackageProvider -Force Nuget | Out-Null
  if (
    -not (Get-Module -ListAvailable -FullyQualifiedName `
    @{ModuleName = 'PSScriptAnalyzer'; ModuleVersion = '1.0.0' })
  ) {
    Write-Output 'Installing PSScriptAnalyzer.'
    Find-Module -MinimumVersion 1.0.0 -Name PSScriptAnalyzer | Save-Module `
      -Force -Path $ModulePath
  }
  Write-Output "Using PSScriptAnalyzer $((Get-Module -ListAvailable `
    PSScriptAnalyzer | Select-Object -First 1).Version)."
  if (
    -not (Get-Module -ListAvailable -FullyQualifiedName `
    @{ModuleName = 'Pester'; ModuleVersion = '5.0.0' })
  ) {
    Write-Output 'Installing Pester.'
    Find-Module -MinimumVersion 5.0.0 -Name Pester | Save-Module -Force -Path `
      $ModulePath
  }
  Write-Output "Using Pester $((Get-Module -ListAvailable Pester | `
    Select-Object -First 1).Version)."
  Write-Output 'Installing packages with Deno.'
  if ($Env:INIT) {
    deno install
    just format
  }
  else {
    deno install --frozen
  }

# Run tests (use DEBUG=1 for debugger).
test: test-sh test-nu test-py

# Run Nushell tests (use DEBUG=1 for debugger).
[script("nu")]
test-nu *args="--path test":
  use "{{replace(justfile_directory(), '\', '/') / '.vendor/lib/nutest/nutest'}}" run-tests
  if ($env.DEBUG? | into bool --relaxed) {
    with-env {NU_BACKTRACE: "1"} {
      run-tests --fail {{args}}
    }
  } else {
    run-tests --fail {{args}}
  }

# Run Python tests (use DEBUG=1 for debugger).
[script("nu")]
test-py *args="test":
  if ($env.DEBUG? | into bool --relaxed) {
    uv tool run --python 3.12 --with loguru,typer,pyyaml pytest --pdb {{args}}
  } else {
    uv tool run --python 3.12 --with loguru,typer,pyyaml pytest {{args}}
  }

# Run Bash tests (use DEBUG=1 for debugger).
[unix]
test-sh *args="test":
  #!/usr/bin/env sh
  if [ -n "${DEBUG:-}" ]; then
    bats --recursive --trace {{args}}
  else
    bats --recursive {{args}}
  fi

# Run PowerShell tests (use DEBUG=1 for debugger).
[windows]
test-sh *args:
  #!powershell.exe
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  $PSNativeCommandUseErrorActionPreference = $True
  Import-Module Pester
  $Config = [PesterConfiguration]::Default
  $Config.Run = @{ Exit = $True; Path = 'test'; TestExtension = '.test.ps1' }
  $Config.Output.Verbosity = 'Detailed'
  if ($Env:DEBUG) {
    $Config.Output = @{
      Verbosity = [PesterConfigurationOutput]::Diagnostic;
      StackTraceVerbosity = [PesterConfigurationStackTraceVerbosity]::Full;
    }
  }
  Invoke-Pester -Configuration $Config {{args}}
