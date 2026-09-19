.PHONY: build run app clean

build:
	swift build -c release

run:
	swift run jevd

app: build
	bash scripts/build-app.sh

clean:
	swift build --clean
	rm -rf build/
