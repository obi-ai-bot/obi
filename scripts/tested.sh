#!/bin/bash
# What passed on this Mac, so a release doesn't run again what the merge ritual just ran
# (docs/release.md, "Tests a release skips").
#
#   scripts/tested.sh run <suite>     runs the suite on this checkout; records it only if it passed
#                                     and the files didn't change while it ran
#   scripts/tested.sh check <suite>   exit 0 if HEAD's files passed it here, saying why either way
#
# Suites: swift-test (`swift test`) and mac-tests (the Oby scheme's MacTests). There's no way to
# record a suite without running it here. A record says "these files passed this suite with this
# Xcode, Swift and Rust": one file per suite and fingerprint under
# ~/Library/Application Support/Oby-release/tested/, with an HMAC whose key lives in the login
# keychain (service oby-release-tested), so a record written or edited by hand, or by an agent
# boxed away from the keychain, doesn't verify. Only a clean checkout is run, recorded or matched.
set -euo pipefail

tested_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tested_dir="$HOME/Library/Application Support/Oby-release/tested"
tested_pbxproj="apps/Oby.xcodeproj/project.pbxproj"
# Build caches shared with release.sh, one set per toolchain (docs/release.md, "Warm builds").
tested_caches="$HOME/Library/Caches/Oby-release"

# The paths a suite's result depends on; empty is the whole tree. swift-test builds only the Swift
# package: Package.swift, Package.resolved and every target's `path:` (plus SwiftPM's default
# Sources/ and Tests/, for a target without one), read from HEAD's Package.swift.
tested_paths() {
    case "$1" in
        swift-test)
            printf '%s\n' Package.swift Package.resolved Sources Tests
            git -C "$tested_root" show HEAD:Package.swift | sed -nE 's/.*(^|[^[:alnum:]_])path:[[:space:]]*"([^"]*)".*/\2/p'
            ;;
    esac
}

# Xcode, Swift and the Rust that builds obid (~/.cargo/bin first, as bundle-obid.sh): a result only
# counts with the same tools. Also keys the build caches.
tested_toolchain() {
    { xcodebuild -version; swift --version 2>&1; PATH="$HOME/.cargo/bin:$PATH" rustc -vV; } | shasum -a 256 | cut -c1-16
}

# HEAD's files for a suite, by content: `git ls-tree` with project.pbxproj's version lines
# (what release.sh's bump changes) normalized, and the gitignored Signing.local.xcconfig, hashed.
# Fails on a checkout with any change, untracked files included.
tested_fingerprint() {
    local suite="$1" normalized local_signing="$tested_root/apps/config/Signing.local.xcconfig"
    [[ -z "$(git -C "$tested_root" status --porcelain --untracked-files=all)" ]] || return 1
    normalized="$(git -C "$tested_root" show "HEAD:$tested_pbxproj" \
        | sed -E 's/(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = [^;]+;/\1 = _;/' | git hash-object --stdin)"
    local -a paths=()
    while IFS= read -r path; do paths+=("$path"); done < <(tested_paths "$suite")
    {
        git -C "$tested_root" ls-tree -r --full-tree HEAD -- ${paths[@]+"${paths[@]}"} \
            | awk -F'\t' -v OFS='\t' -v p="$tested_pbxproj" -v h="$normalized" \
                '$2 == p { split($1, a, " "); $1 = a[1] " " a[2] " " h } { print }'
        if [[ -f "$local_signing" ]]; then printf 'Signing.local.xcconfig %s\n' "$(shasum -a 256 < "$local_signing")"; fi
    } | shasum -a 256 | cut -c1-64
}

# The HMAC key, made once. `security -w` takes it as an argument, so it's in this user's process
# list for an instant; anything running as this user can read the keychain item anyway.
tested_key() {
    security find-generic-password -s oby-release-tested -a hmac -w 2>/dev/null && return
    security add-generic-password -s oby-release-tested -a hmac -w "$(openssl rand -hex 32)" >/dev/null
    security find-generic-password -s oby-release-tested -a hmac -w
}

# HMAC-SHA256 of stdin, the key on the first line (never in an argument).
tested_hmac() {
    perl -MDigest::SHA=hmac_sha256_hex -e '$k = <STDIN>; chomp $k; local $/; print hmac_sha256_hex(<STDIN> // "", $k)'
}

