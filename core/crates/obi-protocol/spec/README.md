# A copy of the Obi-to-Obi protocol v0.1's machine-readable spec

These files are copied, unchanged, from [obi-ai-bot/obi-sphere](https://github.com/obi-ai-bot/obi-sphere)'s `spec/`, which is the contract (docs/ARCHITECTURE.md). They are never edited here: a change goes to the spec first, then `sync-spec.sh` copies it again.

| Here | In obi-sphere |
|---|---|
| `schemas/v0.1/` | `spec/schemas/v0.1/`: compiled into `obi-protocol`, which checks every message, card and chain against them. |
| `conformance/fixtures/` (envelope and audit cases), `conformance/jcs-vectors.json` | `spec/conformance/`: what `cargo test -p obi-protocol` judges, so the Rust core's CI runs the conformance cases without a checkout of obi-sphere. |

<<<<<<< HEAD
Copied from obi-sphere commit `712262fbd3bafe9a50d9e060e47b3fdb929faec8` (its `dev`). With `OBI_SPHERE_DIR` set to a checkout, `cargo test -p obi-protocol` also checks that this copy still matches it.
=======
Copied from obi-sphere commit `712262fbd3bafe9a50d9e060e47b3fdb929faec8` (its `dev`). With `OBI_SPHERE_DIR` set to a checkout, `cargo test -p obi-protocol` also checks that this copy still matches it.
>>>>>>> claude/sphere-mac-screens

Not copied: the agent-card cases (`fixtures/card/`) and `keys.json`. A card case carries the test owners' public keys as `owner_key`, which generic secret scanners mistake for API keys; obi-sphere allowlists exactly those values in its own `.gitleaks.toml`, and this repository has no such list. So `tests/conformance.rs` makes the same card cases at test time, from the test keys' public seed strings, as the spec's `generate.mjs` does, and judges them with the rest. With `OBI_SPHERE_DIR` set, it also checks that the cases it makes are the spec's, case for case, and that the test keys derive as `keys.json` says. The envelope and audit cases carry no owner key: they are copied as they are.
