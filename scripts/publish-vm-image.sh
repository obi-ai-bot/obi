#!/usr/bin/env bash
# Publishes the guest image obi-vm boots, where obid fetches it when an owner turns sharing on
# (#797; docs/release.md, "The guest image"): <dir>'s vmlinuz, initrd and root.img and their
# zstd-compressed copies are checked against core/obi-vm/image.json, then the .zst copies (what obid
# fetches) go to the downloads bucket under vm/<root.img's SHA-256>/, and their public URLs are read
# back. A person runs it, once per new image, before the release that pins it.
#
#   core/obi-vm/image/build.sh <dir>        # builds the image and its image.json
#   cp <dir>/image.json core/obi-vm/image.json && git commit …
#   scripts/publish-vm-image.sh <dir>
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/release.sh
source "$root/scripts/release.sh"
dir="${1:?usage: scripts/publish-vm-image.sh <dir with vmlinuz, initrd, root.img>}"
pin="$root/core/obi-vm/image.json"
root_sha="$(jq -r '.["root.img"]' "$pin")"
for file in vmlinuz initrd root.img vmlinuz.zst initrd.zst root.img.zst; do
    [[ "$(shasum -a 256 "$dir/$file" | cut -d' ' -f1)" == "$(jq -r ".[\"$file\"]" "$pin")" ]] \
        || die "$dir/$file isn't the image core/obi-vm/image.json pins"
done
# upload_r2 tries `wrangler r2 object put` first, which takes about 315 MB at most: each file must
# fit, or go up with `aws s3 cp` (multipart) by hand.
for file in vmlinuz.zst initrd.zst root.img.zst; do
    (( $(stat -f %z "$dir/$file") < 300000000 )) || die "$file is over 300 MB: upload it with aws s3 cp (docs/release.md)"
done
for file in vmlinuz.zst initrd.zst root.img.zst; do
    say "Uploading $file (vm/$root_sha/$file)"
    upload_r2 "$dir/$file" "vm/$root_sha/$file" application/zstd
done
for file in vmlinuz.zst initrd.zst root.img.zst; do
    say "Reading $file back from $vm_images"
    [[ "$(curl -fsSL "$vm_images/$root_sha/$file" | shasum -a 256 | cut -d' ' -f1)" == "$(jq -r ".[\"$file\"]" "$pin")" ]] \
        || die "$vm_images/$root_sha/$file doesn't serve the pinned bytes"
done
say "The guest image ${root_sha:0:12}… is published"
