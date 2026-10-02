CC = clang
CFLAGS = -std=c11 -O2 -Wall -Wextra -Werror -D_DARWIN_C_SOURCE -I Sources/SpaceTempoCLI
CLI_SOURCES = Sources/SpaceTempoCLI/main.c Sources/SpaceTempoCLI/backend.c Sources/SpaceTempoCLI/timing.c
BUILD = .build/local

.PHONY: all app cli input-guard test check clean
all: app

$(BUILD):
	mkdir -p $(BUILD)

cli: $(BUILD)
	$(CC) $(CFLAGS) $(CLI_SOURCES) -o $(BUILD)/space-tempo-cli -framework CoreFoundation

input-guard: $(BUILD)
	$(CC) $(CFLAGS) Sources/InputGuard/main.c -o $(BUILD)/space-tempo-input-guard

test: $(BUILD)
	$(CC) $(CFLAGS) Sources/SpaceTempoCLI/timing.c Tests/timing_test.c -o $(BUILD)/timing-test
	$(BUILD)/timing-test
	$(CC) $(CFLAGS) Tests/backend_test.c Sources/SpaceTempoCLI/timing.c -o $(BUILD)/backend-test -framework CoreFoundation
	$(BUILD)/backend-test
	$(CC) $(CFLAGS) Tests/transaction_test.c Sources/SpaceTempoCLI/timing.c -o $(BUILD)/transaction-test -framework CoreFoundation
	$(BUILD)/transaction-test
	swiftc -swift-version 6 Sources/SpaceTempoApp/InstantSwitchEngine.swift Tests/InstantEngineTests.swift -o $(BUILD)/instant-engine-tests
	$(BUILD)/instant-engine-tests
	python3 Tests/input_guard_test.py

check: cli
	$(BUILD)/space-tempo-cli check
	$(BUILD)/space-tempo-cli status

app: cli input-guard
	swift build -c release
	sh scripts/bundle.sh

clean:
	rm -rf .build dist
