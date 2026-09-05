# SepiaOS - the wifi userspace for the target
#
# Downloads libnl and wpa_supplicant and cross-builds them to run *on* the Pi,
# linked dynamically against the musl from `Sepia-OS/musl`. Together they are
# what turns a Broadcom radio and an nl80211 driver into a device that can join
# a network: wpa_supplicant speaks WPA/WPA2, libnl carries it to the kernel.
#
#   make toolchain-check    prove the cross-compiler builds C against musl
#   make wifi               cross-build both
#   make stage-check        prove every product is aarch64 and self-contained
#   make help               every target
#
# No root, no containers: everything is a download plus a cross-build, so the
# same recipes work on macOS and Linux.
#
# What is *not* here: the Broadcom firmware blobs. Those are a download - an
# unpacked Debian package - rather than a build, they are five times the size
# of everything this repository produces, and they are tied to the kernel that
# loads them. ../rootfs still fetches them.

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

# Make 3.81 (still /usr/bin/make on macOS) compares timestamps only to the
# second and silently reuses stale outputs after a fast edit.
ifeq ($(filter 4.% 5.%,$(MAKE_VERSION)),)
$(error GNU Make >= 4.0 required, found $(MAKE_VERSION). On macOS: brew install make, then run gmake)
endif

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

# --retry-all-errors is load-bearing rather than decoration: ../llvm measured
# four consecutive single-shot fetches of the musl tarball failing from
# debian:trixie-slim, two with a TLS handshake error, which plain --retry does
# not class as transient and therefore will not retry.
CURL   := curl --fail --silent --show-error --location \
                --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors
SHA256 := $(shell command -v sha256sum >/dev/null 2>&1 && echo "sha256sum" || echo "shasum -a 256")

GITHUB_API ?= https://api.github.com

DL_DIR    := downloads
BUILD_DIR := build
DIST_DIR  := dist
CHECKSUMS := checksums

HOST_OS   := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

# Homebrew sets CPPFLAGS and LDFLAGS in the developer's shell on macOS, and
# configure reads them straight onto *cross* compile lines. ../llvm found
# -I/opt/homebrew/opt/include and -L/opt/homebrew/opt/lib in a real target
# link: nothing broke, because nothing was found there, but a host header or
# library that *was* found would have gone into a target binary silently.
SCRUB_ENV := env -u CPPFLAGS -u LDFLAGS -u CFLAGS -u CXXFLAGS \
                 -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH

# Overriding a variable on the command line changes what gets built but touches
# no file, so Make cannot see it. Each expensive tree therefore carries a
# signature of the settings that determine its contents, rewritten only when it
# actually changes so that it works as an ordinary prerequisite.
.PHONY: FORCE
FORCE:

# $(1) stamp path, $(2) signature
define config_stamp_rule
$(1): FORCE
	@mkdir -p $$(@D)
	@printf '%s\n' '$(2)' | cmp -s - $$@ || printf '%s\n' '$(2)' > $$@
endef

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The upstream releases to build. Newer:
#   https://github.com/thom311/libnl/releases
#   https://w1.fi/releases/
#
# Pinned rather than resolved, unlike the ../rootfs step this replaces, which
# asked GitHub and w1.fi what was newest on every build: a release asset has to
# say which versions it holds, and CI has to build the same thing twice.
LIBNL_VERSION ?= 3.12.0
WPA_VERSION   ?= 2.12

LIBNL_REPO := https://github.com/thom311/libnl
WPA_BASE   := https://w1.fi/releases

# Where the package lands on the device: the libraries in /usr/lib, the three
# programs in /usr/sbin. That is where ../rootfs has always put them.
PREFIX ?= /usr

# The triple the product is built for, fixed rather than taken from whichever
# compiler built it. The siblings pin the same one for the same reason: the two
# toolchain vendors disagree about their own name (messense says
# aarch64-unknown-linux-musl, bootlin says aarch64-buildroot-linux-musl).
TARGET_TRIPLE := aarch64-unknown-linux-musl

# Measured on 3.12.0/2.12: 1.2 MiB of programs and libraries unstripped. There
# is no debugger on the device to want the symbols.
WITH_STRIP ?= 1

# ---------------------------------------------------------------------------
# Cross-toolchain
#
# The musl-*targeting* toolchain, which is the whole point: these binaries have
# to link against the libc that is actually on the card.
#
# Two vendors, because no single one publishes a musl-targeting aarch64
# toolchain for both hosts: messense publishes darwin-hosted builds only,
# bootlin (Buildroot) publishes Linux-hosted x86_64 builds only. So macOS is
# the development host and Linux is the release host, matching every sibling.
# TARGET_TRIPLE above is what keeps the product identical either way.
# ---------------------------------------------------------------------------

ifeq ($(HOST_OS),Darwin)
  TC_VENDOR      := messense
  TC_VERSION_DEF := 15.2.0
  TC_PREFIX      := aarch64-unknown-linux-musl-
  ifeq ($(HOST_ARCH),arm64)
    TC_HOST := aarch64-darwin
  else ifeq ($(HOST_ARCH),x86_64)
    TC_HOST := x86_64-darwin
  endif
  TC_ARCHIVE  = aarch64-unknown-linux-musl-$(TC_HOST).tar.gz
  TC_BASE    := https://github.com/messense/homebrew-macos-cross-toolchains/releases/download
  TC_URL      = $(TC_BASE)/v$(TC_VERSION)/$(TC_ARCHIVE)
  TC_SUMS     = $(TC_ARCHIVE).sha256
  TC_SUMS_URL = $(TC_URL).sha256
else ifeq ($(HOST_OS),Linux)
  TC_VENDOR      := bootlin
  TC_VERSION_DEF := 2025.08-1
  # bootlin names its tools aarch64-linux-*, not after the full triple.
  TC_PREFIX      := aarch64-linux-
  ifeq ($(HOST_ARCH),x86_64)
    TC_HOST := x86_64
  endif
  TC_ARCHIVE  = aarch64--musl--stable-$(TC_VERSION).tar.xz
  TC_BASE    := https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs
  TC_URL      = $(TC_BASE)/$(TC_ARCHIVE)
  TC_SUMS     = aarch64--musl--stable-$(TC_VERSION).sha256
  TC_SUMS_URL = $(TC_BASE)/$(TC_SUMS)
endif

TC_VERSION ?= $(TC_VERSION_DEF)

# Point this at a musl cross-toolchain you already have and nothing is
# downloaded - the escape hatch for a host neither vendor covers, and the way
# to build against a sibling's already-extracted toolchain.
CROSS_COMPILE ?=

DL_TC     := $(DL_DIR)/toolchain
TC_DIR     = $(DL_TC)/$(TC_VENDOR)-$(TC_VERSION)-$(TC_HOST)
TC_STAMP   = $(TC_DIR)/.extracted
CROSS      = $(or $(CROSS_COMPILE),$(abspath $(TC_DIR))/bin/$(TC_PREFIX))
TOOLCHAIN_DEP = $(if $(CROSS_COMPILE),,$(TC_STAMP))

