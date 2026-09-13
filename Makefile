APP_DIR := app
SERVER_DIR := server
SYNC_ENGINE_DIR := $(APP_DIR)/packages/sync_engine

.PHONY: \
	help \
	client-deps client-format client-format-check client-analyze client-test \
	server-format server-format-check server-analyze server-test \
	format format-check analyze test verify

help: ## Show available development commands.
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "%-24s %s\n", $$1, $$2}'

client-deps: ## Resolve Flutter app and pure-Dart package dependencies.
	cd $(APP_DIR) && flutter pub get
	cd $(SYNC_ENGINE_DIR) && dart pub get

client-format: ## Format Flutter app and sync-engine Dart source.
	cd $(APP_DIR) && dart format lib test
	cd $(SYNC_ENGINE_DIR) && dart format lib test

client-format-check: ## Check Flutter app and sync-engine Dart formatting without rewriting files.
	cd $(APP_DIR) && dart format --output=none --set-exit-if-changed lib test
	cd $(SYNC_ENGINE_DIR) && dart format --output=none --set-exit-if-changed lib test

client-analyze: client-deps ## Run static analysis for the Flutter app and sync engine.
	cd $(APP_DIR) && flutter analyze --fatal-infos
	cd $(SYNC_ENGINE_DIR) && dart analyze --fatal-infos

client-test: client-deps ## Run Flutter app and pure-Dart sync-engine tests.
	cd $(APP_DIR) && flutter test
	cd $(SYNC_ENGINE_DIR) && dart test

server-format: ## Format all Go source files.
	cd $(SERVER_DIR) && gofmt -w $$(find . -type f -name '*.go')

server-format-check: ## Check Go formatting without rewriting files.
	@cd $(SERVER_DIR) && unformatted="$$(gofmt -l $$(find . -type f -name '*.go'))"; \
	if [ -n "$$unformatted" ]; then \
		printf 'Go files that require formatting:\n%s\n' "$$unformatted"; \
		exit 1; \
	fi

server-analyze: ## Run Go static analysis.
	cd $(SERVER_DIR) && go vet ./...

server-test: ## Run all Go tests.
	cd $(SERVER_DIR) && go test ./...

format: client-format server-format ## Format client and server source.

format-check: client-format-check server-format-check ## Check client and server formatting.

analyze: client-analyze server-analyze ## Run client and server static analysis.

test: client-test server-test ## Run client and server tests.

verify: client-deps format-check analyze test ## Run all formatting, analysis, and test checks.
