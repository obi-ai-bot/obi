#!/bin/bash
# Ships Oby as a notarized DMG that updates itself (#282): docs/release.md has the steps around it.
#
#   scripts/release.sh <version> [--dry-run] [--notes <file>]
#
# Run on a Mac with Xcode 27. In order:
#   0. runs the checks (swift test, the Mac app with MacTests): nothing is built unless they pass;
#   1. bumps the version: CFBundleShortVersionString from <version>, the build number from the git
#      commit count, committed on the current branch;
#   2. archives the Oby scheme (Release) and exports it with Developer ID
#      (apps/ExportOptions-DeveloperID.plist, teamID from apps/config/Signing.xcconfig);
#   3. notarizes the app (xcrun notarytool, keychain profile "oby-notary") and staples it;
#   4. builds Oby-<version>.dmg with an Applications link (and a background, with create-dmg), then
#      signs, notarizes and staples the DMG;
#   5. signs the DMG for Sparkle (sign_update, the EdDSA key in the keychain);
#   6. writes the appcast entry, with the merged pull requests since the last tag as release notes,
#      then scans the app, the appcast and the commits since the last tag for secrets (gitleaks):
#      a finding, or no scanner, and nothing is published;
#   7. uploads the DMG and appcast.xml to R2 (wrangler, or aws against the R2 endpoint);
#   8. tags v<version>.
#
# --dry-run does everything up to the signatures with ad hoc identities, and leaves out the
# notarization, the upload, the commit and the tag, so it runs on any Mac today. Everything lands in
# build/release/ (gitignored).
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
minimum_system="26.0"
# What apps/config/Signing.xcconfig holds for OBY_SPARKLE_PUBLIC_KEY until the key is generated.
placeholder_public_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf 'release.sh: %s\n' "$*" >&2; exit 1; }

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

# Sparkle's command-line tools from the archive's package checkout, else any DerivedData's.
sparkle_bin() {
    local candidate
    candidate="$out/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
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

# gitleaks over what's about to be published: the exported app, the appcast, and every commit
# since `since` (a tag, or empty for the whole history). Findings are redacted, so no secret is
# printed. A finding stops the release. Without gitleaks a real release stops too (AGENTS.md: if
# the scanner can't run, nothing goes out); a dry run notes it, since it publishes nothing.
secret_scan() {
    local app="$1" appcast="$2" since="$3" dry_run="$4" report="$out/gitleaks.json" status
    say "Secret scan (gitleaks)"
    if ! command -v gitleaks >/dev/null 2>&1; then
        $dry_run || die "gitleaks isn't installed (brew install gitleaks): nothing is published unscanned"
        note "gitleaks isn't installed: a real release stops here (brew install gitleaks)"
        return
    fi
    local target
    for target in "$app" "$appcast"; do
        status=0
        gitleaks dir "$target" --config "$root/.gitleaks.toml" --no-banner --redact --exit-code=99 --report-format=json --report-path="$report" > "$out/gitleaks.log" 2>&1 || status=$?
        case "$status" in
            0) ;;
            99) die "possible secret in ${target#"$out/"}: build/release/gitleaks.json says where (redacted)" ;;
            *) tail -n 20 "$out/gitleaks.log"; die "gitleaks couldn't scan ${target#"$out/"}: nothing is published unscanned" ;;
        esac
    done
    status=0
    if [[ -n "$since" ]]; then
        gitleaks git "$root" "--log-opts=$since..HEAD" --no-banner --redact --exit-code=99 --report-format=json --report-path="$report" > "$out/gitleaks.log" 2>&1 || status=$?
    else
        gitleaks git "$root" --no-banner --redact --exit-code=99 --report-format=json --report-path="$report" > "$out/gitleaks.log" 2>&1 || status=$?
    fi
    case "$status" in
        0) note "clean: the app, the appcast and the commits since ${since:-the beginning}" ;;
        99) die "possible secret in a commit since ${since:-the beginning}: build/release/gitleaks.json says where (redacted)" ;;
        *) tail -n 20 "$out/gitleaks.log"; die "gitleaks couldn't scan the commits: nothing is published unscanned" ;;
    esac
}

