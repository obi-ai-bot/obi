#!/bin/zsh
# Builds the handoff package from the working copy into dist/oby (and
# dist/oby.zip): oby.html without the playground (every dev:start..dev:end
# block) and with only the expressions in KEEP, plus three.js, the README,
# a demo page and the sample mac app.
set -euo pipefail
here=${0:A:h}
src=${here:h}
dist=${src:h}/dist
out=$dist/oby

# What ships. Listening, Thinking, Working and Loading stay because the states use them;
# Hello, Grin, Agree and Confused because the apps play them (apps/ios/app/Home.swift,
# apps/mac/app/ObyController.swift).
KEEP="Hello Listening Thinking Working Loading Agree Disagree Grin Laugh Surprised Confused Tired Yawn Distracted Hiding"

rm -rf "$out" "$dist/oby.zip"
mkdir -p "$out/vendor" "$out/mac"

python3 - "$src/oby.html" "$out/oby.html" "$KEEP" <<'EOF'
import re, sys
src, dst, keep = sys.argv[1], sys.argv[2], set(sys.argv[3].split())
s = open(src).read()

# 1. the playground
s = re.sub(r'[ \t]*<!-- dev:start -->.*?<!-- dev:end -->\n', '', s, flags=re.S)
s = re.sub(r'[ \t]*/\* dev:start.*?dev:end \*/\n', '', s, flags=re.S)
assert 'dev:' not in s, 'unmatched dev marker'

# 2. expressions not in KEEP: drop their { ... } entries from the EXPRESSIONS array
start = s.index('const EXPRESSIONS = [') + len('const EXPRESSIONS = [')
i, depth, entry, spans = start, 0, None, []
while True:
    c = s[i]
    if s.startswith('//', i): i = s.index('\n', i); continue
    if s.startswith('/*', i): i = s.index('*/', i) + 2; continue
    if c in '\'"`':
        j = i + 1
        while s[j] != c: j += 2 if s[j] == '\\' else 1
        i = j + 1; continue
    if c in '{[(':
        if depth == 0 and c == '{': entry = i
        depth += 1
    elif c in '}])':
        if depth == 0: break  # the array's closing ]
        depth -= 1
        if depth == 0 and c == '}': spans.append((entry, i + 1))
    i += 1
assert s[i] == ']', f'scanner stopped at {s[i]!r}, not the end of EXPRESSIONS'
kept = []
for a, b in reversed(spans):
    name = re.search(r"name: '([^']+)'", s[a:b]).group(1)
    if name in keep:
        kept.append(name); continue
    a = s.rindex('\n', 0, a) + 1                     # the whole line the entry starts on
    b = b + 1 if s[b] == ',' else b                  # its trailing comma
    b = s.index('\n', b) + 1 if s[b:].lstrip(' ').startswith('\n') else b
    s = s[:a] + s[b:]
missing = keep - set(kept)
assert not missing, f'KEEP names not found: {missing}'
# what actually ships must be exactly KEEP
arr = s[s.index('const EXPRESSIONS = ['):s.index('\nconst IDLE')]
shipped = set(re.findall(r"^    name: '([^']+)'", arr, flags=re.M))
assert shipped == keep, f'shipped {sorted(shipped)} != KEEP'
# 3. state pools: only name expressions that ship
def prune(m):
    names = [n for n in re.findall(r"'([^']+)'", m.group(1)) if n in keep]
    return 'pool: [' + ', '.join(f"'{n}'" for n in names) + ']'
states = s.index('const STATES = {'); end = s.index('\n};', states)
s = s[:states] + re.sub(r'pool: \[([^\]]*)\]', prune, s[states:end]) + s[end:]

open(dst, 'w').write(s)
print('expressions:', ', '.join(reversed(kept)))
EOF

cp "$src/vendor/three.module.js" "$out/vendor/"
cp "$here/README.md" "$here/demo.html" "$out/"
cp "$src/mac/Info.plist" "$out/mac/"
# the sample app's "Say hi" waves with Hello; when Hello doesn't ship, it just listens
if [[ " $KEEP " == *" Hello "* ]]; then
  cp "$src/mac/main.swift" "$out/mac/"
else
  sed -e '/oby("play(.Hello.)")/d' -e 's/"Hi Oby": wave, then listen/"Hi Oby": listen/' "$src/mac/main.swift" > "$out/mac/main.swift"
  ! grep -q "Hello" "$out/mac/main.swift" || { echo "build.sh: couldn't take Hello out of mac/main.swift" >&2; exit 1; }
fi
cp "$src/mac/build.sh" "$out/mac/"

(cd "$dist" && zip -qr oby.zip oby -x '*.DS_Store')
echo "built $out and $dist/oby.zip"
