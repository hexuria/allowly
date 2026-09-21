.PHONY: build run app clean

build:
	swift build -c release

run:
	swift run jevd

app: build
	bash scripts/build-app.sh

clean:
	# Was `swift build --clean`, which Swift has not accepted for several
	# releases: it exited 64 and took the whole target down with it, so
	# `make clean` never reached the line that removes the app bundle.
	swift package clean
	rm -rf build/