TC_GOALS := toolchain toolchain-info toolchain-check musl musl-info musl-check \
            libnl wpa_supplicant wifi wifi-info stage stage-check stage-info dist
ifneq ($(filter $(TC_GOALS),$(MAKECMDGOALS)),)
  ifeq ($(CROSS_COMPILE),)
    ifeq ($(TC_HOST),)
      $(error No prebuilt musl-targeting aarch64 toolchain is published for $(HOST_OS)/$(HOST_ARCH) (macOS: messense, Linux/x86_64: bootlin). Set CROSS_COMPILE to one you have)
    endif
  endif
endif

# ---------------------------------------------------------------------------
# Step 1 - the cross-toolchain
# ---------------------------------------------------------------------------

.PHONY: toolchain
toolchain: $(TOOLCHAIN_DEP) ## Fetch the musl-targeting aarch64 cross-compiler
	@$(call assert_cross_compiler)
	@echo "  READY    $(if $(CROSS_COMPILE),CROSS_COMPILE -> $(CROSS)gcc,$(TC_VENDOR) $(TC_VERSION) -> $(TC_DIR))"

# Nothing under $(TC_DIR) is a prerequisite: release archives are immutable, so
# once a version is unpacked it is never unpacked again. Change TC_VERSION and
# the path changes with it.
$(TC_STAMP):
	@command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }
	@mkdir -p $(DL_TC)
	@if [ ! -f $(DL_TC)/$(TC_ARCHIVE) ]; then \
	   echo "  FETCH    $(TC_ARCHIVE) (78 MiB bootlin, 132 MiB messense)"; \
	   $(CURL) -o $(DL_TC)/$(TC_ARCHIVE).part "$(TC_URL)"; \
	   mv -f $(DL_TC)/$(TC_ARCHIVE).part $(DL_TC)/$(TC_ARCHIVE); \
	 fi
	@if [ ! -f $(DL_TC)/$(TC_SUMS) ]; then \
	   $(CURL) -o $(DL_TC)/$(TC_SUMS).part "$(TC_SUMS_URL)"; \
	   mv -f $(DL_TC)/$(TC_SUMS).part $(DL_TC)/$(TC_SUMS); \
	 fi
	@echo "  VERIFY   $(TC_ARCHIVE)"
	@( cd $(DL_TC) && $(SHA256) --check --quiet $(TC_SUMS) ) || { \
	   echo "  FAIL     $(TC_ARCHIVE) does not match upstream's digest; delete $(DL_TC) and retry" >&2; \
	   exit 1; }
	@echo "  UNPACK   $(TC_ARCHIVE) -> $(TC_DIR)"
	@rm -rf $(TC_DIR)
	@mkdir -p $(TC_DIR)
	@tar -xf $(DL_TC)/$(TC_ARCHIVE) -C $(TC_DIR) --strip-components=1
	@touch $@
	@$(call assert_cross_compiler)

# A cross-compiler for the wrong host arch extracts happily and then fails to
# exec; one for the wrong target compiles happily and produces the wrong
# binaries. -dumpmachine catches both in one cheap call - and here it must say
# musl, because a gnu toolchain would link these programs against glibc.
define assert_cross_compiler
	command -v $(CROSS)gcc >/dev/null 2>&1 || { \
	  echo "  FAIL     no $(CROSS)gcc" >&2; exit 1; }; \
	m=$$($(CROSS)gcc -dumpmachine) || { \
	  echo "  FAIL     $(CROSS)gcc will not run on $(HOST_OS)/$(HOST_ARCH)" >&2; exit 1; }; \
	case "$$m" in \
	  aarch64-*linux-musl*) ;; \
	  aarch64-*linux*) echo "  FAIL     $(CROSS)gcc targets $$m - that is a gnu toolchain, so it would link wpa_supplicant against glibc" >&2; exit 1;; \
	  *) echo "  FAIL     $(CROSS)gcc targets $$m, not aarch64 linux musl" >&2; exit 1;; \
	esac
endef

.PHONY: toolchain-info
toolchain-info: $(TOOLCHAIN_DEP) ## Show the cross-compiler in use
	@echo "  host     $(HOST_OS) $(HOST_ARCH)"
	@echo "  source   $(if $(CROSS_COMPILE),CROSS_COMPILE override,$(TC_VENDOR) $(TC_VERSION))"
	@echo "  prefix   $(CROSS)"
	@echo "  target   $$($(CROSS)gcc -dumpmachine)"
	@$(CROSS)gcc --version | sed -n '1s/^/  gcc      /p'
	@$(CROSS)ld --version | sed -n '1s/^/  ld       /p'
	@echo "  sysroot  $$($(CROSS)gcc -print-sysroot)"

TC_CHECK_DIR := $(BUILD_DIR)/toolchain-check

.PHONY: toolchain-check
toolchain-check: $(TOOLCHAIN_DEP) ## Prove the cross-compiler builds C against musl
	@$(call assert_cross_compiler)
	@mkdir -p $(TC_CHECK_DIR)
	@printf '%s\n' \
	  '#include <stdio.h>' \
	  '#include <stdlib.h>' \
	  'int main(void) { printf("sepiaos\n"); return EXIT_SUCCESS; }' \
	  > $(TC_CHECK_DIR)/t.c
	@$(CROSS)gcc -O2 -o $(TC_CHECK_DIR)/t.dyn $(TC_CHECK_DIR)/t.c \
	  || { echo "  FAIL     C does not compile for musl dynamically" >&2; exit 1; }
	@echo "  OK       dynamic  $$($(CROSS)readelf -d $(TC_CHECK_DIR)/t.dyn | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
	@$(CROSS)gcc -O2 -static -o $(TC_CHECK_DIR)/t.static $(TC_CHECK_DIR)/t.c \
	  || { echo "  FAIL     C does not link statically against musl" >&2; exit 1; }
	@echo "  OK       static   $$(wc -c < $(TC_CHECK_DIR)/t.static | tr -d ' ') bytes"
	@echo "  READY    $(if $(CROSS_COMPILE),CROSS_COMPILE,$(TC_VENDOR) $(TC_VERSION)) builds C against musl"

# ---------------------------------------------------------------------------
# Step 2 - the musl sysroot, from Sepia-OS/musl
#
# Fetched, not built. `Sepia-OS/musl` publishes the libc as a sysroot - the
# loader, libc.so, libc.a, the crt objects and 217 headers - and libnl and
# wpa_supplicant are compiled against exactly the bytes the card will run on.
#
# ../llvm, ../make and ../e2fsprogs each still build their own copy of the musl
# sources for this. This repository is the first package to consume the release
# instead, which is the direction ../rootfs moved in: one repository owns the
# libc, one release names it, and "built against musl 1.2.6" stops being a
# claim that three Makefiles have to keep true independently.
#
# The Linux UAPI headers are added on top from the cross-toolchain's own
# sysroot. The musl release deliberately does not carry them - they have to
# match the compiler that will use them - and libnl and wpa_supplicant want a
# lot of them: linux/netlink.h, linux/genetlink.h, linux/if_packet.h,
# linux/rtnetlink.h and the nl80211 header itself.
#
# CHANNEL, WITH_ and the rest do not appear here: there is no build without a
# libc, so a published release in Sepia-OS/musl is a precondition. MUSL_TAG
# pins one.
# ---------------------------------------------------------------------------

