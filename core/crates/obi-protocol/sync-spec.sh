#!/bin/sh
# Copies the Obi-to-Obi protocol's schemas and conformance cases from an obi-sphere checkout into
# spec/ (spec/README.md says why). Usage: OBI_SPHERE_DIR=/path/to/obi-sphere ./sync-spec.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
src=${OBI_SPHERE_DIR:?set OBI_SPHERE_DIR to an obi-sphere checkout}/spec
[ -d "$src/schemas/v0.1" ] || { echo "no spec/schemas/v0.1 in $OBI_SPHERE_DIR" >&2; exit 1; }
rm -rf "$here/spec/schemas" "$here/spec/conformance"
mkdir -p "$here/spec/conformance"
cp -R "$src/schemas" "$here/spec/schemas"
cp -R "$src/conformance/fixtures" "$here/spec/conformance/fixtures"
# The agent-card cases are made by the tests (spec/README.md): not copied.
rm -rf "$here/spec/conformance/fixtures/card"
cp "$src/conformance/jcs-vectors.json" "$here/spec/conformance/"
# The job channel's known answers (protocol.md section 13), once the spec has them.
[ ! -f "$src/conformance/channel-vectors.json" ] || cp "$src/conformance/channel-vectors.json" "$here/spec/conformance/"
commit=$(git -C "$OBI_SPHERE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
sed -i.bak "s/^Copied from obi-sphere commit \`[0-9a-f]*\`/Copied from obi-sphere commit \`$commit\`/" "$here/spec/README.md"
rm -f "$here/spec/README.md.bak"
echo "copied spec/ from $OBI_SPHERE_DIR at $commit"