# The suite's one command, run from the checkout. MacTests uses the release's DerivedData and
# builds obid (in release, both architectures) into the cargo target the archive then reuses.
tested_command() {
    local cache
    cache="$tested_caches/$(tested_toolchain)"
    case "$1" in
        swift-test) (cd "$tested_root" && swift test) ;;
        mac-tests) (cd "$tested_root" && xcodebuild -project apps/Oby.xcodeproj -scheme Oby -destination 'platform=macOS' \
            -derivedDataPath "$cache/DerivedData" OBY_CARGO_TARGET_DIR="$cache/cargo" test) ;;
    esac
}

# Runs the suite and records it when it passed on files that were the same before and after.
tested_run() {
    local suite="$1" before after toolchain key body file status=0
    case "$suite" in swift-test|mac-tests) ;; *) echo "tested.sh: suites are swift-test and mac-tests" >&2; return 2 ;; esac
    before="$(tested_fingerprint "$suite")" || { echo "tested.sh: the checkout has changes: commit or put them aside first" >&2; return 1; }
    toolchain="$(tested_toolchain)"
    tested_command "$suite" || status=$?
    [[ "$status" == 0 ]] || { echo "tested.sh: $suite failed (exit $status): nothing recorded" >&2; return "$status"; }
    after="$(tested_fingerprint "$suite")" || { echo "tested.sh: the checkout changed while $suite ran: nothing recorded" >&2; return 1; }
    [[ "$after" == "$before" ]] || { echo "tested.sh: HEAD moved while $suite ran: nothing recorded" >&2; return 1; }
    [[ "$(tested_toolchain)" == "$toolchain" ]] || { echo "tested.sh: the toolchain changed while $suite ran: nothing recorded" >&2; return 1; }
    key="$(tested_key)" || { echo "tested.sh: no HMAC key in the keychain: nothing recorded" >&2; return 1; }
    body="$(printf 'tree %s\nsuite %s\ntoolchain %s\ncommit %s\ntime %s' "$before" "$suite" "$toolchain" \
        "$(git -C "$tested_root" rev-parse HEAD)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    file="$tested_dir/$suite/$before"
    mkdir -p "$tested_dir/$suite"
    printf '%s\nhmac %s\n' "$body" "$(printf '%s\n%s' "$key" "$body" | tested_hmac)" > "$file"
    echo "recorded: $suite passed on tree ${before:0:12} ($(git -C "$tested_root" rev-parse --short HEAD))"
}

# Prints why HEAD's files do or don't count as tested for the suite; exit 0 when they do.
tested_check() {
    local suite="$1" fingerprint toolchain file body hmac key
    fingerprint="$(tested_fingerprint "$suite")" || { echo "the checkout has changes"; return 1; }
    file="$tested_dir/$suite/$fingerprint"
    [[ -f "$file" ]] || { echo "no record of tree ${fingerprint:0:12} passing it on this Mac"; return 1; }
    body="$(sed -n '1,5p' "$file")"
    hmac="$(sed -n 's/^hmac //p' "$file")"
    key="$(security find-generic-password -s oby-release-tested -a hmac -w 2>/dev/null)" || { echo "no HMAC key in the keychain"; return 1; }
    [[ -n "$hmac" && "$(printf '%s\n%s' "$key" "$body" | tested_hmac)" == "$hmac" ]] || { echo "the record of tree ${fingerprint:0:12} doesn't verify (edited?)"; return 1; }
    [[ "$(sed -n '1p;2p' <<< "$body")" == "tree $fingerprint"$'\n'"suite $suite" ]] || { echo "the record is for another tree or suite"; return 1; }
    toolchain="$(tested_toolchain)"
    [[ "$(sed -n 's/^toolchain //p' <<< "$body")" == "$toolchain" ]] || { echo "tree ${fingerprint:0:12} passed with another Xcode, Swift or Rust"; return 1; }
    echo "tree ${fingerprint:0:12} passed it on this Mac at $(sed -n 's/^time //p' <<< "$body") (commit $(sed -n 's/^commit //p' <<< "$body" | cut -c1-9))"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        run) [[ $# -eq 2 ]] || { echo "usage: scripts/tested.sh run <suite>" >&2; exit 2; }; tested_run "$2" ;;
        check) [[ $# -eq 2 ]] || { echo "usage: scripts/tested.sh check <suite>" >&2; exit 2; }; tested_check "$2" ;;
        *) sed -n '2,14p' "$0"; exit 2 ;;
    esac
fi
