# SPDX-License-Identifier: GPL-2.0-only
# BPI-R4 Bitcoin Knots Appliance — top-level build
# Authority: REQUIREMENTS.md / TECH_SPEC.md

SHELL := /bin/bash
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
include $(ROOT)/build/version.env

BUILD_DIR := $(ROOT)/build
DL_DIR := $(BUILD_DIR)/dl
IB_DIR := $(BUILD_DIR)/imagebuilder
FILES_DIR := $(ROOT)/files
OUT_DIR := $(ROOT)/bin
# Release keys (keys/README.md): default builds are TEST builds (A + B + TEST
# key, signed here with TEST_KEY); RELEASE=1 ships A + B only, left unsigned
# for offline signing with key A.
CHANNEL := $(if $(filter 1,$(RELEASE)),release,test)
TEST_KEY ?= $(HOME)/.config/rnode/test-key/rnode-release-TEST.sec

PACKAGES := $(shell grep -vE '^\s*#|^\s*$$' $(BUILD_DIR)/packages.txt | tr '\n' ' ')

.DELETE_ON_ERROR:

.PHONY: help version fetch-ib verify-ib apply-ib-partsize rootfs overlay image flash-sd sign-release store-release offline-tools factory-station clean-ib \
	clean-rootfs test test-host test-wipe-loop test-device test-zone-security test-iue \
	test-iue-client uat-web-install

help:
	@echo "PRODUCT_VER=$(PRODUCT_VER)"
	@echo "Targets: version fetch-ib verify-ib rootfs overlay image flash-sd clean-ib clean-rootfs"
	@echo "Tests: test test-host test-iue test-wipe-loop test-device test-zone-security uat-web-install (see docs/TEST_SUITE_MATRIX.md / docs/UAT_WEB.md)"
	@echo "ROOTFS_PARTSIZE_MIB=$(ROOTFS_PARTSIZE_MIB) (R5b eMMC-matched production)"
	@echo "Flash SD: make flash-sd DEVICE=/dev/sdX (factory/flash-sd.sh: checks the disk, asks you to type its name, then gzip -dc … | sudo dd)"
	@echo "Upgrade: bin/targets/mediatek/filogic/bpi-r4-phase2-$(PRODUCT_VER)-squashfs-sysupgrade.itb"
	@echo "Factory: factory/capture-m2.sh factory/flash-m2.sh (P4) factory/install-emmc-from-sd.sh (DOC3a SD→eMMC)"

version:
	@echo "$(PRODUCT_VER)"
	@echo "OPENWRT_VER=$(OPENWRT_VER)"
	@echo "KNOTS_VER=$(KNOTS_VER)"
	@echo "BUILD_NUM=$(BUILD_NUM)"
	@echo "PROFILE=$(PROFILE)"
	@echo "PACKAGES=$(PACKAGES)"

fetch-ib: verify-ib $(IB_DIR)/Makefile

# C4 supply-chain: this recipe verifies fresh downloads against the pinned
# IB_SHA256. Make skips the recipe when the tarball already exists, so cached
# tarballs are covered by the verify-ib prerequisite above instead.
$(DL_DIR)/$(IB_NAME).tar.zst:
	mkdir -p $(DL_DIR)
	curl -fL --continue-at - -o $@.partial $(IB_URL)
	mv $@.partial $@
	echo "$(IB_SHA256)  $@" | sha256sum -c -

# C4: verify the Image Builder tarball whenever it exists on disk (cached or
# freshly downloaded). Runs before every fetch-ib, hence before any extraction.
verify-ib:
	@if [ -f "$(DL_DIR)/$(IB_NAME).tar.zst" ]; then \
		echo "$(IB_SHA256)  $(DL_DIR)/$(IB_NAME).tar.zst" | sha256sum -c -; \
	else \
		echo "verify-ib: $(IB_NAME).tar.zst not downloaded yet (verified after download)"; \
	fi

$(IB_DIR)/Makefile: $(DL_DIR)/$(IB_NAME).tar.zst
	rm -rf $(IB_DIR)
	mkdir -p $(IB_DIR)
	tar --zstd -xf $< -C $(IB_DIR) --strip-components=1
	@touch $@

rootfs:
	chmod +x $(ROOT)/lxc/rootfs-build.sh
	$(ROOT)/lxc/rootfs-build.sh

