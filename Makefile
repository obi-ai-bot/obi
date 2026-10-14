# Obi: top-level targets. The Swift apps build with Xcode (AGENTS.md); this file drives what is
# not Xcode's: the end-to-end scenario (e2e/SCENARIO.md).
#
#   make e2e        the scenario with stub agents: headless, no model credentials, Linux and macOS
#   make e2e-live   the same with the real Claude Code adapter, run by a person on a Mac
#
# OBI_SPHERE_DIR is the obi-sphere checkout (default: ../obi-sphere); OBID_BIN the obid binary
# (default: core/target/debug/obid). Both are documented in e2e/SCENARIO.md.

OBI_SPHERE_DIR ?= $(abspath ../obi-sphere)
export OBI_SPHERE_DIR

.PHONY: e2e e2e-live e2e-deps

# Installs obi-sphere's pinned dependencies (the spec's checker; the server once it exists).
# A missing checkout is reported by the harness itself, so this never stops the run.
e2e-deps:
	@if [ -f "$(OBI_SPHERE_DIR)/spec/package.json" ]; then \
	  (cd "$(OBI_SPHERE_DIR)/spec" && pnpm install --frozen-lockfile --silent); \
	else echo "e2e: no obi-sphere spec at $(OBI_SPHERE_DIR)/spec (set OBI_SPHERE_DIR)"; fi
	@if [ -f "$(OBI_SPHERE_DIR)/server/package.json" ]; then \
	  (cd "$(OBI_SPHERE_DIR)/server" && pnpm install --frozen-lockfile --silent); fi

e2e: e2e-deps
	node e2e/run.mjs

e2e-live: e2e-deps
	node e2e/run.mjs --live
