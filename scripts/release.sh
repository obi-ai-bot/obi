#!/bin/bash
# Ships Oby as a notarized DMG that updates itself (#282): docs/release.md has the steps around it.
#
#   scripts/release.sh <version> [--dry-run] [--full] [--full-build] [--notes <file>] [--from-upload]
#
# Run on a Mac with Xcode 27. In order:
#   0. runs the checks (swift test, the Mac app with MacTests), one after the other, through
#      scripts/tested.sh: nothing is built unless they pass. A check that already passed on this
#      Mac on the same files (run by the merge ritual with `scripts/tested.sh run`) is skipped,
#      saying so; --full runs them all;
#   1. bumps the version: CFBundleShortVersionString from <version>, the build number from the git
#      commit count, committed on the current branch, once the checkout is checked unchanged;
#   2. archives the Oby scheme (Release) and exports it with Developer ID
#      (apps/ExportOptions-DeveloperID.plist, teamID from apps/config/Signing.xcconfig), with
#      DerivedData and obid's cargo target kept per toolchain in ~/Library/Caches/Oby-release; checks
#      the checkout again, both architectures (lipo) and every signature (codesign), and scans the
#      app for secrets (gitleaks) before anything leaves this Mac;
#   3. notarizes the app (xcrun notarytool, keychain profile "oby-notary") and staples it; while
#      Apple works it scans the commits since the last tag and gathers the release notes;
#   4. builds Oby-<version>.dmg with an Applications link (and a background, with create-dmg), then
#      signs, notarizes and staples the DMG, and checks it, the app in it and a quarantined copy
#      (spctl, stapler validate, hdiutil verify);
#   5. signs the DMG for Sparkle (sign_update, the EdDSA key in the keychain);
#   6. writes the appcast entry, with the merged pull requests since the last tag as release notes,
#      and scans it for secrets: a finding anywhere, or no scanner, and nothing is published;
#   7. uploads the DMG, checks that its public URL serves the same bytes, then uploads appcast.xml
#      to R2 (wrangler, or aws against the R2 endpoint);
#   8. tags v<version>.
#
# --dry-run does everything up to the signatures with ad hoc identities, and leaves out the
# notarization, the upload, the commit and the tag, so it runs on any Mac today. Everything lands in
# build/release/ (gitignored).
#
# --full-build archives the full build (OBY_FULL_BUILD=1): cloudflared, obi-vm and obid's web app,
# which the launch build leaves out, are in, and obi-vm's guest image is checked. Without it the
# release checks that none of them is in the app (docs/release.md, "Full builds").
#
# Credentials come from the keychain (notarytool's profile, Sparkle's key, wrangler's own login,
# or R2 keys under the service "oby-r2") or from .env.local (gitignored), and are never printed.
# Nothing here is ever `set -x`.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/release"
notary_profile="${OBY_NOTARY_PROFILE:-oby-notary}"
# The R2 bucket the appcast and the DMGs live in (docs/release.md).
bucket="${OBY_R2_BUCKET:-oby-downloads}"
# Where obid fetches the guest image obi-vm boots (core/obi-vm/image.json pins it;
# scripts/publish-vm-image.sh puts it there): the same bucket, under vm/<root.img's SHA-256>/.
vm_images="https://downloads.oby.deskree.com/vm"
minimum_system="26.0"
# What apps/config/Signing.xcconfig holds for OBY_SPARKLE_PUBLIC_KEY until the key is generated.
placeholder_public_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
# What passed on this Mac, and the build caches kept between releases (docs/release.md).
# shellcheck source=scripts/tested.sh
source "$root/scripts/tested.sh"
# What a stopped release would leave running or mounted: cleanup kills and detaches them on exit.
bg_pids=()
mnt=""