MUSL_REPO ?= Sepia-OS/musl

# Pin a specific release, e.g. MUSL_TAG=v1.2.6. Empty means "resolve the newest
# one", resolved once and then cached in build/musl/release.env like every
# other upstream version this build takes. `make musl-update` moves it.
MUSL_TAG  ?=

DL_MUSL    := $(DL_DIR)/musl
MUSL_DIR   := $(BUILD_DIR)/musl
MUSL_ENV   := $(MUSL_DIR)/release.env
MUSL_STAGE := $(MUSL_DIR)/stage
MUSL_STAMP := $(MUSL_DIR)/.installed
MUSL_CFG   := $(MUSL_DIR)/.config

# The trailing token is the format of release.env rather than an input to it;
# bump it when a field is added, so an env file written by an older Makefile is
# re-resolved instead of being sourced with the new field silently empty.
MUSL_SIG    = $(MUSL_REPO)|$(MUSL_TAG)|$(GITHUB_API)|env1

# Where musl lands, and what steps 3 and 4 compile against.
SYSROOT := $(BUILD_DIR)/sysroot

.PHONY: musl
musl: $(MUSL_STAMP) ## Fetch, verify and unpack the musl sysroot to build against
	@source $(MUSL_ENV); printf '  READY    musl %s (%s) -> %s\n' \
	   "$$MUSL_VER" "$$MUSL_TAG" $(SYSROOT)

$(MUSL_CFG): FORCE
	@mkdir -p $(@D)
	@printf '%s\n' '$(MUSL_SIG)' | cmp -s - $@ || printf '%s\n' '$(MUSL_SIG)' > $@

