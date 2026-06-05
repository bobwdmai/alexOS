SHELL := /bin/bash

ALEXOS_ARCHITECTURE ?= amd64
ISO := dist/alexOS-$(ALEXOS_ARCHITECTURE).iso

.PHONY: deps iso iso-clean run-qemu usb-list flash-usb release update-source clean

deps:
	./scripts/install-deps.sh

iso:
	ALEXOS_ARCHITECTURE="$(ALEXOS_ARCHITECTURE)" ./scripts/build-iso.sh

iso-clean: clean
	rm -f "$(ISO)" "$(ISO).sha256"
	ALEXOS_ARCHITECTURE="$(ALEXOS_ARCHITECTURE)" ./scripts/build-iso.sh

run-qemu:
	ALEXOS_ARCHITECTURE="$(ALEXOS_ARCHITECTURE)" ISO="$(ISO)" ./scripts/run-qemu.sh

usb-list:
	lsblk -o NAME,SIZE,MODEL,TRAN,TYPE,MOUNTPOINTS

flash-usb:
	ALEXOS_ARCHITECTURE="$(ALEXOS_ARCHITECTURE)" ISO="$(ISO)" ./scripts/flash-usb.sh

release:
	@if [[ -z "$(VERSION)" ]]; then echo "Usage: VERSION=v0.1.0 make release"; exit 2; fi
	./scripts/release-github.sh "$(VERSION)"

update-source:
	git pull --ff-only

clean:
	rm -rf build
