# Oby: top-level targets. The Swift apps build with Xcode (AGENTS.md); this file drives what is
# not Xcode's: the end-to-end scenario (e2e/SCENARIO.md).
#
#   make e2e        the scenario with stub agents: headless, no model credentials, Linux and macOS
#   make e2e-live   the same with the real Claude Code adapter, run by a person on a Mac
#
# Remote mode (writes to a deployed Sphere; see e2e/SCENARIO.md, "Against a deployed Sphere"):
#   OBI_SPHERE_URL=https://... SPHERE_OPERATOR_TOKEN=... OBI_E2E_REMOTE=1 make e2e
#
# OBI_SPHERE_DIR is the obi-sphere checkout (default: ../obi-sphere); OBID_BIN the obid binary
# (default: core/target/debug/obid, which `make e2e` builds first). Both are documented in
# e2e/SCENARIO.md. This file belongs to the lead (docs/ARCHITECTURE.md, section 6).

OBI_SPHERE_DIR ?= $(abspath ../obi-sphere)
export OBI_SPHERE_DIR

# Set OBID_BIN to run another obid binary; then nothing is built here.
OBID_DEFAULT := $(abspath core/target/debug/obid)
OBID_BIN ?= $(OBID_DEFAULT)
export OBID_BIN

.PHONY: e2e e2e-live e2e-deps e2e-obid

# Installs obi-sphere's pinned dependencies (the spec's checker; the server once it exists).
# A missing checkout is reported by the harness itself, so this never stops the run.
e2e-deps:
	@if [ -f "$(OBI_SPHERE_DIR)/spec/package.json" ]; then \
	  (cd "$(OBI_SPHERE_DIR)/spec" && pnpm install --frozen-lockfile --silent); \
	else echo "e2e: no obi-sphere spec at $(OBI_SPHERE_DIR)/spec (set OBI_SPHERE_DIR)"; fi
	@if [ -f "$(OBI_SPHERE_DIR)/server/package.json" ]; then \
	  (cd "$(OBI_SPHERE_DIR)/server" && pnpm install --frozen-lockfile --silent); fi

# Builds obid (debug) into core/target/debug/obid, the harness's default OBID_BIN. Until core/
# exists there is nothing to build, and the harness reports the binary as missing. A build that
# fails stops the run here.
e2e-obid:
	@if [ "$(OBID_BIN)" != "$(OBID_DEFAULT)" ]; then \
	  echo "e2e: using OBID_BIN=$(OBID_BIN), not building obid"; \
	elif [ -f core/Cargo.toml ]; then \
	  cargo build --manifest-path core/Cargo.toml --locked -p obid; \
	else echo "e2e: no core/Cargo.toml yet, so no obid to build"; fi

e2e: e2e-deps e2e-obid
	node e2e/run.mjs

e2e-live: e2e-deps e2e-obid
	node e2e/run.mjs --live