# Each step says how long the release has run, so the slow ones show.
say() { printf '\033[1m==> [%d:%02d] %s\033[0m\n' $((SECONDS / 60)) $((SECONDS % 60)) "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf 'release.sh: %s\n' "$*" >&2; exit 1; }

kill_tree() {
    local child
    for child in $(pgrep -P "$1" || true); do kill_tree "$child"; done
    kill "$1" 2>/dev/null || true
}

cleanup() {
    local pid
    for pid in ${bg_pids[@]+"${bg_pids[@]}"}; do kill_tree "$pid"; done
    if [[ -n "$mnt" ]]; then hdiutil detach "$mnt" -force -quiet 2>/dev/null || true; fi
}

# Mounts a disk image (hdiutil attach's options, the image last) at $mnt; detach unmounts it.
attach() {
    mnt="$(hdiutil attach -nobrowse -noautoopen "$@" | awk -F'\t' '/\/Volumes\//{print $NF}')"
    [[ -n "$mnt" ]] || die "couldn't attach ${*: -1}"
}
detach() {
    hdiutil detach "$mnt" -quiet || hdiutil detach "$mnt" -force -quiet
    mnt=""
}

# The checkout as the release found it: nothing changed, untracked files included, and HEAD at
# `expected`. A real release checks it before its version commit and after the archive.
still_clean() {
    local expected="$1" when="$2"
    [[ -z "$(git -C "$root" status --porcelain --untracked-files=all)" ]] || die "the checkout changed $when: nothing is published"
    [[ "$(git -C "$root" rev-parse HEAD)" == "$expected" ]] || die "HEAD moved $when: nothing is published"
}

# Notarizes and staples one item (the app, as a zip, or the DMG); `log` names its log.
notarize() {
    local item="$1" submit="$2" log="$3"
    xcrun notarytool submit "$submit" --keychain-profile "$notary_profile" --wait > "$out/$log" 2>&1 \
        || { cat "$out/$log"; die "notarization failed: build/release/$log"; }
    grep -E '^ *(id|status):' "$out/$log" | tail -n 2 | sed 's/^ */    /'
    xcrun stapler staple "$item" > /dev/null || { cat "$out/$log"; die "no ticket to staple on ${item#"$out/"}: build/release/$log"; }
    xcrun stapler validate "$item" || die "the ticket on ${item#"$out/"} doesn't validate"
}

# A build setting from apps/config/Signing.local.xcconfig, else apps/config/Signing.xcconfig: comments
# stripped, the empty $() that keeps "//" out of a URL removed.
setting() {
    local name="$1" file value=""
    for file in "$root/apps/config/Signing.local.xcconfig" "$root/apps/config/Signing.xcconfig"; do
        [[ -f "$file" ]] || continue
        value="$(grep -E "^[[:space:]]*$name[[:space:]]*=" "$file" | tail -n 1 || true)"
        [[ -n "$value" ]] && break
    done
    value="${value#*=}"
    value="${value%%//*}"
    value="${value//\$()/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Text safe inside XML, in an element or a quoted attribute: &, <, > and ". With sed, not
# ${text//x/&amp;}: in bash 5.2 an & in the replacement is the match itself.
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# The release notes as an HTML list: the subjects of the merged pull requests since `since`
# (a tag, or empty for everything), one <li> each. Oby squash-merges, so each PR is one commit
# whose subject ends with its number.
release_notes() {
    local since="$1" range subject lines=""
    if [[ -n "$since" ]]; then range="$since..HEAD"; else range="HEAD"; fi
    while IFS= read -r subject; do
        [[ -n "$subject" ]] || continue
        lines+="<li>$(xml_escape "$subject")</li>"$'\n'
    done < <(git -C "$root" log --format=%s "$range" | grep -E '\(#[0-9]+\)$' || true)
    if [[ -z "$lines" ]]; then lines="<li>Fixes and improvements.</li>"$'\n'; fi
    printf '<ul>\n%s</ul>\n' "$lines"
}

# Lines of a notes file as the HTML list.
notes_from_file() {
    local file="$1" line lines=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        lines+="<li>$(xml_escape "$line")</li>"$'\n'
    done < "$file"
    printf '<ul>\n%s</ul>\n' "$lines"
}

# One <item> of the appcast: version build pubdate url length signature notes_html.
appcast_item() {
    local version="$1" build="$2" pubdate="$3" url="$4" length="$5" signature="$6" notes="$7"
    url="$(xml_escape "$url")"
    signature="$(xml_escape "$signature")"
    cat <<EOF
        <item>
            <title>Version $version</title>
            <pubDate>$pubdate</pubDate>
            <sparkle:version>$build</sparkle:version>
            <sparkle:shortVersionString>$version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$minimum_system</sparkle:minimumSystemVersion>
            <description><![CDATA[
$notes            ]]></description>
            <enclosure url="$url" type="application/octet-stream" length="$length" sparkle:edSignature="$signature"/>
        </item>
EOF
}

# The appcast with `item` first, then the items of the previous appcast (a file, or empty).
write_appcast() {
    local previous="$1" item="$2" target="$3" older=""
    if [[ -n "$previous" && -f "$previous" ]]; then
        older="$(sed -n '/<item>/,/<\/item>/p' "$previous")"
    fi
    {
        cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Oby</title>
        <link>https://github.com/deskree-inc/oby</link>
        <description>Oby's updates.</description>
        <language>en</language>
EOF
        printf '%s\n' "$item"
        [[ -n "$older" ]] && printf '%s\n' "$older"
        cat <<EOF
    </channel>
</rss>
EOF
    } > "$target"
}

# Sparkle's command-line tools from the archive's package checkout (in DerivedData `derived`), else
# any DerivedData's.
sparkle_bin() {
    local candidate
    candidate="$1/SourcePackages/artifacts/sparkle/Sparkle/bin"
    [[ -x "$candidate/sign_update" ]] && { printf '%s' "$candidate"; return; }
    candidate="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type d -path '*/artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -n 1 || true)"
    [[ -n "$candidate" && -x "$candidate/sign_update" ]] && { printf '%s' "$candidate"; return; }
    return 1
}

# The Developer ID Application identity of the team, by its hash, for codesign.
developer_id_identity() {
    local team="$1"
    security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($team)" | head -n 1 | awk '{print $2}'
}

# gitleaks over what's about to be published: folders and files with scan_paths, every commit since
# `since` (a tag, or empty for the whole history) with scan_history. Findings are redacted, so no
# secret is printed. A finding stops the release. Without gitleaks a real release stops too
# (AGENTS.md: if the scanner can't run, nothing goes out); a dry run notes it, since it publishes
# nothing.
have_gitleaks() {
    local dry_run="$1"
    command -v gitleaks >/dev/null 2>&1 && return
    $dry_run || die "gitleaks isn't installed (brew install gitleaks): nothing is published unscanned"
    note "gitleaks isn't installed: a real release stops here (brew install gitleaks)"
    return 1
}

scan_paths() {
    local report="$out/gitleaks.json" status target
    for target in "$@"; do
        status=0
        gitleaks dir "$target" --config "$root/.gitleaks.toml" --no-banner --redact --exit-code=99 --report-format=json --report-path="$report" > "$out/gitleaks.log" 2>&1 || status=$?
        case "$status" in
            0) note "clean: ${target#"$out/"}" ;;
            99) die "possible secret in ${target#"$out/"}: build/release/gitleaks.json says where (redacted)" ;;
            *) tail -n 20 "$out/gitleaks.log"; die "gitleaks couldn't scan ${target#"$out/"}: nothing is published unscanned" ;;
        esac
    done
}

