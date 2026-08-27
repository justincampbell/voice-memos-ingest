# voice-memos-ingest — developer entry points.
#
# Thin, documented wrappers around the commands in the README, so `make help`
# is the single place to look for "how do I build / test / lint / install this".
# Nothing here is load-bearing: plain `swift build` and the scripts under
# packaging/ and launchd/ still work exactly as before.

# `make` with no arguments prints help. It must never start a build — and
# absolutely never an install — by accident.
.DEFAULT_GOAL := help

# Give recipes the same discipline the shell scripts give themselves
# (`set -euo pipefail`): abort on the first failure, including mid-pipeline,
# and treat unset variables as errors.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

# Shell scripts are discovered, not hardcoded, so a script added tomorrow is
# linted the moment it is `git add`ed instead of quietly escaping lint forever.
# `git ls-files` lists only *tracked* files, which is what keeps us out of the
# gitignored `.build/` tree (full of vendored dependency scripts we do not own);
# the explicit pathspec exclusion is belt-and-braces in case anything under
# .build/ ever gets committed.
SHELL_SCRIPTS := $(shell git ls-files '*.sh' ':!:.build/**' 2>/dev/null)

# `require-variable-braces` (SC2250) is off by default but is the specific
# reason shellcheck is here at all. This project has twice been bitten by an
# unbraced expansion immediately followed by a multibyte character —
# `echo "Assembling $$APP…"` — where bash reads `APP…` as the variable name and
# dies with "unbound variable" under `set -u`. Nothing in shellcheck's default
# set flags that; SC2250 does, by insisting on `$${APP}` everywhere.
SHELLCHECK_FLAGS := --enable=require-variable-braces

.PHONY: help build test lint check package install uninstall clean

help: ## Show this help
	@echo "voice-memos-ingest — available targets:"
	@echo
	@awk 'BEGIN { FS = ":.*## " } \
	     /^[a-zA-Z0-9_-]+:.*## / { printf "  %-10s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo

build: ## Build VMIngestCore, the menu-bar app, and the CLI (debug)
	swift build

test: ## Run the unit tests
	swift test

lint: ## Run shellcheck over every tracked shell script
	@# A lint target that silently passes when the linter is missing is worse
	@# than no lint target at all, so make the absence loud and actionable.
	@command -v shellcheck >/dev/null 2>&1 || { \
	    echo "error: shellcheck not found on PATH." >&2; \
	    echo "       Install it with:  brew install shellcheck" >&2; \
	    exit 1; \
	}
	@# Likewise, an empty file list would "pass" while checking nothing —
	@# which is what a non-git checkout or a broken pathspec looks like.
	@test -n "$(SHELL_SCRIPTS)" || { \
	    echo "error: no tracked shell scripts found (is this a git checkout?)." >&2; \
	    exit 1; \
	}
	shellcheck $(SHELLCHECK_FLAGS) $(SHELL_SCRIPTS)

check: build test lint ## Build, test, and lint — the full pre-commit sweep

package: ## Build release + code-sign .build/VoiceMemosIngest.app
	packaging/package.sh

install: ## Package, install to ~/Applications, load the LaunchAgent
	launchd/install.sh

uninstall: ## Unload and remove the LaunchAgent (leaves the app and data)
	launchd/uninstall.sh

clean: ## Remove build artifacts
	swift package clean
	rm -rf .build