# The release body is mined the way the boot, llvm, make and e2fsprogs ones
# are: it states the version verbatim as a table row, `| musl | `1.2.6` |`.
# That is what /etc/os-release records and what the release notes quote, and a
# release that does not name it leaves the field empty rather than failing this
# step - but it *is* the field the image's own version string is built from, so
# an empty one is worth noticing.
$(MUSL_ENV): $(MUSL_CFG)
	@mkdir -p $(@D)
	@command -v jq >/dev/null 2>&1 || { \
	  echo "jq is required to read the GitHub release metadata." >&2; \
	  echo "macOS 13+ ships it at /usr/bin/jq; otherwise: brew install jq / apt-get install jq" >&2; \
	  exit 1; }
	@echo "  RESOLVE  $(MUSL_REPO) ($(if $(MUSL_TAG),pinned $(MUSL_TAG),newest release))"
	@api="$(GITHUB_API)/repos/$(MUSL_REPO)"; \
	 hdr=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28'); \
	 if [ -n "$${GITHUB_TOKEN:-}" ]; then hdr+=(-H "Authorization: Bearer $$GITHUB_TOKEN"); fi; \
	 body=$$(mktemp); trap 'rm -f "$$body"' EXIT; \
	 get() { curl --silent --show-error --location \
	              --retry 3 --retry-delay 2 --retry-connrefused \
	              "$${hdr[@]}" -o "$$body" -w '%{http_code}' "$$1"; }; \
	 refuse() { \
	   case "$$1" in \
	     403|429) echo "GitHub API rate limit hit (HTTP $$1). Set GITHUB_TOKEN to raise it." >&2;; \
	     *) echo "GitHub API returned HTTP $$1 for $$2" >&2;; \
	   esac; exit 1; }; \
	 if [ -n '$(MUSL_TAG)' ]; then \
	   code=$$(get "$$api/releases/tags/$(MUSL_TAG)"); \
	   if [ "$$code" = 404 ]; then \
	     echo "$(MUSL_REPO) has no release tagged '$(MUSL_TAG)'. Leave MUSL_TAG empty" >&2; \
	     echo "to take the newest one, or check 'gh release list --repo $(MUSL_REPO)'." >&2; \
	     exit 1; fi; \
	   [ "$$code" = 200 ] || refuse "$$code" "release $(MUSL_TAG)"; \
	   rel=$$(cat "$$body"); \
	 else \
	   code=$$(get "$$api/releases?per_page=100"); \
	   if [ "$$code" = 404 ]; then \
	     echo "$(MUSL_REPO) does not exist, or this token cannot see it. It is a" >&2; \
	     echo "hard dependency - there is no card without a libc - so create it and" >&2; \
	     echo "cut a release, or point MUSL_REPO at one that has." >&2; \
	     exit 1; fi; \
	   [ "$$code" = 200 ] || refuse "$$code" "the release list"; \
	   rel=$$(jq -c '[.[]|select(.draft==false)]|sort_by(.published_at)|last' "$$body"); \
	   if [ -z "$$rel" ] || [ "$$rel" = null ]; then \
	     echo "$(MUSL_REPO) has published no release yet. There is no build without" >&2; \
	     echo "a libc, so pin one with MUSL_TAG=<tag> or cut a release there first." >&2; \
	     exit 1; fi; \
	 fi; \
	 tag=$$(jq -r '.tag_name // empty' <<<"$$rel"); \
	 pre=$$(jq -r '.prerelease // false' <<<"$$rel"); \
	 ast=$$(jq -r '[.assets[] | select(.name | endswith(".tar.xz"))] | first | .name // empty' <<<"$$rel"); \
	 asturl=$$(jq -r '[.assets[] | select(.name | endswith(".tar.xz"))] | first | .browser_download_url // empty' <<<"$$rel"); \
	 astid=$$(jq -r '[.assets[] | select(.name | endswith(".tar.xz"))] | first | .id // empty' <<<"$$rel"); \
	 sumurl=$$(jq -r '[.assets[] | select(.name == "SHA256SUMS")] | first | .browser_download_url // empty' <<<"$$rel"); \
	 if [ -z "$$ast" ]; then \
	   echo "Release $$tag carries no .tar.xz asset - was it renamed?" >&2; exit 1; fi; \
	 if [ -z "$$sumurl" ]; then \
	   echo "Release $$tag carries no SHA256SUMS - refusing to use an unverifiable asset." >&2; exit 1; fi; \
	 [[ "$$astid" =~ ^[0-9]+$$ ]] || { \
	   echo "Release $$tag gave asset id '$$astid', which is not a number - the" >&2; \
	   echo "cache below keys on it, so refusing rather than caching on nothing." >&2; exit 1; }; \
	 for v in "$$tag" "$$ast"; do \
	   [[ "$$v" =~ ^[A-Za-z0-9._+-]+$$ ]] || { echo "Refusing '$$v': not a plain tag/filename." >&2; exit 1; }; \
	 done; \
	 for v in "$$asturl" "$$sumurl"; do \
	   [[ "$$v" == https://* ]] || { echo "Refusing non-https URL '$$v'." >&2; exit 1; }; \
	 done; \
	 ver=$$(jq -r '.body // ""' <<<"$$rel" \
	        | sed -n 's/^| *musl *|[^|]*`\([^`]*\)`.*/\1/p' | head -1); \
	 [[ "$$ver" =~ ^[0-9][0-9A-Za-z._-]*$$ ]] || ver=''; \
	 { echo "MUSL_TAG='$$tag'"; \
	   echo "MUSL_PRERELEASE='$$pre'"; \
	   echo "MUSL_ASSET='$$ast'"; \
	   echo "MUSL_ASSET_URL='$$asturl'"; \
	   echo "MUSL_ASSET_ID='$$astid'"; \
	   echo "MUSL_SUMS_URL='$$sumurl'"; \
	   echo "MUSL_VER='$$ver'"; } > $@.part
	@mv -f $@.part $@
	@sed -n "s/^MUSL_TAG='\(.*\)'/  MUSL     \1/p" $@

# Keyed by tag under downloads/, surviving `clean` like every other upstream
# artifact, with the release asset's GitHub id recorded beside it: that
# repository keeps its releases and refuses to reuse a version, but the retry
# path its own error message recommends is deleting a release and republishing
# it, after which the same tag names different bytes. The marker is written
# only after VERIFY passes, so an interrupted download is refetched rather than
# trusted.
#
# Unpacked into build/musl/stage and only then copied into the sysroot, rather
# than straight into it: an asset that turns out to be the wrong shape must not
# be able to leave the sysroot half-replaced, because the previous one still
# works.
$(MUSL_STAMP): $(MUSL_ENV) $(TOOLCHAIN_DEP) Makefile
	@command -v xz >/dev/null 2>&1 || { \
	  echo "xz is required to unpack the asset (brew install xz / apt-get install xz-utils)" >&2; \
	  exit 1; }
	@mkdir -p $(@D)
	@source $(MUSL_ENV); \
	 d=$(DL_MUSL)/$$MUSL_TAG; mkdir -p "$$d"; \
	 if [ ! -f "$$d/.asset-id" ] \
	    || [ "$$(cat "$$d/.asset-id")" != "$$MUSL_ASSET_ID" ]; then \
	   rm -f "$$d/SHA256SUMS" "$$d/$$MUSL_ASSET"; \
	 fi; \
	 if [ ! -f "$$d/SHA256SUMS" ]; then \
	   echo "  FETCH    SHA256SUMS"; \
	   $(CURL) -o "$$d/SHA256SUMS.part" "$$MUSL_SUMS_URL"; \
	   mv -f "$$d/SHA256SUMS.part" "$$d/SHA256SUMS"; \
	 fi; \
	 if [ ! -f "$$d/$$MUSL_ASSET" ] \
	    || ! ( cd "$$d" && grep -F "$$MUSL_ASSET" SHA256SUMS \
	           | $(SHA256) --check --quiet - ) >/dev/null 2>&1; then \
	   echo "  FETCH    $$MUSL_ASSET"; \
	   $(CURL) -o "$$d/$$MUSL_ASSET.part" "$$MUSL_ASSET_URL"; \
	   mv -f "$$d/$$MUSL_ASSET.part" "$$d/$$MUSL_ASSET"; \
	 fi; \
	 echo "  VERIFY   $$MUSL_ASSET"; \
	 ( cd "$$d" && grep -F "$$MUSL_ASSET" SHA256SUMS | $(SHA256) --check --quiet - ) || { \
	   echo "  FAIL     $$MUSL_ASSET does not match SHA256SUMS; delete $$d and retry" >&2; exit 1; }; \
	 printf '%s\n' "$$MUSL_ASSET_ID" > "$$d/.asset-id"; \
	 echo "  UNPACK   $$MUSL_ASSET"; \
	 rm -rf $(MUSL_STAGE); mkdir -p $(MUSL_STAGE); \
	 tar -xf "$$d/$$MUSL_ASSET" -C $(MUSL_STAGE)
	@$(call assert_musl_asset)
	@echo "  INSTALL  -> $(SYSROOT)"
	@rm -rf $(SYSROOT)
	@mkdir -p $(SYSROOT)
	@cp -R $(MUSL_STAGE)/. $(SYSROOT)/
	@$(call install_uapi_headers)
	@$(call assert_musl)
	@touch $@

# Asked of the unpacked asset before any of it reaches the sysroot, so a
# truncated or wrong-shaped one fails naming itself rather than leaving the
# tree half-replaced.
#
# The loader is checked with -L and readlink rather than -e, and that is not
# fussiness: musl installs it as a symlink to the *absolute* path
# /usr/lib/libc.so, which resolves on the card and nowhere else. On a Linux
# build host `[ -e ]` would follow it to that host's own /usr/lib/libc.so -
# glibc's linker script - and pass for entirely the wrong reason.
#
# The crt objects and the headers are named because they are what makes this a
# sysroot rather than a runtime: without them nothing here links at all. ELF byte 18 is e_machine,
# little-endian, and 0xb7 is AArch64.
define assert_musl_asset
	set -e; s=$(MUSL_STAGE); \
	for f in usr/lib/libc.so usr/lib/libc.a usr/lib/crt1.o usr/lib/crti.o \
	         usr/lib/crtn.o usr/lib/Scrt1.o usr/include/stdio.h \
	         usr/share/licenses/musl/COPYRIGHT; do \
	  [ -f "$$s/$$f" ] || { \
	    echo "  FAIL     $$f is missing - is this a SepiaOS musl asset?" >&2; exit 1; }; \
	done; \
	m=$$(od -An -tx1 -j 18 -N2 "$$s/usr/lib/libc.so" | tr -d ' \n'); \
	[ "$$m" = "b700" ] || { \
	  echo "  FAIL     usr/lib/libc.so has ELF machine 0x$$m, expected b700 (AArch64)" >&2; exit 1; }; \
	[ -L "$$s/lib/ld-musl-aarch64.so.1" ] || { \
	  echo "  FAIL     lib/ld-musl-aarch64.so.1 is not a symlink - every binary's PT_INTERP names it" >&2; exit 1; }; \
	t=$$(readlink "$$s/lib/ld-musl-aarch64.so.1"); \
	[ "$$t" = /usr/lib/libc.so ] || { \
	  echo "  FAIL     the loader points at '$$t', not /usr/lib/libc.so" >&2; exit 1; }; \
	for d in bin sbin usr/bin usr/sbin; do \
	  [ ! -d "$$s/$$d" ] || { \
	    echo "  FAIL     the asset carries $$d/ - that is a rootfs, not a libc" >&2; exit 1; }; \
	done
endef

# Both linkages are what the README asks for, so both are actually exercised
# rather than inferred from the presence of libc.a and libc.so. It is worth
# keeping now that musl arrives as a download rather than a build: this is the
# check that says the *combination* of somebody else's libc and this
# repository's cross-toolchain works, which is a thing neither side can test
# alone. readelf comes from the cross-toolchain itself, so this needs nothing
# that is not already a dependency - `file` is absent from a slim Debian image.
define assert_musl
	set -e; \
	d=$(MUSL_DIR)/.check; rm -rf $$d; mkdir -p $$d; \
	printf '#include <stdio.h>\nint main(void){puts("sepia");return 0;}\n' > $$d/t.c; \
	$(CROSS)gcc --sysroot=$(abspath $(SYSROOT)) -static -O2 -o $$d/t.static $$d/t.c \
	  || { echo "  FAIL     nothing links statically against $(SYSROOT)" >&2; exit 1; }; \
	$(CROSS)gcc --sysroot=$(abspath $(SYSROOT)) -O2 \
	    -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1 -o $$d/t.dyn $$d/t.c \
	  || { echo "  FAIL     nothing links dynamically against $(SYSROOT)" >&2; exit 1; }; \
	$(CROSS)readelf -h $$d/t.static | grep -q AArch64 \
	  || { echo "  FAIL     the static test binary is not aarch64" >&2; exit 1; }; \
	$(CROSS)readelf -l $$d/t.dyn | grep -q ld-musl-aarch64.so.1 \
	  || { echo "  FAIL     the dynamic test binary does not use the musl loader" >&2; exit 1; }
endef

# musl installs libc headers and nothing else, which is not a usable sysroot:
# anything that talks to the kernel needs the Linux UAPI headers too, and
# libnl is nothing but talk to the kernel. They are
# taken from the cross-toolchain's own sysroot - the same toolchain that
# supplies libgcc - rather than downloaded separately, so this costs nothing
# and cannot drift from the compiler. The musl release deliberately does not
# carry them, for exactly that reason.
#
# The whole sysroot is replaced on every refetch here, unlike in ../rootfs
# where busybox and the kernel modules live in the same tree: nothing else
# writes into this one.
define install_uapi_headers
	set -e; \
	k=$$($(CROSS)gcc -print-sysroot)/usr/include; \
	[ -d "$$k" ] || { echo "  FAIL     $(CROSS)gcc has no sysroot to take UAPI headers from" >&2; exit 1; }; \
	for d in linux asm asm-generic mtd rdma sound video drm misc scsi xen; do \
	  if [ -d "$$k/$$d" ]; then cp -R "$$k/$$d" $(abspath $(SYSROOT))/usr/include/; fi; \
	done; \
	[ -f $(abspath $(SYSROOT))/usr/include/linux/kd.h ] \
	  || { echo "  FAIL     no Linux UAPI headers landed in $(SYSROOT)" >&2; exit 1; }
endef

.PHONY: musl-update
musl-update: ## Re-resolve the newest musl release and refetch
	@rm -f $(MUSL_ENV)
	@$(MAKE) --no-print-directory musl

.PHONY: musl-tag
musl-tag: $(MUSL_ENV) ## Print the musl release tag in use
	@source $(MUSL_ENV); echo "$$MUSL_TAG"

.PHONY: musl-check
musl-check: $(MUSL_STAMP) ## Link a test program against the sysroot, both ways
	@$(call assert_musl)
	@echo "  OK       static and dynamic both link against $(SYSROOT)"

.PHONY: musl-info
musl-info: $(MUSL_STAMP) ## Show the fetched musl release and what it installed
	@source $(MUSL_ENV); \
	 if [ "$$MUSL_PRERELEASE" = true ]; then k=' (pre-release)'; else k=''; fi; \
	 echo "  repo     $(MUSL_REPO)"; \
	 echo "  tag      $$MUSL_TAG$$k$(if $(MUSL_TAG), (pinned))"; \
	 echo "  asset    $$MUSL_ASSET"; \
	 echo "  version  musl $${MUSL_VER:-<not named in the release notes>}"
	@echo "  sysroot  $(SYSROOT)"
	@ls -l $(SYSROOT)/lib/ld-musl-aarch64.so.1 | sed 's/^/  loader   /'
	@printf '  static   %s (%s KiB)\n' $(SYSROOT)/usr/lib/libc.a "$$(( $$(wc -c < $(SYSROOT)/usr/lib/libc.a) / 1024 ))"
	@printf '  shared   %s (%s KiB)\n' $(SYSROOT)/usr/lib/libc.so "$$(( $$(wc -c < $(SYSROOT)/usr/lib/libc.so) / 1024 ))"
	@$(CROSS)readelf -h $(SYSROOT)/usr/lib/libc.so | sed -n 's/^ *Machine: *\(.*\)/  machine  \1/p'


# ---------------------------------------------------------------------------
# Step 3 - libnl
#
# The netlink library wpa_supplicant talks to the kernel through. Only the two
# shared objects it needs are built - libnl-3 and libnl-genl-3 - not the whole
# package: libnl also ships route, xfrm, nf and idiag libraries, a set of
# command line tools, and a parser that wants yacc and flex, and none of it is
# on the path from a passphrase to an association.
#
# YACC=false FLEX=false is how that is said out loud. libnl's configure looks
# for both and its Makefile would use them for the route library's address
# parser; pointing them at `false` keeps a host that happens to have bison from
# building something a host without it cannot.
#
# --disable-cli drops the tools, --disable-static the archives. What is left is
# two .so files and their SONAME symlinks.
# ---------------------------------------------------------------------------

LIBNL_ARCHIVE  = libnl-$(LIBNL_VERSION).tar.gz
LIBNL_TAG      = libnl$(subst .,_,$(LIBNL_VERSION))
LIBNL_URL      = $(LIBNL_REPO)/releases/download/$(LIBNL_TAG)/$(LIBNL_ARCHIVE)
LIBNL_SUMS     = $(CHECKSUMS)/libnl-$(LIBNL_VERSION).sha256

DL_SRC     := $(DL_DIR)/src
SRC_DIR    := $(BUILD_DIR)/src
LIBNL_SRC   = $(SRC_DIR)/libnl-$(LIBNL_VERSION)
LIBNL_STAMP = $(LIBNL_SRC)/.built

# Upstream publishes no digest sidecar for either of these, so - as ../make and
# ../llvm do - the digest is recorded on first fetch and checked on every fetch
# after that. Both files came from ../rootfs, where they were already committed
# and already being checked.
#
# $(1) directory, $(2) filename, $(3) url, $(4) checksums stem
define fetch_recorded
	set -e; mkdir -p $(1) $(CHECKSUMS); m=$(abspath $(CHECKSUMS))/$(4).sha256; \
	if [ ! -f $(1)/$(2) ]; then \
	  echo "  FETCH    $(2)"; \
	  $(CURL) -o $(1)/$(2).part "$(3)"; \
	  mv -f $(1)/$(2).part $(1)/$(2); \
	fi; \
	if [ -f "$$m" ]; then \
	  echo "  VERIFY   $(2)"; \
	  ( cd $(1) && $(SHA256) --check --quiet "$$m" ) || { \
	    echo "  FAIL     $(2) does not match $(CHECKSUMS)/$(4).sha256; delete $(1)/$(2) and retry" >&2; \
	    exit 1; }; \
	else \
	  ( cd $(1) && $(SHA256) $(2) ) > "$$m"; \
	  echo "  RECORD   $(CHECKSUMS)/$(4).sha256 - first fetch of this version, commit it"; \
	fi
endef

.PHONY: libnl
libnl: $(LIBNL_STAMP) ## Cross-build libnl-3 and libnl-genl-3
	@echo "  READY    libnl $(LIBNL_VERSION) -> $(LIBNL_SRC)/lib/.libs"

# pkg-config is not in debian:trixie-slim and libnl's configure insists on
# finding *something* it can ask for a version. Nothing here has a pkg-config
# dependency to resolve - the only library involved is the musl in the sysroot
# - so a five-line stub that answers the version question and refuses every
# other one is enough, and is better than installing a tool whose whole job
# here is to say "no".
$(LIBNL_STAMP): $(MUSL_STAMP) $(TOOLCHAIN_DEP) Makefile
	@$(call fetch_recorded,$(DL_SRC),$(LIBNL_ARCHIVE),$(LIBNL_URL),libnl-$(LIBNL_VERSION))
	@echo "  UNPACK   $(LIBNL_ARCHIVE)"
	@rm -rf $(LIBNL_SRC)
	@mkdir -p $(SRC_DIR)
	@tar -xf $(DL_SRC)/$(LIBNL_ARCHIVE) -C $(SRC_DIR)
	@echo "  CONFIG   libnl $(LIBNL_VERSION) (aarch64, dynamic against $(SYSROOT))"
	@s=$(LIBNL_SRC); \
	 if ! command -v pkg-config >/dev/null 2>&1; then \
	   p=$(abspath $(BUILD_DIR))/pkg-config-stub; mkdir -p $$p; \
	   printf '%s\n' '#!/bin/sh' \
	     'case "$$1" in --atleast-pkgconfig-version) exit 0;; --version) echo 0.29.2; exit 0;; esac' \
	     'exit 1' > $$p/pkg-config; chmod 0755 $$p/pkg-config; \
	   PATH=$$p:$$PATH; export PATH; \
	 fi; \
	 ( cd $$s && $(SCRUB_ENV) ./configure --host=aarch64-linux --prefix=$(PREFIX) \
	     --disable-static --disable-cli \
	     YACC=false FLEX=false \
	     CC=$(CROSS)gcc AR=$(CROSS)ar RANLIB=$(CROSS)ranlib \
	     CFLAGS="-Os $(MUSL_INCLUDES) --sysroot=$(abspath $(SYSROOT))" \
	     LDFLAGS="--sysroot=$(abspath $(SYSROOT)) -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1" \
	   ) > $$s/configure.log 2>&1 || { \
	   tail -20 $$s/configure.log >&2; \
	   echo "  FAIL     configure (full log: $$s/configure.log)" >&2; exit 1; }
	@echo "  BUILD    libnl-3 and libnl-genl-3 (-j$(JOBS))"
	@$(MAKE) --no-print-directory -C $(LIBNL_SRC) -j$(JOBS) \
	   lib/libnl-3.la lib/libnl-genl-3.la > $(LIBNL_SRC)/build.log 2>&1 || { \
	   tail -30 $(LIBNL_SRC)/build.log >&2; \
	   echo "  FAIL     libnl (full log: $(LIBNL_SRC)/build.log)" >&2; exit 1; }
	@f=$$(ls $(LIBNL_SRC)/lib/.libs/libnl-3.so.[0-9]*.[0-9]*.[0-9]* | sed -n 1p); \
	 $(call assert_target_elf,"$$f",libnl-3)
	@touch $@

MUSL_INCLUDES = -isystem $(abspath $(SYSROOT))/usr/include

# A cross-build succeeds just as happily having produced something for the
# build host, and nothing downstream would notice until the card did.
#
# The file to read is found by the *shell*, not by $(wildcard): Make expands a
# recipe in full before running any of it, so a wildcard over a file this same
# recipe is about to create expands to nothing and readelf is called with no
# argument at all. That is what it did the first time, and the error it printed
# was readelf's entire --help. Every
# product is read back: aarch64, and - for the programs - pointing at the
# loader the device has. A shared library has no PT_INTERP of its own, so the
# interpreter check is skipped for one.
# $(1) file, $(2) what to call it in a message
define assert_target_elf
	set -e; \
	$(CROSS)readelf -h $(1) | grep -q AArch64 \
	  || { echo "  FAIL     $(2) is not aarch64" >&2; exit 1; }; \
	if $(CROSS)readelf -l $(1) | grep -q INTERP; then \
	  $(CROSS)readelf -l $(1) | grep -q 'ld-musl-aarch64.so.1' \
	    || { echo "  FAIL     $(2) does not use the musl loader" >&2; exit 1; }; \
	fi; \
	echo "  OK       $(2): aarch64, needs $$($(CROSS)readelf -d $(1) | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
endef

# ---------------------------------------------------------------------------
# Step 4 - wpa_supplicant
#
# Built against the libnl above rather than an installed one: libnl's headers
# only appear under a `make install`, which is exactly what is not run, so -I
# points into the unpacked tree and -L at its .libs.
#
# CFLAGS and LIBS reach wpa_supplicant's Makefile through the environment and
# not on the command line, and that distinction is load-bearing: a variable set
# on make's command line cannot be appended to, so `make CFLAGS=...` would
# discard every += in the Makefile - including the ones that add the nl80211
# driver's own flags - and the build would fail in a way that reads like a
# missing header. From the environment, += still works.
#
# The generated .config asks for internal TLS and libtommath so that nothing
# here needs OpenSSL: that covers WPA and WPA2 with a passphrase, which is what
# a Pi on a home or office network needs. WPA3/SAE and EAP-TLS would need a
# real crypto library and are not built.
# ---------------------------------------------------------------------------

WPA_ARCHIVE  = wpa_supplicant-$(WPA_VERSION).tar.gz
WPA_URL      = $(WPA_BASE)/$(WPA_ARCHIVE)
WPA_SUMS     = $(CHECKSUMS)/wpa_supplicant-$(WPA_VERSION).sha256

WPA_SRC   = $(SRC_DIR)/wpa_supplicant-$(WPA_VERSION)
WPA_STAMP = $(WPA_SRC)/.built

WPA_CONFIG ?= CONFIG_DRIVER_NL80211=y CONFIG_LIBNL32=y CONFIG_CTRL_IFACE=y \
              CONFIG_BACKEND=file CONFIG_TLS=internal CONFIG_INTERNAL_LIBTOMMATH=y

.PHONY: wpa_supplicant
wpa_supplicant: $(WPA_STAMP) ## Cross-build wpa_supplicant, wpa_cli and wpa_passphrase
	@echo "  READY    wpa_supplicant $(WPA_VERSION) -> $(WPA_SRC)/wpa_supplicant"

$(WPA_STAMP): $(LIBNL_STAMP) Makefile
	@$(call fetch_recorded,$(DL_SRC),$(WPA_ARCHIVE),$(WPA_URL),wpa_supplicant-$(WPA_VERSION))
	@echo "  UNPACK   $(WPA_ARCHIVE)"
	@rm -rf $(WPA_SRC)
	@mkdir -p $(SRC_DIR)
	@tar -xf $(DL_SRC)/$(WPA_ARCHIVE) -C $(SRC_DIR)
	@printf '%s\n' $(WPA_CONFIG) > $(WPA_SRC)/wpa_supplicant/.config
	@echo "  BUILD    wpa_supplicant $(WPA_VERSION) (-j$(JOBS))"
	@l=$(abspath $(LIBNL_SRC)); \
	 ( cd $(WPA_SRC)/wpa_supplicant && \
	   $(SCRUB_ENV) \
	   CC=$(CROSS)gcc \
	   CFLAGS="-Os $(MUSL_INCLUDES) --sysroot=$(abspath $(SYSROOT)) -I$$l/include" \
	   LIBS="--sysroot=$(abspath $(SYSROOT)) -L$$l/lib/.libs -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1" \
	   $(MAKE) --no-print-directory -j$(JOBS) wpa_supplicant wpa_cli wpa_passphrase \
	 ) > $(WPA_SRC)/build.log 2>&1 || { \
	   tail -30 $(WPA_SRC)/build.log >&2; \
	   echo "  FAIL     wpa_supplicant (full log: $(WPA_SRC)/build.log)" >&2; exit 1; }
	@$(call assert_target_elf,$(WPA_SRC)/wpa_supplicant/wpa_supplicant,wpa_supplicant)
	@touch $@

.PHONY: wifi
wifi: $(LIBNL_STAMP) $(WPA_STAMP) ## Cross-build everything this package ships
	@echo "  READY    libnl $(LIBNL_VERSION) + wpa_supplicant $(WPA_VERSION)"

.PHONY: wifi-info
wifi-info: $(WPA_STAMP) ## Show what was built and what it needs
	@echo "  libnl    $(LIBNL_VERSION)"
	@echo "  wpa      $(WPA_VERSION)"
	@echo "  config   $(WPA_CONFIG)"
	@printf '  needs    %s\n' \
	   "$$($(CROSS)readelf -d $(WPA_SRC)/wpa_supplicant/wpa_supplicant | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# Step 5 - stage the install tree
#
# Neither upstream's `make install` is used, and that is deliberate in both
# cases. libnl's would install the four libraries this build does not compile,
# its headers and its pkg-config files; wpa_supplicant's has no install target
# worth the name - upstream's own README tells you to copy the binaries. So the
# five files that ship are copied by name, which is also the list ../rootfs
# asserts on the other side.
#
# cp -P, not cp: libnl-3.so.200 is a symlink to libnl-3.so.200.26.0 and both
# names matter - the SONAME recorded in wpa_supplicant is the short one, and
# following the link here would ship two copies of the same library under two
# names instead.
#
# The licences travel with them: libnl is LGPL-2.1 and wpa_supplicant is BSD,
# and this ships binaries of both.
# ---------------------------------------------------------------------------

STAGE_DIR   := $(BUILD_DIR)/stage
STAGE_STAMP  = $(STAGE_DIR)/.staged
LICENSE_DIR  = $(STAGE_DIR)$(PREFIX)/share/licenses/wifi

STAGE_CFG := $(STAGE_DIR)/.config
STAGE_SIG  = $(PREFIX)|$(WITH_STRIP)|$(LIBNL_VERSION)|$(WPA_VERSION)
$(eval $(call config_stamp_rule,$(STAGE_CFG),$(STAGE_SIG)))

.PHONY: stage
stage: $(STAGE_STAMP) ## Install the libraries and programs into a staged tree
	@echo "  READY    staged $$(du -sh $(STAGE_DIR) | cut -f1) -> $(STAGE_DIR)"

$(STAGE_STAMP): $(LIBNL_STAMP) $(WPA_STAMP) $(STAGE_CFG)
	@rm -rf $(STAGE_DIR)
	@mkdir -p $(STAGE_DIR)$(PREFIX)/lib $(STAGE_DIR)$(PREFIX)/sbin $(LICENSE_DIR)
	@printf '%s\n' '$(STAGE_SIG)' > $(STAGE_CFG)
	@echo "  INSTALL  $(PREFIX)/lib, $(PREFIX)/sbin"
	@cp -P $(LIBNL_SRC)/lib/.libs/libnl-3.so.[0-9]* \
	       $(LIBNL_SRC)/lib/.libs/libnl-genl-3.so.[0-9]* $(STAGE_DIR)$(PREFIX)/lib/
	@cp $(WPA_SRC)/wpa_supplicant/wpa_supplicant \
	    $(WPA_SRC)/wpa_supplicant/wpa_cli \
	    $(WPA_SRC)/wpa_supplicant/wpa_passphrase $(STAGE_DIR)$(PREFIX)/sbin/
	@cp $(LIBNL_SRC)/COPYING $(LICENSE_DIR)/COPYING.libnl
	@cp $(WPA_SRC)/COPYING $(LICENSE_DIR)/COPYING.wpa_supplicant
ifeq ($(WITH_STRIP),1)
	@$(call strip_stage)
endif
	@touch $@

# Symlinks are skipped by -type f, so each library is stripped once and the
# SONAME link is not broken by the rename strip does internally.
define strip_stage
	set -e; n=0; \
	while read -r f; do \
	  case "$$(od -An -N4 -tx1 "$$f" | tr -d ' ')" in 7f454c46) ;; *) continue;; esac; \
	  $(CROSS)strip "$$f" || { echo "  FAIL     could not strip $$f" >&2; exit 1; }; \
	  n=$$((n+1)); \
	done < <(find $(STAGE_DIR) -type f); \
	echo "  STRIP    $$n files"
