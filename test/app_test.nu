# Tests for Nushell apps installer.

use std/assert
use std/testing *
use . *

source ../src/install/app.nu

def "http get" [url: string] {
    open data/test/github_trees.json
}

@test
def create-entry-wraps-shebang [] {
    if $nu.os-info.name == "windows" {
        return
    }

    let temp = mktemp --directory --tmpdir
    let entry = $"($temp)/main.nu"
    "#!/usr/bin/env nu" | save $entry

    mock-env
    create-entry "" $entry "/usr/local/bin" $"($temp)/main.sh"
    assert path $"($temp)/main.sh"
    let text = open --raw $"($temp)/main.sh"
    assert str contains $text 'exec nu "${folder}/main.nu" "$@"'
}

@test
def json-parser-finds-all-apps [] {
    let apps = find-apps "main"
    assert equal $apps ["pyapp" "rsapp"]
}
