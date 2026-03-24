.PHONY: dev build install clean deps

deps:
	cd src-ui && npm install

dev: deps
	cargo tauri dev

build: deps
	cargo tauri build

install: build
	@echo "Install the .dmg from target/release/bundle/dmg/"

clean:
	cargo clean
	rm -rf src-ui/dist src-ui/node_modules
