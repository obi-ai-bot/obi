#!/bin/sh
# Builds the guest image into $1 (default ./out): vmlinuz, initrd, root.img and image.json with
# their SHA-256s, which obi-vm checks before every boot. Needs Docker (any arm64 engine; OrbStack on this Mac).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/out}
mkdir -p "$out"
docker build --platform linux/arm64 -t obi-guest-image "$here"
id=$(docker create --platform linux/arm64 obi-guest-image)
trap 'docker rm -f "$id" >/dev/null' EXIT
docker cp -L "$id:/boot/vmlinuz-$(docker run --rm --platform linux/arm64 obi-guest-image sh -c 'ls /lib/modules')" "$out/vmlinuz"
docker cp -L "$id:/boot/initrd.img-$(docker run --rm --platform linux/arm64 obi-guest-image sh -c 'ls /lib/modules')" "$out/initrd"
docker export "$id" > "$out/root.tar"
# An ext4 root made from the files, in a container that has mke2fs; read-only in every VM.
docker run --rm --platform linux/arm64 -v "$out:/out" debian:bookworm@sha256:854dd8ab51d62866dbd8f5431d15ce77b12983a2a4a1e1fe43a2395dc7ef9f61 sh -c '
  set -e
  rm -f /etc/apt/sources.list.d/debian.sources
  echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261020T000000Z bookworm main" > /etc/apt/sources.list
  apt-get update -qq >/dev/null; apt-get install -y -qq e2fsprogs >/dev/null
  mkdir /r && tar -xpf /out/root.tar -C /r --exclude=boot --exclude=.dockerenv
  rm /out/root.tar
  rm -rf /r/dev/* /r/proc/* /r/sys/*
  mknod -m 600 /r/dev/console c 5 1; mknod -m 666 /r/dev/null c 1 3
  mb=$(( $(du -sm /r | cut -f1) * 13 / 10 + 64 ))
  rm -f /out/root.img; mke2fs -q -t ext4 -L obi-root -d /r /out/root.img ${mb}M'
cd "$out"
# Their SHA-256s and sizes: copied to core/obi-vm/image.json, it pins the image obi-vm is built for
# and the one obid fetches (scripts/publish-vm-image.sh).
sum() { shasum -a 256 "$1" | cut -d" " -f1; }
size() { stat -f %z "$1"; }
printf '{\n  "vmlinuz": "%s",\n  "initrd": "%s",\n  "root.img": "%s",\n  "bytes": {"vmlinuz": %s, "initrd": %s, "root.img": %s}\n}\n' \
  "$(sum vmlinuz)" "$(sum initrd)" "$(sum root.img)" "$(size vmlinuz)" "$(size initrd)" "$(size root.img)" > image.json
ls -la "$out"