endef

.PHONY: stage-check
stage-check: $(STAGE_STAMP) ## Verify every staged file is aarch64 and its libraries are all here
	@$(call assert_stage_elfs)
	@$(call assert_stage_layout)
	@$(call assert_no_libc)
	@echo "  READY    the staged tree needs musl and its own libraries, nothing else"

# The closure check the siblings make is "libc.so and nothing else". This
# package cannot make that claim and should not: wpa_supplicant needs
# libnl-3.so.200 and libnl-genl-3.so.200, which is the whole reason libnl is
# built here rather than somewhere else. So the rule is one step weaker and one
# step stricter - every DT_NEEDED is either the card's libc or a file *in this
# asset*, checked by looking for it - which catches the failure that matters:
# a library that was linked against and then not shipped. ../llvm shipped a
# libc++ needing libatomic.so.1 that nothing provided, and every program on
# that card died at exec.
define assert_stage_elfs
	set -e; n=0; \
	while read -r f; do \
	  case "$$(od -An -N4 -tx1 "$$f" | tr -d ' ')" in 7f454c46) ;; *) continue;; esac; \
	  $(CROSS)readelf -h "$$f" | grep -q AArch64 \
	    || { echo "  FAIL     $$f is not aarch64" >&2; exit 1; }; \
	  if $(CROSS)readelf -l "$$f" | grep -q INTERP; then \
	    $(CROSS)readelf -l "$$f" | grep -q 'ld-musl-aarch64.so.1' \
	      || { echo "  FAIL     $$f does not use the musl loader" >&2; exit 1; }; \
	  fi; \
	  for lib in $$($(CROSS)readelf -d "$$f" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do \
	    case "$$lib" in \
	      libc.so*) ;; \
	      *) [ -e "$(STAGE_DIR)$(PREFIX)/lib/$$lib" ] || { \
	           echo "  FAIL     $$f needs $$lib, which is not in this asset and not the card's libc" >&2; \
	           exit 1; };; \
	    esac; \
	  done; \
	  n=$$((n+1)); \
	done < <(find $(STAGE_DIR) -type f); \
	[ "$$n" -eq 5 ] || { \
	  echo "  FAIL     $$n ELF files in the staged tree, expected 5" >&2; exit 1; }; \
	echo "  OK       5 files: aarch64, musl loader, every library they need is here"
