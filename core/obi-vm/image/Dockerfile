# The guest image for a teammate's job (#797): Debian with git and Claude Code, and no network setup
# at all. core/obi-vm/image/build.sh turns it into a kernel, an initrd and a read-only ext4 root.
# Every source is pinned: the base by digest, Debian's packages by snapshot date, each tool by
# version and SHA-256. It's kept small (it's fetched by every Mac that's shared): no docs, man pages
# or translations, only the kernel modules the guest loads, and no Codex until Codex guest jobs work.
FROM debian:bookworm@sha256:854dd8ab51d62866dbd8f5431d15ce77b12983a2a4a1e1fe43a2395dc7ef9f61
# Debian's packages as they were on 2026-10-20, from its snapshot archive: the same every build.
RUN rm -f /etc/apt/sources.list.d/debian.sources \
 && echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20261020T000000Z bookworm main" > /etc/apt/sources.list \
 && echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20261020T000000Z bookworm-security main" >> /etc/apt/sources.list
# No docs, man pages, info or translations, now or in any package installed later (each package's
# copyright stays). The C.UTF-8 locale is in /usr/lib/locale, which stays.
RUN printf '%s\n' \
      'path-exclude=/usr/share/doc/*' 'path-include=/usr/share/doc/*/copyright' \
      'path-exclude=/usr/share/man/*' 'path-exclude=/usr/share/info/*' \
      'path-exclude=/usr/share/locale/*' 'path-exclude=/usr/share/lintian/*' \
      > /etc/dpkg/dpkg.cfg.d/01-obi-slim \
 && find /usr/share/doc -mindepth 1 -not -name copyright -not -type d -delete \
 && rm -rf /usr/share/man /usr/share/info /usr/share/locale /usr/share/lintian
# The kernel, and an initrd with only what boot needs: the virtio devices and ext4 for the root.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      linux-image-arm64 initramfs-tools ca-certificates curl git jq socat cryptsetup-bin e2fsprogs \
      iproute2 kmod procps util-linux ripgrep python3 less xz-utils \
 && printf 'virtio_pci\nvirtio_blk\nvirtio_console\next4\n' >> /etc/initramfs-tools/modules \
 && sed -i 's/^MODULES=.*/MODULES=list/' /etc/initramfs-tools/initramfs.conf \
 && echo RESUME=none > /etc/initramfs-tools/conf.d/resume \
 && update-initramfs -u \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/cache/debconf/*-old /var/log/*
# Only the kernel modules the guest loads (as /proc/modules showed at the end of a real job), with
# what they depend on; the rest of /usr/lib/modules goes. To add one, name it in keep-modules.
COPY keep-modules /etc/obi/keep-modules
# (modprobe names them under /lib/modules, which is /usr/lib/modules: the same path for both sides.)
# The build fails if one isn't there afterwards.
RUN kver=$(ls /lib/modules) && mods=$(grep -v '^#' /etc/obi/keep-modules) \
 && modprobe -a -S "$kver" --show-depends $mods | awk '$1 == "insmod" {print $2}' | sort -u > /tmp/keep \
 && find "/lib/modules/$kver/kernel/" -type f | sort | comm -23 - /tmp/keep | xargs rm -f \
 && find "/lib/modules/$kver/kernel/" -type d -empty -delete \
 && depmod "$kver" && rm /tmp/keep \
 && for m in $mods; do modinfo -k "$kver" -n "$m" > /dev/null || exit 1; done
# Claude Code's native binary, from the same place its installer takes it, checked against the
# SHA-256 its release manifest names.
ARG CLAUDE_VERSION=2.1.306
ARG CLAUDE_SHA256=77d257d5e8b8730ec61d5a4992a8eb65550aaf9589f464988aa1a9684338d801
RUN curl -fsSL -o /usr/local/bin/claude "https://downloads.claude.ai/claude-code-releases/${CLAUDE_VERSION}/linux-arm64/claude" \
 && echo "${CLAUDE_SHA256}  /usr/local/bin/claude" | sha256sum -c - && chmod 755 /usr/local/bin/claude
# Codex isn't here until Codex guest jobs work. obid refuses them: `GUEST_ONLY_CLAUDE`, checked for
# the owner's jobs placed on a teammate's Mac (Jobs::create, place and change in
# core/crates/obid/src/jobs.rs) and for a guest's job arriving here (core/crates/obid/src/sphere/
# guest.rs). To add it back: its release binary, pinned like Claude Code's (+246 MB), `"codex"` in the
# runner status's agents (core/crates/obid/src/sphere/hosting.rs), and those guards taken out:
#   ARG CODEX_VERSION=rust-v0.163.0
#   ARG CODEX_SHA256=a7261e65f4a96d8f4ca65a069c6cf2dc2c33defc341e48078acefda9461fffe4
#   RUN curl -fsSL -o /tmp/codex.tar.gz "https://github.com/openai/codex/releases/download/${CODEX_VERSION}/codex-aarch64-unknown-linux-musl.tar.gz" \
#    && echo "${CODEX_SHA256}  /tmp/codex.tar.gz" | sha256sum -c - \
#    && tar -xzf /tmp/codex.tar.gz -C /usr/local/bin && rm /tmp/codex.tar.gz \
#    && mv /usr/local/bin/codex-aarch64-unknown-linux-musl /usr/local/bin/codex
# The job runs as `obi`, whose home is on the job's encrypted disk.
RUN useradd --uid 1000 --home-dir /work/home --no-create-home --shell /bin/sh obi \
 && mkdir /work
COPY obi-guest /sbin/obi-guest
COPY obi-job /usr/local/bin/obi-job
RUN chmod 755 /sbin/obi-guest /usr/local/bin/obi-job
