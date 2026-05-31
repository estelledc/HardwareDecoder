.PHONY: build test install clean run-probe run-decode

build:
	swift build -c release

test:
	swift test

install: build
	cp .build/release/hardware-decoder /usr/local/bin/
	@echo "installed to /usr/local/bin/hardware-decoder"

clean:
	swift package clean
	rm -rf .build

# Smoke targets — useful while iterating.
run-probe:
	swift run hardware-decoder probe --input HardwareDecoder/1.h264

run-decode:
	swift run hardware-decoder decode \
	    --input HardwareDecoder/1.h264 \
	    --output-dir /tmp/hwdec-out \
	    --format jpg --max-height 480 --quality 70 \
	    --fps 1 --ts-end 5
