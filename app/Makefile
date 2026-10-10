# Shortcuts for working on Kept. Each target is a thin wrapper over a script in
# this folder; see CONTRIBUTING.md at the top of the repository.
#
#   make setup     signing certificate (unless you have a Developer ID) and the bundled Python
#   make build     build and sign .build/Kept.app, install nothing
#   make install   build, install (to KEPT_INSTALL_TO, else /Applications/Kept.app), open it
#   make debug     a debug build a debugger can attach to, installed the same way
#   make test      swift test
#   make run       swift run: the panel and setup screens, without a bundle

.PHONY: help setup build install debug test run

# First, so a bare `make` lists the targets rather than running one.
help:
	@sed -n 's/^#   //p' Makefile

setup:
	@security find-identity -v -p codesigning | grep -q "Developer ID Application" || ./make-cert.sh
	./bundle-python.sh

build:
	./build.sh --no-install

install:
	./build.sh

debug:
	./build.sh --debug

test:
	swift test

run:
	swift run
