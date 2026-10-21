#!/bin/sh
# Builds the guest image into $1 (default ./out): vmlinuz, initrd, root.img and image.json with
# their SHA-256s. Needs Docker (any arm64 engine; OrbStack on this Mac).
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
docker run --rm --platform linux/arm64 -v "$out:/out" debian:bookworm sh -c '
  set -e; apt-get update -qq >/dev/null; apt-get install -y -qq e2fsprogs >/dev/null
  mkdir /r && tar -xpf /out/root.tar -C /r --exclude=boot --exclude=.dockerenv
  rm /out/root.tar
  rm -rf /r/dev/* /r/proc/* /r/sys/*
  mknod -m 600 /r/dev/console c 5 1; mknod -m 666 /r/dev/null c 1 3
  mb=$(( $(du -sm /r | cut -f1) * 13 / 10 + 64 ))
  rm -f /out/root.img; mke2fs -q -t ext4 -L obi-root -d /r /out/root.img ${mb}M'
cd "$out"
printf '{"vmlinuz": "%s", "initrd": "%s", "root.img": "%s"}\n' \
  "$(shasum -a 256 vmlinuz | cut -d" " -f1)" "$(shasum -a 256 initrd | cut -d" " -f1)" "$(shasum -a 256 root.img | cut -d" " -f1)" > image.json
ls -la "$out"