upload_r2() {
    local file="$1" name="$2" type="$3"
    if command -v wrangler >/dev/null 2>&1; then
        wrangler r2 object put "$bucket/$name" --file "$file" --content-type "$type" --remote
        return
    fi
    command -v aws >/dev/null 2>&1 || die "neither wrangler nor aws is installed: docs/release.md, Uploading"
    if [[ -f "$root/.env.local" ]]; then
        # OBY_R2_ACCOUNT_ID, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, never in git.
        set -a; # shellcheck disable=SC1091
        source "$root/.env.local"; set +a
    fi
    : "${OBY_R2_ACCOUNT_ID:=$(security find-generic-password -s oby-r2 -a account-id -w 2>/dev/null || true)}"
    : "${AWS_ACCESS_KEY_ID:=$(security find-generic-password -s oby-r2 -a access-key-id -w 2>/dev/null || true)}"
    : "${AWS_SECRET_ACCESS_KEY:=$(security find-generic-password -s oby-r2 -a secret-access-key -w 2>/dev/null || true)}"
    [[ -n "$OBY_R2_ACCOUNT_ID" && -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]] || die "no R2 credentials in the keychain (service oby-r2) or .env.local: docs/release.md, Uploading"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    AWS_DEFAULT_REGION=auto aws s3 cp "$file" "s3://$bucket/$name" --content-type "$type" \
        --endpoint-url "https://$OBY_R2_ACCOUNT_ID.r2.cloudflarestorage.com"
}

