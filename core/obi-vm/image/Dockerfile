# The guest image for a teammate's job (#797): Debian with git, Claude Code and Codex, and no
# network setup at all. core/obi-vm/image/build.sh turns it into a kernel, an initrd and a
# read-only ext4 root.
FROM debian:bookworm
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      linux-image-arm64 initramfs-tools ca-certificates curl git jq socat cryptsetup-bin e2fsprogs \
      iproute2 kmod procps util-linux ripgrep python3 less xz-utils \
 && printf 'virtio_pci\nvirtio_blk\nvirtio_console\n' >> /etc/initramfs-tools/modules \
 && echo RESUME=none > /etc/initramfs-tools/conf.d/resume \
 && update-initramfs -u \
 && rm -rf /var/lib/apt/lists/*
# Claude Code's own installer; the binary is copied out of the installing user's home.
RUN curl -fsSL https://claude.ai/install.sh | bash \
 && cp -L /root/.local/bin/claude /usr/local/bin/claude && rm -rf /root/.local /root/.claude*
ARG CODEX_VERSION=latest
RUN curl -fsSL "https://github.com/openai/codex/releases/${CODEX_VERSION}/download/codex-aarch64-unknown-linux-musl.tar.gz" \
      | tar -xz -C /usr/local/bin && mv /usr/local/bin/codex-aarch64-unknown-linux-musl /usr/local/bin/codex
# The job runs as `obi`, whose home is on the job's encrypted disk.
RUN useradd --uid 1000 --home-dir /work/home --no-create-home --shell /bin/sh obi \
 && mkdir /work
COPY obi-guest /sbin/obi-guest
COPY obi-job /usr/local/bin/obi-job
RUN chmod 755 /sbin/obi-guest /usr/local/bin/obi-job
