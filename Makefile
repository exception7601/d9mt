.DEFAULT_GOAL := help
SHELL := /bin/bash

VERSION ?=
DRAFT ?= 0
REPO ?= exception7601/d9mt
BOTTLE ?=
BOTTLE_DIR ?=
GAME_EXE ?=
CX_APP ?= /Applications/CrossOver.app
ARCHIVE ?= $(firstword $(shell ls -t build/releases/d9mt-*.tar.gz 2>/dev/null))

.PHONY: help all install-deps update download build package release install install-dry-run test

help:
	@echo 'make install-deps                   Install build tools with Homebrew'
	@echo 'make update                         Download the latest DXMT winemetal for builds'
	@echo 'make download                       Download the latest precompiled D9MT release'
	@echo 'make build                          Compile D9MT using local winemetal'
	@echo 'make package                        Build and package the current Git version'
	@echo 'make release                        Build, package and publish the current tag'
	@echo 'make release DRAFT=1                Publish as a draft'
	@echo 'make all                            Install tools, update winemetal and package'
	@echo 'make install BOTTLE="..." GAME_EXE="..."          Install the newest local package'
	@echo 'make install-dry-run BOTTLE="..." GAME_EXE="..."  Simulate installation'
	@echo 'make test                           Run shell checks and simulated tests'
	@echo 'Optional overrides: VERSION, REPO, ARCHIVE, CX_APP, BOTTLE_DIR.'
	@echo 'Install modifies shared CrossOver files with backups. Close all bottles first.'

# Keep setup steps sequential even with make -j. Publication is always explicit.
all:
	$(MAKE) install-deps
	$(MAKE) update
	$(MAKE) package

install-deps:
	brew install mingw-w64 glslang gh

update:
	bash scripts/update-winemetal.sh

download:
	bash scripts/download-release.sh --repo "$(REPO)" $(if $(VERSION),--version "$(VERSION)")

build:
	MACOSX_DEPLOYMENT_TARGET=15.0 bash tools/build-d9mtmetal.sh --build-only
	RELEASE=1 TRACY=0 D9MT_HUD=0 bash scripts/build-dxvkfe.sh

package:
	bash scripts/release.sh $(if $(VERSION),--version "$(VERSION)")

release:
	bash scripts/release.sh $(if $(VERSION),--version "$(VERSION)") \
	  --repo "$(REPO)" --publish $(if $(filter 1,$(DRAFT)),--draft)

install install-dry-run:
	@test -n "$(BOTTLE)" -a -n "$(GAME_EXE)" || { echo 'Provide BOTTLE and GAME_EXE.'; exit 1; }
	@set -e; archive="$(ARCHIVE)"; \
	test -f "$$archive" || { echo 'No local package. Run make package first.'; exit 1; }; \
	mkdir -p build; work=$$(mktemp -d build/install.XXXXXX); \
	trap 'rm -rf "$$work"' EXIT; \
	tar -xzf "$$archive" -C "$$work"; package=( "$$work"/d9mt-* ); \
	bash scripts/setup-crossover.sh install --package-dir "$${package[0]}" \
	  --crossover "$(CX_APP)" --bottle "$(BOTTLE)" --game-exe "$(GAME_EXE)" \
	  $(if $(BOTTLE_DIR),--bottle-dir "$(BOTTLE_DIR)") \
	  $(if $(filter install-dry-run,$@),--dry-run,--allow-bundle-modification)

test:
	bash -n scripts/update-winemetal.sh scripts/download-release.sh scripts/release.sh scripts/setup-crossover.sh \
	  tools/build-d9mtmetal.sh scripts/build-dxvkfe.sh examples/play-gta4.sh test/scripts-test.sh
	shellcheck scripts/update-winemetal.sh scripts/download-release.sh scripts/release.sh scripts/setup-crossover.sh \
	  tools/build-d9mtmetal.sh scripts/build-dxvkfe.sh examples/play-gta4.sh test/scripts-test.sh
	bash test/scripts-test.sh