endef

# The SONAME links are what wpa_supplicant actually records, so a tree with the
# versioned files and no links is a tree where nothing starts. -e follows the
# link, which is what is wanted here: it has to resolve *inside* the asset.
define assert_stage_layout
	set -e; s=$(STAGE_DIR); \
	for f in $(PREFIX)/sbin/wpa_supplicant $(PREFIX)/sbin/wpa_cli \
	         $(PREFIX)/sbin/wpa_passphrase \
	         $(PREFIX)/share/licenses/wifi/COPYING.libnl \
	         $(PREFIX)/share/licenses/wifi/COPYING.wpa_supplicant; do \
	  [ -f "$$s$$f" ] || { echo "  FAIL     $$f is missing from the staged tree" >&2; exit 1; }; \
	done; \
	for l in libnl-3.so.200 libnl-genl-3.so.200; do \
	  [ -L "$$s$(PREFIX)/lib/$$l" ] || { \
	    echo "  FAIL     $(PREFIX)/lib/$$l is not a symlink - that is the name recorded in wpa_supplicant" >&2; exit 1; }; \
	  [ -e "$$s$(PREFIX)/lib/$$l" ] || { \
	    echo "  FAIL     $(PREFIX)/lib/$$l points nowhere inside the asset" >&2; exit 1; }; \
	done; \
	echo "  OK       three programs, two libraries with their SONAME links, two licences"
