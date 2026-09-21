.PHONY: build run app clean hid-test

build:
	swift build -c release

run:
	swift run allowlyd

app: build
	bash scripts/build-app.sh

# The HID path, with no board plugged in. See scripts/hid-test.sh — this is
# how the firmware and the bridge are checked before the hardware exists.
hid-test:
	swift build
	bash scripts/hid-test.sh

clean:
	# Was `swift build --clean`, which Swift has not accepted for several
	# releases: it exited 64 and took the whole target down with it, so
	# `make clean` never reached the line that removes the app bundle.
	swift package clean
	rm -rf build/
