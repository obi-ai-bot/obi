#!/usr/bin/env bash
# Run as the runner's owner on tetrix-lab. No sudo, GPU, or agent sandbox.
set -euo pipefail
umask 077
: "${OBY_HOME:?Set OBY_HOME to the runner data directory (for example /srv/nvme/oby)}"
for tool in git cmake c++ curl flock; do
    command -v "$tool" >/dev/null || { echo "Missing $tool (install git, cmake, build-essential, curl and util-linux)." >&2; exit 1; }
done
whisper_root="$OBY_HOME/whisper"
mkdir -p "$whisper_root"
exec 9>"$whisper_root/setup.lock"
flock 9
whisper_source="$whisper_root/source"
whisper_version=v1.8.2
if [[ ! -d "$whisper_source/.git" ]]; then
    # A failed clone is kept away from the destination, so the next run can retry.
    rm -rf "$whisper_root/source.partial"
    git clone --depth 1 --branch "$whisper_version" https://github.com/ggml-org/whisper.cpp.git "$whisper_root/source.partial"
    mv "$whisper_root/source.partial" "$whisper_source"
fi
if [[ "$(git -C "$whisper_source" describe --tags --exact-match HEAD)" != "$whisper_version" ]]; then
    echo "Expected whisper.cpp $whisper_version in $whisper_source; refusing to change an existing checkout." >&2
    exit 1
fi
cmake -S "$whisper_source" -B "$whisper_root/build" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=ON \
    -DGGML_CUDA=OFF -DGGML_METAL=OFF -DGGML_VULKAN=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=ON
cmake --build "$whisper_root/build" --config Release --target whisper-cli whisper-server --parallel "${OBY_WHISPER_THREADS:-16}"
mkdir -p "$whisper_root/bin" "$whisper_root/models"
install -m 700 "$whisper_root/build/bin/whisper-cli" "$whisper_root/bin/whisper-cli"
install -m 700 "$whisper_root/build/bin/whisper-server" "$whisper_root/bin/whisper-server"
for model in base-q5_1 large-v3-turbo-q5_0 small-q5_1; do
    model_path="$whisper_root/models/ggml-$model.bin"
    if [[ ! -s "$model_path" ]]; then
        # Atomic rename: interruptions/HTTP errors never become an installed model.
        curl --fail --location --retry 3 --output "$model_path.partial" \
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$model.bin"
        test -s "$model_path.partial"
        mv "$model_path.partial" "$model_path"
    fi
done
echo "Whisper CPU setup ready in $whisper_root (base-q5_1, large-v3-turbo-q5_0 and small-q5_1)."