overlay: rootfs
	@test -d $(FILES_DIR)
	mkdir -p $(FILES_DIR)/etc/knots $(FILES_DIR)/srv/lxc/knots
	echo "$(PRODUCT_VER)" > $(FILES_DIR)/etc/knots/product_version
	echo "$(PRODUCT_VER)" > $(FILES_DIR)/etc/product_version
	echo "$(BUILD_NUM)" > $(FILES_DIR)/etc/knots/build_number
	printf '%s\n' \
		"OPENWRT_VER=$(OPENWRT_VER)" \
		"KNOTS_VER=$(KNOTS_VER)" \
		"BUILD_NUM=$(BUILD_NUM)" \
		"PRODUCT_VER=$(PRODUCT_VER)" \
		> $(FILES_DIR)/etc/knots/versions.env
	cp $(FILES_DIR)/etc/knots/versions.env $(FILES_DIR)/etc/versions.env
	$(ROOT)/build/stage-release-keys.sh $(FILES_DIR) $(CHANNEL)
	cp $(ROOT)/lxc/config.in $(FILES_DIR)/etc/knots/lxc-config.in
	cp $(ROOT)/lxc/config.in $(FILES_DIR)/srv/lxc/knots/config.in
	rm -rf $(FILES_DIR)/srv/lxc/knots/rootfs
	mkdir -p $(FILES_DIR)/srv/lxc/knots/rootfs
	tar -C $(ROOT)/lxc/out/rootfs -cf - . | tar -C $(FILES_DIR)/srv/lxc/knots/rootfs -xf -
	@echo "Overlay staged PRODUCT_VER=$(PRODUCT_VER) rootfs=$$(du -sh $(FILES_DIR)/srv/lxc/knots/rootfs | awk '{print $$1}')"

# Apply eMMC-matched production size to Image Builder (survives fetch-ib extract).
apply-ib-partsize: fetch-ib
	@test -n "$(ROOTFS_PARTSIZE_MIB)"
	@test -f $(IB_DIR)/.config
	@sed -i -E 's/^CONFIG_TARGET_ROOTFS_PARTSIZE=[0-9]+/CONFIG_TARGET_ROOTFS_PARTSIZE=$(ROOTFS_PARTSIZE_MIB)/' \
		$(IB_DIR)/.config
	@grep -E '^CONFIG_TARGET_ROOTFS_PARTSIZE=' $(IB_DIR)/.config
	@echo "Applied ROOTFS_PARTSIZE_MIB=$(ROOTFS_PARTSIZE_MIB) (R5b eMMC-matched)"

