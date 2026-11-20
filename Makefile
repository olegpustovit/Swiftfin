# Swiftfin tvOS (Apple TV fork) developer commands.
#
#   make setup    install the tvOS toolchain, simulator, and local Jellyfin test server
#   make run      start the test server, then build and launch the app in the Apple TV Simulator
#   make test     run the native player UI tests against the test server
#   make device   build, sign, and install on a paired Apple TV
#
# Run `make help` for everything else.

SHELL := /bin/bash
SIM_NAME ?= Swiftfin Apple TV
export SIM_NAME

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36mmake %-14s\033[0m %s\n", $$1, $$2}'

.PHONY: setup
setup: ## Install Xcode tvOS platform, tools, simulator, and the Jellyfin test server
	@Scripts/setup.sh
	@Scripts/simulator.sh create
	@Scripts/testserver.sh setup

.PHONY: run
run: server ## Start the test server, build, and launch Swiftfin in the Apple TV Simulator
	@Scripts/simulator.sh run

.PHONY: run-app
run-app: ## Build and launch in the simulator without starting the test server
	@Scripts/simulator.sh run

.PHONY: test
test: server ## Run NativePlaybackTests (UI tests) in the simulator against the test server
	@Scripts/simulator.sh create
	set -o pipefail; xcodebuild test \
		-project Swiftfin.xcodeproj \
		-scheme "Swiftfin tvOS" \
		-destination "platform=tvOS Simulator,name=$(SIM_NAME)" \
		-derivedDataPath .build/DerivedData \
		-skipMacroValidation -skipPackagePluginValidation \
		-only-testing:"Swiftfin tvOS Screenshots/NativePlaybackTests" \
		2>&1 | tee .build/test.log | grep -E "error:|Test Case .*(passed|failed)|\*\* TEST"

.PHONY: device
device: ## Build, sign, and install on a paired Apple TV (pair it in Xcode first)
	@Scripts/install-appletv.sh

.PHONY: testflight
testflight: ## Archive and upload a tvOS build to TestFlight (Xcode account or ASC_KEY_ID/ASC_ISSUER_ID)
	@Scripts/testflight.sh

.PHONY: server
server: ## Start the Jellyfin test server (http://localhost:8096)
	@Scripts/testserver.sh start

.PHONY: server-stop
server-stop: ## Stop the Jellyfin test server
	@Scripts/testserver.sh stop

.PHONY: server-status
server-status: ## Show whether the test server is running
	@Scripts/testserver.sh status

.PHONY: server-reset
server-reset: ## Delete the test server (binaries, media, data); run make setup again after
	@Scripts/testserver.sh reset

.PHONY: open
open: ## Open the project in Xcode
	@open Swiftfin.xcodeproj

.PHONY: clean
clean: ## Remove build output (.build/)
	rm -rf .build