main() {
    local version="" dry_run=false notes_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true ;;
            --notes) shift; notes_file="${1:-}"; [[ -f "$notes_file" ]] || die "--notes needs a file" ;;
            -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
            -*) die "unknown option $1" ;;
            *) [[ -z "$version" ]] || die "one version only"; version="$1" ;;
        esac
        shift
    done
    [[ -n "$version" ]] || die "usage: scripts/release.sh <version> [--dry-run] [--notes <file>]"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the version is X.Y.Z, like 1.2.3"
    [[ "$(uname)" == "Darwin" ]] || die "runs on a Mac with Xcode"
    for tool in xcodebuild xcrun swift hdiutil codesign xmllint plutil git; do
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
    local tag="v$version" last_tag
    git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "$tag exists already"
    last_tag="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
    if ! $dry_run && [[ -n "$(git status --porcelain)" ]]; then
        die "the working tree isn't clean: commit or put aside what's changed first"
    fi

    rm -rf "$out"
    mkdir -p "$out"

    # 0. The checks Oby runs before a merge (docs/ci.md), without the iPhone app, which this release
    #    doesn't ship: nothing is built for release, let alone uploaded, unless they pass.
    say "Checks: swift test"
    swift test > "$out/swift-test.log" 2>&1 || { tail -n 40 "$out/swift-test.log"; die "swift test failed: build/release/swift-test.log"; }
    say "Checks: the Mac app and MacTests"
    xcodebuild -project apps/Oby.xcodeproj -scheme Oby -destination 'platform=macOS' -derivedDataPath "$out/DerivedData" \
        test > "$out/mac-test.log" 2>&1 || { tail -n 40 "$out/mac-test.log"; die "MacTests failed: build/release/mac-test.log"; }
    note "both passed"

    # 1. The version. For real, it's committed first, so the build number counts that commit and
    #    the tag names it; a dry run passes both to xcodebuild and changes nothing.
    local build
    if $dry_run; then
        build="$(git rev-list --count HEAD)"
        say "Dry run: Oby $version ($build), ad hoc signed, nothing notarized, uploaded or tagged"
    else
        say "Oby $version: bumping the version in apps/Oby.xcodeproj"
        build="$(( $(git rev-list --count HEAD) + 1 ))"
        sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $version;/; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $build;/" apps/Oby.xcodeproj/project.pbxproj
        git add apps/Oby.xcodeproj/project.pbxproj
        git commit -q -m "chore(release): Oby $version ($build)"
        [[ "$(git rev-list --count HEAD)" == "$build" ]] || die "the build number and the commit count disagree"
        note "committed $(git rev-parse --short HEAD): build $build"
    fi

    # 2. Archive and export.
    local archive="$out/Oby.xcarchive" app
    say "Archiving the Oby scheme (Release)"
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
        -derivedDataPath "$out/DerivedData"
        MARKETING_VERSION="$version"
        CURRENT_PROJECT_VERSION="$build"
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
    fi
    [[ -d "$app" ]] || die "no Oby.app after the export"
    local built
    built="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist") ($(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist"))"
    [[ "$built" == "$version ($build)" ]] || die "the app says $built, not $version ($build)"
    note "Oby $built, feed $(plutil -extract SUFeedURL raw -o - "$app/Contents/Info.plist")"

    # 3. Notarize and staple the app.
    if $dry_run; then
        say "Dry run: the app stays ad hoc signed, not notarized"
    else
        say "Notarizing the app (keychain profile $notary_profile)"
        ditto -c -k --keepParent "$app" "$out/Oby.zip"
        xcrun notarytool submit "$out/Oby.zip" --keychain-profile "$notary_profile" --wait
        xcrun stapler staple "$app"
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
        local rw="$out/dmg-rw.dmg" mnt
        rm -f "$rw" "$dmg"
        hdiutil create -quiet -size "$(( $(du -sm "$staging" | cut -f1) + 50 ))m" -fs HFS+ -volname "Oby" "$rw"
        mnt="$(hdiutil attach -nobrowse -noverify -noautoopen "$rw" | awk -F'\t' '/\/Volumes\//{print $NF}')"
        [[ -n "$mnt" ]] || die "couldn't attach $rw"
        touch "$mnt/.metadata_never_index"
        ditto "$staging" "$mnt"
        sync
        hdiutil detach "$mnt" -quiet || hdiutil detach "$mnt" -force -quiet
        hdiutil convert -quiet "$rw" -format UDZO -o "$dmg"
        rm -f "$rw"
        hdiutil verify -quiet "$dmg"
    fi
    if $dry_run; then
        codesign --force --sign - "$dmg"
        note "signed ad hoc, not notarized (dry run)"
    else
        local identity
        identity="$(developer_id_identity "$team")"
        [[ -n "$identity" ]] || die "no Developer ID Application certificate for team $team in the keychain: docs/release.md"
        codesign --force --sign "$identity" --timestamp "$dmg"
        say "Notarizing the DMG"
        xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
        xcrun stapler staple "$dmg"
    fi
    codesign --verify "$dmg"

    # 5. Sparkle's signature.
    local bin signature="" length
    length="$(stat -f %z "$dmg")"
    if bin="$(sparkle_bin)"; then
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

    # 6. The appcast entry, on top of the appcast already published.
    local notes previous="" item pubdate
    if [[ -n "$notes_file" ]]; then notes="$(notes_from_file "$notes_file")"; else notes="$(release_notes "$last_tag")"; fi
    if curl -fsSL --max-time 20 "$feed" -o "$out/appcast-previous.xml" 2>/dev/null; then
        previous="$out/appcast-previous.xml"
        note "previous appcast: $(grep -c '<item>' "$previous" || true) entries"
    else
        note "no appcast at $feed yet: starting one"
    fi
    pubdate="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    item="$(appcast_item "$version" "$build" "$pubdate" "$base/$dmg_name" "$length" "$signature" "$notes")"
    write_appcast "$previous" "$item" "$out/appcast.xml"
    xmllint --noout "$out/appcast.xml"
    say "Appcast entry (xmllint: well-formed)"
    printf '%s\n' "$item"

    # 6b. The secret scan of what goes out: the app in the DMG, the appcast, and the commits since
    #     the last release (AGENTS.md). If the scanner can't run, nothing is published.
    secret_scan "$app" "$out/appcast.xml" "$last_tag" "$dry_run"

    # 7. Upload, 8. tag.
    if $dry_run; then
        say "Dry run done: nothing uploaded or tagged"
        note "$dmg"
        note "$out/appcast.xml"
        exit 0
    fi
    say "Uploading to R2 ($bucket)"
    upload_r2 "$dmg" "$dmg_name" "application/octet-stream"
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
