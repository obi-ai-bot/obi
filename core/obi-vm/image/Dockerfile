# The guest image for a teammate's job (#797): Debian with git, Claude Code and Codex, and no
# network setup at all. core/obi-vm/image/build.sh turns it into a kernel, an initrd and a
# read-only ext4 root. Every source is pinned: the base by digest, each tool by version and SHA-256.
FROM debian:bookworm@sha256:854dd8ab51d62866dbd8f5431d15ce77b12983a2a4a1e1fe43a2395dc7ef9f61
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      linux-image-arm64 initramfs-tools ca-certificates curl git jq socat cryptsetup-bin e2fsprogs \
      iproute2 kmod procps util-linux ripgrep python3 less xz-utils \
 && printf 'virtio_pci\nvirtio_blk\nvirtio_console\n' >> /etc/initramfs-tools/modules \
 && echo RESUME=none > /etc/initramfs-tools/conf.d/resume \
 && update-initramfs -u \
 && rm -rf /var/lib/apt/lists/*
# Claude Code's native binary, from the same place its installer takes it, checked against the
# SHA-256 its release manifest names.
ARG CLAUDE_VERSION=2.1.306
ARG CLAUDE_SHA256=77d257d5e8b8730ec61d5a4992a8eb65550aaf9589f464988aa1a9684338d801
RUN curl -fsSL -o /usr/local/bin/claude "https://downloads.claude.ai/claude-code-releases/${CLAUDE_VERSION}/linux-arm64/claude" \
 && echo "${CLAUDE_SHA256}  /usr/local/bin/claude" | sha256sum -c - && chmod 755 /usr/local/bin/claude
ARG CODEX_VERSION=rust-v0.163.0
ARG CODEX_SHA256=a7261e65f4a96d8f4ca65a069c6cf2dc2c33defc341e48078acefda9461fffe4
RUN curl -fsSL -o /tmp/codex.tar.gz "https://github.com/openai/codex/releases/download/${CODEX_VERSION}/codex-aarch64-unknown-linux-musl.tar.gz" \
 && echo "${CODEX_SHA256}  /tmp/codex.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/codex.tar.gz -C /usr/local/bin && rm /tmp/codex.tar.gz \
 && mv /usr/local/bin/codex-aarch64-unknown-linux-musl /usr/local/bin/codex
# The job runs as `obi`, whose home is on the job's encrypted disk.
RUN useradd --uid 1000 --home-dir /work/home --no-create-home --shell /bin/sh obi \
 && mkdir /work
COPY obi-guest /sbin/obi-guest
COPY obi-job /usr/local/bin/obi-job
RUN chmod 755 /sbin/obi-guest /usr/local/bin/obi-job