endef

# musl reaching the asset would be a packaging mistake with a long fuse: it
# would install over rootfs's own libc and its loader, and the mismatch would
# only surface as something odd at runtime on the device.
define assert_no_libc
	set -e; \
	found=$$(find $(STAGE_DIR) \( -name 'libc.so*' -o -name 'ld-musl-*' \) -print); \
	if [ -n "$$found" ]; then \
	  echo "  FAIL     musl is in the staged tree; the card's libc comes from Sepia-OS/musl:" >&2; \
	  printf '           %s\n' $$found >&2; exit 1; \
	fi; \
	echo "  OK       no libc, no loader"
endef

.PHONY: stage-info
stage-info: $(STAGE_STAMP) ## Show what the staged tree contains
	@echo "  stage    $(STAGE_DIR)"
	@echo "  size     $$(du -sh $(STAGE_DIR) | cut -f1)"
	@echo "  stripped $(if $(filter 1,$(WITH_STRIP)),yes,no)"
	@find $(STAGE_DIR) \( -type f -o -type l \) ! -name '.staged' ! -name '.config' \
	  | sort | sed "s|$(STAGE_DIR)/|  file     |"

# ---------------------------------------------------------------------------
# Step 6 - the release asset
#
# The staged tree, tarred and compressed: exactly what rootfs unpacks into the
# root filesystem. Sibling repositories consume each other's *published
# releases* rather than each other's build trees, so this is the supported way
# out of here - nothing should read build/ across the filesystem.
# ---------------------------------------------------------------------------