scan_history() {
    local since="$1" report="$out/gitleaks.json" status=0
    if [[ -n "$since" ]]; then
        gitleaks git "$root" "--log-opts=$since..HEAD" --no-banner --redact --exit-code=99 --report-format=json --report-path="$report" > "$out/gitleaks.log" 2>&1 || status=$?
    else
        gitleaks git "$root" --no-banner --redact --exit-code=99 --report-format=json --report-path="$report" > "$out/gitleaks.log" 2>&1 || status=$?
    fi
    case "$status" in
        0) note "clean: the commits since ${since:-the beginning}" ;;
        99) die "possible secret in a commit since ${since:-the beginning}: build/release/gitleaks.json says where (redacted)" ;;
        *) tail -n 20 "$out/gitleaks.log"; die "gitleaks couldn't scan the commits: nothing is published unscanned" ;;
    esac
}

# Both architectures in a binary: a release runs on Apple silicon and Intel Macs.
check_universal() {
    local archs
    archs=" $(lipo -archs "$1") "
    [[ "$archs" == *" arm64 "* && "$archs" == *" x86_64 "* ]] || die "${1#"$out/"} is${archs% } only, not arm64 and x86_64"
}

# obi-vm, the box for teammates' jobs (#797): arm64, signed with the virtualization entitlement,
# built for the image core/obi-vm/image.json pins, and that image published where obid fetches it,
# each file its pinned size. A dry run only warns about the image.
check_obi_vm() {
    local vm="$1" dry_run="$2" pin="$root/core/obi-vm/image.json" root_sha file bytes got published=published sig
    [[ -x "$vm" ]] || die "no Contents/Helpers/obi-vm"
    [[ "$(lipo -archs "$vm")" == arm64 ]] || die "obi-vm is $(lipo -archs "$vm"), not arm64"
    # Exactly its entitlements file's, the hardened runtime, and (but in a dry run) Developer ID.
    diff <(codesign -d --entitlements - --xml "$vm" 2>/dev/null | plutil -convert xml1 -o - -) \
        <(plutil -convert xml1 -o - "$root/core/obi-vm/obi-vm.entitlements") > /dev/null \
        || die "obi-vm's entitlements aren't exactly core/obi-vm/obi-vm.entitlements"
    sig="$(codesign -dvv "$vm" 2>&1)"
    grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\(.*runtime' <<< "$sig" || die "obi-vm isn't signed with the hardened runtime"
    if ! $dry_run; then
        grep -q '^Authority=Developer ID Application' <<< "$sig" || die "obi-vm isn't signed with Developer ID"
    fi
    # What obi-vm answers: every SHA-256 in the pin, and each size as "<name>.bytes".
    [[ "$("$vm" image | jq -cS .)" == "$(jq -cS '(to_entries | map(select(.value | type == "string")) | from_entries) + (.bytes | with_entries(.key += ".bytes" | .value |= tostring))' "$pin")" ]] \
        || die "obi-vm wasn't built for core/obi-vm/image.json's image"
    root_sha="$(jq -r '.["root.img"]' "$pin")"
    for file in vmlinuz.zst initrd.zst root.img.zst; do
        bytes="$(jq -r ".bytes[\"$file\"]" "$pin")"
        got="$(curl -fsI --max-time 20 "$vm_images/$root_sha/$file" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' || true)"
        if [[ "$got" != "$bytes" ]]; then
            local why="the guest image's $file isn't published at $vm_images/$root_sha/ (${got:-nothing} bytes, not $bytes): scripts/publish-vm-image.sh"
            if $dry_run; then note "warning: $why"; published="NOT published"; else die "$why"; fi
        fi
    done
    note "obi-vm: arm64, its entitlement, the image ${root_sha:0:12}… $published"
}

# The Cloudflare account the bucket is in: OBY_R2_ACCOUNT_ID from the environment, .env.local or the
# keychain (service oby-r2, account account-id). Wrangler gets it as CLOUDFLARE_ACCOUNT_ID, since a
# login that sees more than one account won't pick one by itself. Checked before anything is built.
r2_account() {
    if [[ -f "$root/.env.local" ]]; then
        # OBY_R2_ACCOUNT_ID, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, never in git.
        set -a; # shellcheck disable=SC1091
        source "$root/.env.local"; set +a
    fi
    : "${OBY_R2_ACCOUNT_ID:=$(security find-generic-password -s oby-r2 -a account-id -w 2>/dev/null || true)}"
    if command -v wrangler >/dev/null 2>&1; then
        if [[ -n "$OBY_R2_ACCOUNT_ID" ]]; then
            export CLOUDFLARE_ACCOUNT_ID="$OBY_R2_ACCOUNT_ID"
        elif [[ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
            local accounts
            accounts="$(wrangler whoami 2>/dev/null | grep -cE '[0-9a-f]{32}' || true)"
            (( accounts <= 1 )) || die "wrangler sees $accounts Cloudflare accounts and none is chosen: set OBY_R2_ACCOUNT_ID (or the keychain item oby-r2/account-id) to the one with the $bucket bucket: docs/release.md, Uploading"
        fi
        return
    fi
    command -v aws >/dev/null 2>&1 || die "neither wrangler nor aws is installed: docs/release.md, Uploading"
}

upload_r2() {
    local file="$1" name="$2" type="$3"
    if command -v wrangler >/dev/null 2>&1; then
        wrangler r2 object put "$bucket/$name" --file "$file" --content-type "$type" --remote
        return
    fi
    : "${AWS_ACCESS_KEY_ID:=$(security find-generic-password -s oby-r2 -a access-key-id -w 2>/dev/null || true)}"
    : "${AWS_SECRET_ACCESS_KEY:=$(security find-generic-password -s oby-r2 -a secret-access-key -w 2>/dev/null || true)}"
    [[ -n "$OBY_R2_ACCOUNT_ID" && -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]] || die "no R2 credentials in the keychain (service oby-r2) or .env.local: docs/release.md, Uploading"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    AWS_DEFAULT_REGION=auto aws s3 cp "$file" "s3://$bucket/$name" --content-type "$type" \
        --endpoint-url "https://$OBY_R2_ACCOUNT_ID.r2.cloudflarestorage.com"
}

main() {
    local version="" dry_run=false full=false full_build=false notes_file="" from_upload=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true ;;
            --full) full=true ;;
            --full-build) full_build=true ;;
            --from-upload) from_upload=true ;;
            --notes) shift; notes_file="${1:-}"; [[ -f "$notes_file" ]] || die "--notes needs a file" ;;
            -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
            -*) die "unknown option $1" ;;
            *) [[ -z "$version" ]] || die "one version only"; version="$1" ;;
        esac
        shift
    done
    [[ -n "$version" ]] || die "usage: scripts/release.sh <version> [--dry-run] [--full] [--full-build] [--notes <file>] [--from-upload]"
    ! { $from_upload && $dry_run; } || die "--from-upload publishes: it doesn't go with --dry-run"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the version is X.Y.Z, like 1.2.3"
    [[ "$(uname)" == "Darwin" ]] || die "runs on a Mac with Xcode"
    for tool in xcodebuild xcrun swift hdiutil codesign xmllint plutil git jq curl; do
        command -v "$tool" >/dev/null 2>&1 || die "$tool isn't installed"
    done

    local team feed base public_key
    team="$(setting OBY_TEAM_ID)"
    feed="$(setting OBY_APPCAST_URL)"
    public_key="$(setting OBY_SPARKLE_PUBLIC_KEY)"
    [[ -n "$team" ]] || die "OBY_TEAM_ID isn't set in apps/config/Signing.xcconfig"
    [[ -n "$feed" ]] || die "OBY_APPCAST_URL isn't set in apps/config/Signing.xcconfig"
    if [[ -z "$public_key" || "$public_key" == "$placeholder_public_key" ]]; then
        $dry_run || die "OBY_SPARKLE_PUBLIC_KEY in apps/config/Signing.xcconfig is still the placeholder: no shipped Oby could verify this update (docs/release.md, Sparkle keys)"
        note "OBY_SPARKLE_PUBLIC_KEY is still the placeholder: fine for a dry run"
    fi
    base="${feed%/*}"

    cd "$root"
    trap cleanup EXIT
    local tag="v$version" last_tag start_head
    git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "$tag exists already"
    last_tag="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
    start_head="$(git rev-parse HEAD)"
    if ! $dry_run && [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
        die "the working tree isn't clean: commit or put aside what's changed first"
    fi

    $dry_run || r2_account

    # A release that stopped at the upload (its build, DMG and appcast are in build/release/, and
    # HEAD is its version commit): publish what's there, through the same checks.
    if $from_upload; then
        local dmg="$out/Oby-$version.dmg" build
        [[ -f "$dmg" && -f "$out/appcast.xml" ]] || die "--from-upload needs build/release/Oby-$version.dmg and appcast.xml from this release"
        build="$(git log -1 --format=%s | sed -nE "s/^chore\(release\): Oby $version \(([0-9]+)\)$/\1/p")"
        [[ -n "$build" ]] || die "--from-upload runs on the release's own commit, chore(release): Oby $version (N)"
        grep -q "<sparkle:shortVersionString>$version</sparkle:shortVersionString>" "$out/appcast.xml" || die "build/release/appcast.xml has no entry for $version"
        spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null || die "$dmg isn't a notarized DMG Gatekeeper accepts"
        publish "$dmg" "$version" "$build" "$tag" "$base"
        return
    fi

    rm -rf "$out"
    mkdir -p "$out"

    # The build caches: one set per Xcode, Swift and Rust, so a new toolchain starts cold and the
    # old set goes.
    local toolchain cache derived
    toolchain="$(tested_toolchain)"
    cache="$tested_caches/$toolchain"
    derived="$cache/DerivedData"
    mkdir -p "$cache"
    find "$tested_caches" -mindepth 1 -maxdepth 1 ! -name "$toolchain" -exec rm -rf {} +

    # 0. The checks Oby runs before a merge (docs/ci.md), without the iPhone app, which this release
    #    doesn't ship: nothing is built for release, let alone uploaded, unless they pass. One that
    #    passed on these files on this Mac (scripts/tested.sh) doesn't run again; the ones that run
    #    run one after the other, through tested.sh, which records them when they pass on a clean
    #    checkout. Side by side, the load timed tests out (CursorTests, CharacterTests' page, 0.3.0).
    say "Checks"
    local suite reason recording=true
    local -a running=()
    if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
        recording=false
        note "the checkout has changes: every check runs, and none is recorded (dry run)"
    fi
    for suite in swift-test mac-tests; do
        if $full; then
            note "running $suite: --full"
        elif reason="$(tested_check "$suite")"; then
            note "skipped $suite: $reason"
            continue
        elif $recording; then
            note "running $suite: $reason"
        fi
        running+=("$suite")
    done
    if (( ${#running[@]} )); then
        for suite in "${running[@]}"; do
            note "$suite…"
            if $recording; then
                tested_run "$suite" > "$out/$suite.log" 2>&1 &
            else
                tested_command "$suite" > "$out/$suite.log" 2>&1 &
            fi
            # In the background only so a stopped release stops it too (cleanup).
            bg_pids=($!)
            if ! wait "${bg_pids[0]}"; then
                bg_pids=()
                tail -n 40 "$out/$suite.log"
                die "failed: $suite (build/release/$suite.log)"
            fi
            bg_pids=()
        done
        note "passed: ${running[*]}"
        for suite in "${running[@]}"; do grep -h '^recorded: ' "$out/$suite.log" | sed 's/^/    /' || true; done
    fi

    # 1. The version. For real, it's committed first, so the build number counts that commit and
    #    the tag names it; a dry run passes both to xcodebuild and changes nothing.
    local build
    if $dry_run; then
        build="$(git rev-list --count HEAD)"
        say "Dry run: Oby $version ($build), ad hoc signed, nothing notarized, uploaded or tagged"
    else
        still_clean "$start_head" "while the checks ran"
        say "Oby $version: bumping the version in apps/Oby.xcodeproj"
        build="$(( $(git rev-list --count HEAD) + 1 ))"
        sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $version;/; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $build;/" apps/Oby.xcodeproj/project.pbxproj
        git add apps/Oby.xcodeproj/project.pbxproj
        git commit -q -m "chore(release): Oby $version ($build)"
        [[ "$(git rev-list --count HEAD)" == "$build" ]] || die "the build number and the commit count disagree"
        note "committed $(git rev-parse --short HEAD): build $build"
        start_head="$(git rev-parse HEAD)"
    fi

    # 2. Archive and export, warm: DerivedData and obid's cargo target are kept between releases.
    #    What could go stale is the assembled app, so it's removed first and put together again
    #    from this commit's build; the result is checked below (versions, both architectures,
    #    every signature).
    local archive="$out/Oby.xcarchive" app
    say "Archiving the Oby scheme (Release)"
    rm -rf "$derived/Build/Intermediates.noindex/ArchiveIntermediates/Oby/InstallationBuildProductsLocation" \
        "$derived/Build/Intermediates.noindex/ArchiveIntermediates/Oby/BuildProductsPath/Release/Oby.app"
    local -a signing=()
    if $dry_run; then
        # CI's ad hoc flags (docs/ci.md): no certificate needed, hardened runtime stays on.
        signing=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
    fi
    local -a archive_args=(
        -project apps/Oby.xcodeproj
        -scheme Oby
        -configuration Release
        -destination 'generic/platform=macOS'
        -archivePath "$archive"
        -derivedDataPath "$derived"
        MARKETING_VERSION="$version"
        CURRENT_PROJECT_VERSION="$build"
        OBY_CARGO_TARGET_DIR="$cache/cargo"
        # Always said, so apps/config/Signing.local.xcconfig can't make a release full, or lean.
        OBY_FULL_BUILD="$($full_build && echo 1 || echo 0)"
    )
    if $dry_run; then
        archive_args+=("${signing[@]}")
    fi
    xcodebuild "${archive_args[@]}" archive > "$out/archive.log" 2>&1 || { tail -n 40 "$out/archive.log"; die "the archive failed: build/release/archive.log"; }
    if $dry_run; then
        app="$out/Oby.app"
        cp -R "$archive/Products/Applications/Oby.app" "$app"
        note "exported ad hoc: $app"
    else
        say "Exporting with Developer ID (team $team)"
        plutil -convert xml1 -o "$out/ExportOptions.plist" apps/ExportOptions-DeveloperID.plist
        plutil -replace teamID -string "$team" "$out/ExportOptions.plist"
        xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/ExportOptions.plist" \
            -exportPath "$out/export" > "$out/export.log" 2>&1 || { tail -n 40 "$out/export.log"; die "the export failed: build/release/export.log"; }
        app="$out/export/Oby.app"
        still_clean "$start_head" "during the archive"
    fi
    [[ -d "$app" ]] || die "no Oby.app after the export"
    local built
    built="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist") ($(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist"))"
    [[ "$built" == "$version ($build)" ]] || die "the app says $built, not $version ($build)"
    check_universal "$app/Contents/MacOS/$(plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist")"
    check_universal "$app/Contents/Helpers/obid"
    # What the launch build leaves out (AGENTS.md, "The launch build"): in a full build, and only there.
    local kind="the launch build" part
    if $full_build; then
        kind="a full build"
        [[ -x "$app/Contents/MacOS/cloudflared" ]] || die "a full build has no Contents/MacOS/cloudflared"
        check_universal "$app/Contents/MacOS/cloudflared"
        check_obi_vm "$app/Contents/Helpers/obi-vm" "$dry_run"
        [[ -f "$app/Contents/Resources/obid/web/index.html" ]] || die "a full build has no web app (Contents/Resources/obid/web)"
    else
        for part in Contents/MacOS/cloudflared Contents/Helpers/obi-vm Contents/Resources/obid/web; do
            [[ ! -e "$app/$part" ]] || die "the launch build carries $part: only --full-build does"
        done
    fi
    codesign --verify --deep --strict "$app" || die "Oby.app doesn't verify"
    note "Oby $built, $kind, arm64 and x86_64, feed $(plutil -extract SUFeedURL raw -o - "$app/Contents/Info.plist")"

    # The secret scan of the app before anything leaves this Mac, Apple's notary service included
    # (AGENTS.md); the commits' and the appcast's follow. If the scanner can't run, nothing is
    # published.
    say "Secret scan (gitleaks)"
    local scanner=true
    if have_gitleaks "$dry_run"; then scan_paths "$app"; else scanner=false; fi

    # 3. Notarize and staple the app, so a copy taken out of the DMG carries its own ticket, even
    #    offline. Apple takes minutes: the commits' scan and the release notes happen meanwhile.
    local notarizing=""
    if $dry_run; then
        say "Dry run: the app stays ad hoc signed, not notarized"
    else
        say "Notarizing the app (keychain profile $notary_profile)"
        ditto -c -k --keepParent "$app" "$out/Oby.zip"
        notarize "$app" "$out/Oby.zip" notarize-app.log > "$out/notarize-app.out" 2>&1 &
        notarizing=$!
        bg_pids+=("$notarizing")
    fi
    if $scanner; then scan_history "$last_tag"; fi
    local notes previous=""
    if [[ -n "$notes_file" ]]; then notes="$(notes_from_file "$notes_file")"; else notes="$(release_notes "$last_tag")"; fi
    if curl -fsSL --max-time 20 "$feed" -o "$out/appcast-previous.xml" 2>/dev/null; then
        previous="$out/appcast-previous.xml"
        note "previous appcast: $(grep -c '<item>' "$previous" || true) entries"
    else
        note "no appcast at $feed yet: starting one"
    fi
    if [[ -n "$notarizing" ]]; then
        local status=0
        wait "$notarizing" || status=$?
        bg_pids=()
        sed 's/^/    /' "$out/notarize-app.out"
        [[ "$status" == 0 ]] || die "the app's notarization failed: build/release/notarize-app.log"
        spctl --assess --type execute -v "$app"
    fi

    # 4. The DMG: Oby.app and an Applications link; create-dmg lays it out with the background.
    # One local per line: a local's value can't read a name declared on the same line.
    local dmg_name="Oby-$version.dmg"
    local dmg="$out/$dmg_name"
    local staging="$out/dmg"
    say "Building $dmg_name"
    rm -rf "$staging" && mkdir -p "$staging"
    cp -R "$app" "$staging/Oby.app"
    ln -s /Applications "$staging/Applications"
    local background="$root/apps/icon/dmg-background.png"
    if command -v create-dmg >/dev/null 2>&1; then
        local -a layout=(--volname "Oby" --window-size 600 400 --icon-size 128 --icon "Oby.app" 150 190 --app-drop-link 450 190 --no-internet-enable)
        [[ -f "$background" ]] && layout+=(--background "$background")
        rm -f "$staging/Applications"
        create-dmg "${layout[@]}" "$dmg" "$staging" >/dev/null
    else
        [[ -f "$background" ]] && note "create-dmg isn't installed (brew install create-dmg): a plain DMG, without the background"
        # `hdiutil create -srcfolder` fails "Resource busy" when a system scanner still holds its
        # scratch volume at unmount, so: a blank image, copy, a forced detach after sync, convert.
        local rw="$out/dmg-rw.dmg"
        rm -f "$rw" "$dmg"
        hdiutil create -quiet -size "$(( $(du -sm "$staging" | cut -f1) + 50 ))m" -fs HFS+ -volname "Oby" "$rw"
        attach -noverify "$rw"
        touch "$mnt/.metadata_never_index"
        ditto "$staging" "$mnt"
        sync
        detach
        hdiutil convert -quiet "$rw" -format UDZO -o "$dmg"
        rm -f "$rw"
    fi
    # The checksum doesn't prove the copy is whole: the app inside must verify, every nested signature.
    attach -readonly "$dmg"
    codesign --verify --deep --strict "$mnt/Oby.app" || die "Oby.app in $dmg_name doesn't verify"
    detach

    if $dry_run; then
        codesign --force --sign - "$dmg"
        note "signed ad hoc, not notarized (dry run)"
    else
        local identity
        identity="$(developer_id_identity "$team")"
        [[ -n "$identity" ]] || die "no Developer ID Application certificate for team $team in the keychain: docs/release.md"
        codesign --force --sign "$identity" --timestamp "$dmg"
        say "Notarizing the DMG"
        notarize "$dmg" "$dmg" notarize-dmg.log
        spctl --assess --type open --context context:primary-signature -v "$dmg"
        # The app as a user gets it: in the mounted DMG, and copied out with a quarantine flag.
        local copy="$out/gatekeeper"
        rm -rf "$copy" && mkdir -p "$copy"
        attach -readonly "$dmg"
        ditto "$mnt/Oby.app" "$copy/Oby.app"
        spctl --assess --type execute -v "$mnt/Oby.app" || die "Gatekeeper rejects Oby.app in $dmg_name"
        detach
        xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$copy/Oby.app"
        spctl --assess --type execute -v "$copy/Oby.app" || die "Gatekeeper rejects Oby.app copied out of $dmg_name"
        xcrun stapler validate "$copy/Oby.app" || die "Oby.app copied out of $dmg_name carries no ticket"
        rm -rf "$copy"
    fi
    hdiutil verify -quiet "$dmg"
    codesign --verify "$dmg"

    # 5. Sparkle's signature, of the stapled DMG.
    local bin signature="" length
    length="$(stat -f %z "$dmg")"
    if bin="$(sparkle_bin "$derived")"; then
        local signed
        if signed="$("$bin/sign_update" "$dmg" 2>/dev/null)"; then
            signature="$(printf '%s' "$signed" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
            length="$(printf '%s' "$signed" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
        fi
    fi
    if [[ -z "$signature" ]]; then
        $dry_run || die "sign_update couldn't sign the DMG: no Sparkle EdDSA key in the keychain (docs/release.md, Sparkle keys)"
        signature="dry-run-no-sparkle-key"
        note "no Sparkle key in the keychain: a placeholder signature (dry run)"
    fi
    say "Signed for Sparkle: $length bytes"

    # 6. The appcast entry, on top of the appcast already published, and its secret scan.
    local item pubdate
    pubdate="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    item="$(appcast_item "$version" "$build" "$pubdate" "$base/$dmg_name" "$length" "$signature" "$notes")"
    write_appcast "$previous" "$item" "$out/appcast.xml"
    xmllint --noout "$out/appcast.xml"
    say "Appcast entry (xmllint: well-formed)"
    printf '%s\n' "$item"
    if $scanner; then scan_paths "$out/appcast.xml"; fi

    # 7. Upload, 8. tag.
    if $dry_run; then
        say "Dry run done: nothing uploaded or tagged"
        note "$dmg"
        note "$out/appcast.xml"
        exit 0
    fi
    publish "$dmg" "$version" "$build" "$tag" "$base"
}

# 7. Upload, 8. tag: the DMG, checked at its public URL, then the appcast that points at it.
publish() {
    local dmg="$1" version="$2" build="$3" tag="$4" base="$5" dmg_name
    dmg_name="$(basename "$dmg")"
    say "Uploading to R2 ($bucket)"
    upload_r2 "$dmg" "$dmg_name" "application/octet-stream"
    # The appcast points at the DMG only once the public URL serves this very file.
    curl -fsSL --max-time 600 "$base/$dmg_name" -o "$out/published.dmg" || die "$base/$dmg_name doesn't download: the appcast isn't uploaded"
    [[ "$(stat -f %z "$out/published.dmg")" == "$(stat -f %z "$dmg")" && \
        "$(shasum -a 256 < "$out/published.dmg")" == "$(shasum -a 256 < "$dmg")" ]] \
        || die "$base/$dmg_name isn't the DMG just built (size or sha256): the appcast isn't uploaded"
    rm -f "$out/published.dmg"
    note "$base/$dmg_name serves this DMG (size and sha256)"
    upload_r2 "$out/appcast.xml" "appcast.xml" "application/xml"
    say "Tagging $tag"
    git tag -a "$tag" -m "Oby $version ($build)"
    say "Released Oby $version ($build)"
    note "push the release: git push origin HEAD $tag"
    note "$base/$dmg_name"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
