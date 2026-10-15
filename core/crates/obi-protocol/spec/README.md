# A copy of the Obi-to-Obi protocol v0.1's machine-readable spec

These files are copied, unchanged, from [obi-ai-bot/obi-sphere](https://github.com/obi-ai-bot/obi-sphere)'s `spec/`, which is the contract (docs/ARCHITECTURE.md). They are never edited here: a change goes to the spec first, then `sync-spec.sh` copies it again.

| Here | In obi-sphere |
|---|---|
| `schemas/v0.1/` | `spec/schemas/v0.1/`: compiled into `obi-protocol`, which checks every message, card and chain against them. |
| `conformance/fixtures/`, `conformance/jcs-vectors.json`, `conformance/keys.json` | `spec/conformance/`: what `cargo test -p obi-protocol` judges, so the Rust core's CI runs the conformance cases without a checkout of obi-sphere. |

Copied from obi-sphere commit `36e84f507a2d8e89e129eb8432018115d7127e6e` (its `dev`). With `OBI_SPHERE_DIR` set to a checkout, `cargo test -p obi-protocol` also checks that this copy still matches it.

The keys in `conformance/keys.json` and the fixtures are the spec's public test keys: anyone can derive them from their seed strings, and they are never used for anything else.