DIST_TAG   ?=
DIST_ASSET  = sepiaos-wifi-$(WPA_VERSION)-aarch64-musl$(if $(DIST_TAG),-$(DIST_TAG)).tar.xz
DIST_SUMS  := SHA256SUMS

.PHONY: dist
dist: $(STAGE_STAMP) ## Pack the staged tree into dist/ as a release asset
	@$(call assert_no_libc)
	@mkdir -p $(DIST_DIR)
	@echo "  PACK     $(DIST_ASSET)"
	@tar -C $(STAGE_DIR) --exclude=./.staged --exclude=./.config -cf - . \
	  | xz -9 -T0 -c > $(DIST_DIR)/$(DIST_ASSET).part
	@mv -f $(DIST_DIR)/$(DIST_ASSET).part $(DIST_DIR)/$(DIST_ASSET)
	@( cd $(DIST_DIR) && $(SHA256) $(DIST_ASSET) > $(DIST_SUMS) )
	@echo "  READY    $$(du -h $(DIST_DIR)/$(DIST_ASSET) | cut -f1) -> $(DIST_DIR)/$(DIST_ASSET)"

.PHONY: dist-info
dist-info: ## Show the packed asset and its digest
	@test -f $(DIST_DIR)/$(DIST_ASSET) \
	  || { echo "No $(DIST_DIR)/$(DIST_ASSET); run 'make dist' first." >&2; exit 1; }
	@echo "  asset    $(DIST_DIR)/$(DIST_ASSET)"
	@du -h $(DIST_DIR)/$(DIST_ASSET) | sed 's/^/  size     /' | cut -f1,2
	@sed 's/^/  sha256   /' $(DIST_DIR)/$(DIST_SUMS)
	@tar -tf $(DIST_DIR)/$(DIST_ASSET) | sort | sed 's|^\./|  contents |'

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove build output (keeps downloads)
	rm -rf $(BUILD_DIR)

.PHONY: distclean
distclean: clean ## Also remove downloaded sources and the toolchain
	rm -rf $(DL_DIR) $(DIST_DIR)

# Read one variable's value, for scripts and CI: make -s print-DIST_ASSET
print-%:
	@echo '$($*)'

.PHONY: help
help: ## Show this help
	@echo "SepiaOS wifi build"
	@echo
	@echo "Targets:"
	@grep -hE '^[a-zA-Z0-9_-]+([ ]+[a-zA-Z0-9_-]+)*:.*?## ' $(MAKEFILE_LIST) \
	  | sed 's/:.*## /|/' \
	  | awk -F'|' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables:"
	@printf "  %-18s %s\n" \
	  "LIBNL_VERSION"    "upstream libnl release (default $(LIBNL_VERSION))" \
	  "WPA_VERSION"      "upstream wpa_supplicant release (default $(WPA_VERSION))" \
	  "MUSL_TAG"         "pin a musl release instead of taking the newest one" \
	  "MUSL_REPO"        "where musl comes from (default $(MUSL_REPO))" \
	  "PREFIX"           "where the package lands on the device (default $(PREFIX))" \
	  "WPA_CONFIG"       "the .config wpa_supplicant is built from" \
	  "CROSS_COMPILE"    "use a musl cross-toolchain you already have" \
	  "WITH_STRIP"       "strip the staged files (default $(WITH_STRIP))" \
	  "DIST_TAG"         "release tag to name the asset after" \
	  "JOBS"             "parallelism for the builds (default $(JOBS))"
	@echo
	@echo "Examples:"
	@echo "  make toolchain-check                 prove the compiler works"
	@echo "  make musl-check                      link C against the fetched sysroot"
	@echo "  make wifi                            cross-build libnl and wpa_supplicant"
	@echo "  make stage-check                     prove the result is shippable"
	@echo "  make MUSL_TAG=v1.2.6 stage           against a specific musl release"
	@echo "  make CROSS_COMPILE=/path/to/aarch64-unknown-linux-musl- wifi"
