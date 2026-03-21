.PHONY: dev build install clean

dev:
	cargo tauri dev

build:
	cargo tauri build

install: build
	@echo "Install the .dmg from target/release/bundle/dmg/"

clean:
	cargo clean