image: fetch-ib apply-ib-partsize overlay
	@if [ "$(CHANNEL)" = test ] && [ ! -f "$(TEST_KEY)" ]; then \
		echo "no TEST signing key at $(TEST_KEY) (factory/release-keygen.sh ~/.config/rnode/test-key TEST keys/test), or RELEASE=1" >&2; exit 1; fi
	mkdir -p $(OUT_DIR)
	$(MAKE) -C $(IB_DIR) image \
		PROFILE="$(PROFILE)" \
		PACKAGES="$(PACKAGES)" \
		FILES="$(FILES_DIR)"
	$(ROOT)/build/refresh-targets.sh $(IB_DIR)/bin/targets $(OUT_DIR)
	chmod +x $(ROOT)/build/publish-versioned-images.sh
	$(ROOT)/build/publish-versioned-images.sh "$(OUT_DIR)/targets/mediatek/filogic"
	@if [ "$(CHANNEL)" = test ]; then $(ROOT)/build/sign-release.sh "$(TEST_KEY)" "$(OUT_DIR)/targets/mediatek/filogic"; \
	else echo "RELEASE build: unsigned — sign offline with key A (factory/OFFLINE-KEYGEN.md)"; fi
	@echo "=== Image build complete CHANNEL=$(CHANNEL) PRODUCT_VER=$(PRODUCT_VER) ROOTFS_PARTSIZE_MIB=$(ROOTFS_PARTSIZE_MIB) ==="
	@ls -lh $(OUT_DIR)/targets/mediatek/filogic/bpi-r4-phase2-$(PRODUCT_VER)* 2>/dev/null | head -10
	@ls -lh $(OUT_DIR)/targets/mediatek/filogic/*$(PROFILE)*sdcard* 2>/dev/null | head -5
	@$(ROOT)/tests/host/test-sdcard-partsize.sh "$(OUT_DIR)/targets/mediatek/filogic" "$(ROOTFS_PARTSIZE_MIB)"

# TECH_SPEC §10.2 — operator-run SD write. Requires explicit DEVICE=/dev/sdX;
# refuses to run without it and echoes the destructive action before dd.
SDCARD_IMG := $(OUT_DIR)/targets/mediatek/filogic/bpi-r4-phase2-$(PRODUCT_VER)-sdcard.img.gz

# T4: device assertions (whole removable disk, nothing mounted, SD-sized) and
# a typed confirmation live in factory/flash-sd.sh (testable).
flash-sd:
	@$(ROOT)/factory/flash-sd.sh "$(DEVICE)" "$(SDCARD_IMG)"

# Release signing (pre-production review 2026-10-18): KEY= is the usign
# SECRET key on offline media (factory/release-keygen.sh). Signs the current
# build's sysupgrade image in place and refreshes its .sha256 line.
sign-release:
	@test -n "$(KEY)" || { echo "usage: make sign-release KEY=/path/to/rnode-release.sec" >&2; exit 1; }
	$(ROOT)/build/sign-release.sh "$(KEY)" "$(OUT_DIR)/targets/mediatek/filogic"

# Factory station bundle (production laptop): scripts, runbook, version and the
# current build's images — factory/PRODUCTION.md. STATION=user@host also copies it.
factory-station:
	$(ROOT)/factory/make-station-bundle.sh $(OUT_DIR)/factory-station
	@if [ -n "$(STATION)" ]; then rsync -a --delete $(OUT_DIR)/factory-station/rnode-factory/ $(STATION):rnode-factory/ && echo "copied to $(STATION):rnode-factory/"; fi

# Offline key / signing tools (factory/OFFLINE-KEYGEN.md), kept in the project
# folder: bin/offline-tools/rnode-keygen/ (owner: nothing is stored on USB media).
offline-tools:
	mkdir -p $(OUT_DIR)/offline-tools
	$(ROOT)/factory/make-keygen-usb.sh $(OUT_DIR)/offline-tools

# Stage rnode-sign/ for the live-session script (factory/offline/rnode-offline.sh):
#   make offline-stage MODE=keys|sign STATION=user@host
offline-stage: offline-tools
	$(ROOT)/build/stage-offline.sh "$(MODE)" "$(STATION)"

# File a release signed offline with key A/B (factory/OFFLINE-KEYGEN.md) in
# bin/targets/mediatek/filogic/Releases/<version>/ — kept across builds.
store-release:
	@test -n "$(SIGNED)" || { echo "usage: make store-release SIGNED=/path/to/signed-sysupgrade.itb" >&2; exit 1; }
	$(ROOT)/build/store-release.sh "$(SIGNED)"

clean-ib:
	rm -rf $(IB_DIR)

# NOTE: files/srv/lxc/knots-rootfs-arm64.tar.zst is not listed — the build never
# stages it (overlay stages the extracted knots/rootfs dir; the archive stays in
# lxc/out/). It is only an optional manual drop-in for on-device lxc-ensure.sh.
clean-rootfs:
	rm -rf $(ROOT)/lxc/out $(FILES_DIR)/srv/lxc/knots/rootfs

test-host:
	chmod +x $(ROOT)/tests/host/*.sh $(ROOT)/factory/*.sh \
		$(ROOT)/files/usr/libexec/knots/led-status.sh \
		$(ROOT)/files/usr/libexec/knots/factory-reset.sh \
		$(ROOT)/files/usr/libexec/knots/identity-regen.sh \
		$(ROOT)/files/usr/sbin/knots-storage
	$(ROOT)/tests/host/test-wipe-guards.sh
	$(ROOT)/tests/host/test-identity-regen.sh
	$(ROOT)/tests/host/test-factory-scripts.sh
	$(ROOT)/tests/host/test-install-emmc-sim.sh
	$(ROOT)/tests/host/test-factory-reset-guards.sh
	$(ROOT)/tests/host/test-settings-factory-reset-ui.sh
	$(ROOT)/tests/host/test-settings-node-start.sh
	$(ROOT)/tests/host/test-settings-upgrade-ui.sh
	$(ROOT)/tests/host/test-wait-handoff-ux.sh
	$(ROOT)/tests/host/test-progress-wait-probes.sh
	$(ROOT)/tests/host/test-upgrade-f115-regression.sh
	$(ROOT)/tests/host/test-upgrade-keep-password.sh
	$(ROOT)/tests/host/test-image-versioned-names.sh
	$(ROOT)/tests/host/test-led-derive.sh
	$(ROOT)/tests/host/test-ui-nav.sh
	$(ROOT)/tests/host/test-node-impl-persist.sh
	$(ROOT)/tests/host/test-wallet-cgi-exec.sh
	$(ROOT)/tests/host/test-node-bin-install.sh
	$(ROOT)/tests/host/test-node-core-seed-ui.sh
	$(ROOT)/tests/host/test-node-busy-status.sh
	$(ROOT)/tests/host/test-http-https-redirect.sh
	$(ROOT)/tests/host/test-nginx-conf.sh
	$(ROOT)/tests/host/test-nginx-origin.sh
	$(ROOT)/tests/host/test-nginx-device.sh
	$(ROOT)/tests/host/test-lan-addrs-hotplug.sh
	$(ROOT)/tests/host/test-cgi-origin.sh
	$(ROOT)/tests/host/test-cgi-auth.sh
	$(ROOT)/tests/host/test-bitcoin-conf-raw.sh
	$(ROOT)/tests/host/test-input-validation.sh
	$(ROOT)/tests/host/test-factory-reset-baseline.sh
	$(ROOT)/tests/host/test-node-op-lock.sh
	$(ROOT)/tests/host/test-ui-ports-restart.sh
	$(ROOT)/tests/host/test-setup-api-retry.sh
	$(ROOT)/tests/host/test-factory-secret.sh
	$(ROOT)/tests/host/test-provision-secret.sh
	$(ROOT)/tests/host/test-node-ui-tls.sh
	$(ROOT)/tests/host/test-uhttpd-device.sh
	$(ROOT)/tests/host/test-upgrade-apply.sh
	$(ROOT)/tests/host/test-progress-steps.sh
	$(ROOT)/tests/host/test-node-op-result.sh
	$(ROOT)/tests/host/test-setup-finish.sh
	$(ROOT)/tests/host/test-d2-host.sh
	$(ROOT)/tests/host/test-nginx-apply.sh
	$(ROOT)/tests/host/test-flash-tools.sh
	$(ROOT)/tests/host/test-phase8.sh
	$(ROOT)/tests/host/test-emmc-gpt.sh
	$(ROOT)/tests/host/test-image-tools.sh
	$(ROOT)/tests/host/test-console-login.sh
	$(ROOT)/tests/host/test-clock-floor.sh
	$(ROOT)/tests/host/test-trust-deb.sh
	$(ROOT)/tests/host/test-sticker-recovery.sh
	$(ROOT)/tests/host/test-offline-script.sh
	$(ROOT)/tests/host/test-disk-health.sh
	$(ROOT)/tests/host/test-factory-station.sh
	$(ROOT)/tests/host/test-factory-label.sh
	$(ROOT)/tests/host/test-factory-station-app.sh
	$(ROOT)/tests/host/test-captive-portal.sh
	$(ROOT)/tests/host/test-first-boot.sh
	$(ROOT)/tests/host/test-release-sig.sh
	$(ROOT)/tests/host/test-unit-name.sh
	$(ROOT)/tests/host/test-tls-installers.sh
	$(ROOT)/tests/host/test-http-setup-iue.sh
	$(ROOT)/tests/host/test-urldecode.sh
	$(ROOT)/tests/host/test-uat-web.sh
	$(ROOT)/tests/host/run-iue.sh
	@echo "=== test-host PASSED ==="

# Laptop web UAT — copy runner to LAPTOP:~/Documents/knots-uat (no serial).
# Usage: make uat-web-install LAPTOP=user@laptop
LAPTOP ?=
uat-web-install:
	@test -n "$(LAPTOP)" || { echo "usage: make uat-web-install LAPTOP=user@laptop" >&2; exit 1; }
	chmod +x $(ROOT)/tests/device/uat-web.sh $(ROOT)/tests/device/uat-web.py \
		$(ROOT)/tests/device/uat_wizard.py $(ROOT)/tests/device/uat-web-run.sh
	ssh $(LAPTOP) 'mkdir -p $$HOME/Documents/knots-uat'
	scp $(ROOT)/tests/device/uat-web.py $(ROOT)/tests/device/uat_wizard.py \
		$(ROOT)/tests/device/uat-web.sh $(ROOT)/tests/device/uat-web-run.sh \
		$(ROOT)/docs/UAT_WEB.md \
		$(LAPTOP):Documents/knots-uat/
	ssh $(LAPTOP) 'chmod +x $$HOME/Documents/knots-uat/uat-web.sh $$HOME/Documents/knots-uat/uat-web.py \
		$$HOME/Documents/knots-uat/uat-web-run.sh; \
		cp $$HOME/Documents/knots-uat/uat-web-run.sh $$HOME/Documents/knots-uat/run; \
		chmod +x $$HOME/Documents/knots-uat/run; ls -l $$HOME/Documents/knots-uat'
	@echo "=== uat-web installed. On the laptop: cd ~/Documents/knots-uat && ./run ==="

# U17 / U19 / N13 — first-run Setup + TLS OS install simulations (host)
test-iue:
	chmod +x $(ROOT)/tests/host/run-iue.sh $(ROOT)/tests/host/test-iue-*.sh \
		$(ROOT)/tests/host/test-tls-install-scripts.sh \
		$(ROOT)/tests/host/test-node-ui-tls-local-ca.sh \
		$(ROOT)/tests/device/test-iue.sh
	$(ROOT)/tests/host/run-iue.sh
	@# X4: device tests drive (and can complete Setup on) a real unit — only
	@# with an explicit SERIAL=, never because /dev/ttyUSB0 happens to exist.
	@if [ -n "$(SERIAL)" ]; then \
		SERIAL="$(SERIAL)" $(ROOT)/tests/device/test-iue.sh; \
	else \
		echo "NOTE: no SERIAL= — skipped device IUE (make test-iue SERIAL=/dev/ttyUSB0)"; \
	fi
	@echo "=== test-iue PASSED ==="

# U17 / N13 — laptop-perspective IUE (serial + SSH from router to LAN PC)
test-iue-client:
	chmod +x $(ROOT)/tests/device/test-iue-client.sh
	@test -n "$(SERIAL)" || { echo "usage: make test-iue-client SERIAL=/dev/ttyUSB0 PC_IP=… PC_USER=… PC_PASS=…" >&2; exit 1; }
	SERIAL="$(SERIAL)" \
		PC_IP="$(PC_IP)" PC_USER="$(PC_USER)" PC_PASS="$(PC_PASS)" \
		START_AT="$(if $(START_AT),$(START_AT),P0)" \
		$(ROOT)/tests/device/test-iue-client.sh
	@echo "=== test-iue-client complete ==="

test-wipe-loop:
	chmod +x $(ROOT)/tests/host/test-wipe-loop.sh
	@# S7: absence-assert stub (wipe tooling retired) — runs unprivileged
	$(ROOT)/tests/host/test-wipe-loop.sh
	@echo "=== test-wipe-loop PASSED (or skipped) ==="

# T-IUE-E2E — full end-user wizard walkthrough (needs IUE state; IUE_RESET=1 resets first)
test-iue-e2e:
	chmod +x $(ROOT)/tests/device/test-iue-e2e.sh
	SERIAL="$(SERIAL)" IUE_RESET="$(IUE_RESET)" $(ROOT)/tests/device/test-iue-e2e.sh
	@echo "=== test-iue-e2e complete ==="

test-device:
	@test -n "$(SERIAL)" || { echo "usage: make test-device SERIAL=/dev/ttyUSB0 [SERIAL_PASS=router password, default factory] (drives a real unit)" >&2; exit 1; }
	chmod +x $(ROOT)/tests/device/smoke.sh $(ROOT)/tests/device/test-ui.sh \
		$(ROOT)/tests/device/test-iue.sh
	SERIAL="$(SERIAL)" SERIAL_PASS="$(SERIAL_PASS)" $(ROOT)/tests/device/smoke.sh
	SERIAL="$(SERIAL)" SERIAL_PASS="$(SERIAL_PASS)" $(ROOT)/tests/device/test-ui.sh
	SERIAL="$(SERIAL)" SERIAL_PASS="$(SERIAL_PASS)" $(ROOT)/tests/device/test-iue.sh
	@echo "=== test-device PASSED ==="

# T5 / NF10 — zone isolation (docs/SECURITY_ZONE_TEST.md)
test-zone-security:
	chmod +x $(ROOT)/tests/security/*.sh $(ROOT)/tests/security/lib/*.sh
	ROUTER_LAN_IP="$(ROUTER_LAN_IP)" ROUTER_WAN_IP="$(ROUTER_WAN_IP)" \
		ROUTER_SSH="$(ROUTER_SSH)" RUN_WIFI="$(RUN_WIFI)" WIFI_PSK="$(WIFI_PSK)" \
		SKIP_ASSOC="$(SKIP_ASSOC)" RETAIL="$(RETAIL)" \
		$(ROOT)/tests/security/run-all.sh
	@echo "=== test-zone-security complete ==="

# Host always; device tests only with an explicit SERIAL= (X4)
test: test-host
	@if [ -n "$(SERIAL)" ]; then \
		$(MAKE) test-device SERIAL="$(SERIAL)"; \
	else \
		echo "NOTE: no SERIAL= — skipped test-device (make test SERIAL=/dev/ttyUSB0)"; \
	fi
	@echo "=== make test complete ==="
