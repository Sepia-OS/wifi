# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

**The build is implemented and green end to end.** [Makefile](Makefile) fetches the musl sysroot from `Sepia-OS/musl`, cross-builds libnl and wpa_supplicant against it, and packs the five shipped files as a release asset. Verified on macOS/arm64 against messense GCC 15.2.0 and musl 1.2.6: 1.1 MiB staged and stripped, a **348 KB** `dist/sepiaos-wifi-2.12-aarch64-musl.tar.xz`, `wpa_supplicant` needing `libnl-3.so.200`, `libnl-genl-3.so.200` and `libc.so` — all three satisfied.

**That is a layout and linkage proof, not a behavioural one**, and here that gap is wider than in the sibling repositories: nothing has associated with an access point. `../rootfs` can drive `wpa_supplicant -v` and a `mac80211_hwsim` radio under QEMU, which is the furthest anything in this project has got; whether a real Pi joins a real network is a question only a real Pi can answer.

What does not exist yet: a published release, and therefore a consumer. `../rootfs` is written to fetch this asset instead of building libnl and wpa_supplicant itself.

## Commands

```sh
gmake help                  # every target, with the variables that steer them
gmake toolchain-check       # compile and link C against musl, both ways
gmake musl-check            # fetch the musl sysroot and link against it
gmake wifi                  # cross-build libnl and wpa_supplicant
gmake stage-check           # aarch64, musl loader, every needed library present
gmake dist                  # dist/sepiaos-wifi-<version>-aarch64-musl.tar.xz
gmake <thing>-info          # what version, from where, how big
gmake clean                 # drop build/, keep downloads/
gmake -s print-DIST_ASSET   # read any variable's value
```

**A full build with no toolchain in `downloads/` fetches a few hundred MiB.** To iterate without that, point `CROSS_COMPILE` at a toolchain a sibling already extracted — this is how the build was verified:

```sh
gmake CROSS_COMPILE=../llvm/downloads/toolchain/messense-15.2.0-aarch64-darwin/bin/aarch64-unknown-linux-musl- stage-check
```

`stage-check` is the fast regression gate: about 15 s for libnl plus wpa_supplicant on an 8-core machine, once the musl sysroot is unpacked.

## What This Repository Is For

SepiaOS is an operating system for Raspberry Pi that reuses the kernel and firmware from Raspberry Pi OS; everything above the kernel is custom. Targets: Pi Zero 2 W, Pi 3, Pi 4, Pi 5, CM4, CM5.

The repositories are checked out side by side and opened together via [../SepiaOS.code-workspace](../SepiaOS.code-workspace). Each pushes to `git@github.com:Sepia-OS/<name>.git`:

| | |
|---|---|
| [../boot](../boot) | the FAT boot partition — complete, released, CI'd. The clearest model of the house style. |
| [../musl](../musl) | musl libc, published as a sysroot. Everything here links against it. |
| [../rootfs](../rootfs) | the ext4 root filesystem and the bootable image. It assembles what the others publish. |
| [../llvm](../llvm) | clang/lld cross-built to run *on* the Pi. |
| [../make](../make) | GNU `make`, the same way. |
| [../e2fsprogs](../e2fsprogs) | the filesystem tools, the same way. |
| [../spm](../spm) | the SepiaOS package manager, in Rust. Early. |
| `.` (this repo) | the wifi userspace: libnl and wpa_supplicant. |

This was step 5 of `../rootfs` until it was extracted here. That repository now builds exactly two things from source — busybox and the image itself — and fetches everything else.

## Decisions Already Taken

Each of these was open when the Makefile was written, and each is settled with evidence. Do not re-open them without new evidence.

- **The firmware stays in `../rootfs`.** The Broadcom blobs are a download — `ar x` over a Debian package — not a build; they are 4.5 MiB against this package's 1.1 MiB; and they are tied to the kernel that loads them, which is `../boot`'s business rather than this one's. Moving them here is defensible and would make `WITH_WIFI` a single fetch on the other side; it is not what "extract the build of wpa_supplicant and libnl" asked for.
- **musl comes from the `Sepia-OS/musl` release, not from source.** `../llvm`, `../make` and `../e2fsprogs` each build their own copy of the musl sources purely to have something to link against. This repository is the first package to consume the release instead, which is the direction `../rootfs` moved in: one repository owns the libc, one release names it, and "built against musl 1.2.6" stops being a claim three Makefiles have to keep true independently.
- **Only two libnl libraries are built.** libnl also ships route, xfrm, nf and idiag libraries, a set of command line tools and a parser that wants yacc and flex. None of it is on the path from a passphrase to an association. `make lib/libnl-3.la lib/libnl-genl-3.la` is the whole build.
- **No OpenSSL.** `CONFIG_TLS=internal` plus `CONFIG_INTERNAL_LIBTOMMATH` covers WPA and WPA2 with a passphrase. WPA3/SAE and EAP-TLS would need a real crypto library, a much larger asset, and a second thing to keep patched.
- **The five shipped files are copied by name, not installed.** libnl's `make install` would install the four libraries this build does not compile, its headers and its pkg-config files; wpa_supplicant has no install target worth the name — upstream's own README says to copy the binaries.

## Non-Obvious Constraints

All established by running the build, and each one silently produces a broken or confusing result if violated:

- **`$(wildcard)` in a recipe expands before the recipe runs.** Make expands a recipe in full before executing any line of it, so a wildcard over a file that the *same recipe* is about to create expands to nothing. `assert_target_elf` was first called with `$(firstword $(wildcard .../libnl-3.so.*))`, which passed `readelf -h` no argument at all — and the error was readelf's entire `--help` output followed by "libnl-3 is not aarch64". The library is found by the shell now, with `ls | sed -n 1p`.
- **`gmake -n` is not a syntax check here.** Make runs any recipe line containing `$(MAKE)` even under `--dry-run`, so a dry run of `wifi` really tries to build libnl and fails on a directory that does not exist yet. Use `gmake help` to check that the file parses.
- **`cp -P`, never plain `cp`, for the libraries.** `libnl-3.so.200` is a symlink to `libnl-3.so.200.26.0`, and the *short* name is what wpa_supplicant records as `DT_NEEDED`. Following the link would ship two copies of the same library under two names, and the SONAME link — the one that is actually loaded — would be missing.
- **CFLAGS and LIBS reach wpa_supplicant's Makefile through the environment, not the command line.** A variable set on make's command line cannot be appended to, so `make CFLAGS=...` would discard every `+=` in that Makefile — including the ones that add the nl80211 driver's own flags — and the build fails in a way that reads like a missing header.
- **wpa_supplicant is built against the *unpacked* libnl, not an installed one.** libnl's headers only appear under a `make install`, which is exactly what is not run, so `-I` points into the source tree and `-L` at its `.libs`.
- **`YACC=false FLEX=false` is not a way of saying "not installed".** libnl's configure finds bison if the host has it and then builds the route library's address parser with it. Pointing both at `false` keeps a developer's machine from building something a slim container cannot.
- **pkg-config is absent from `debian:trixie-slim` and libnl's configure insists on one.** Nothing here has a pkg-config dependency to resolve — the only library involved is the musl in the sysroot — so the recipe writes a five-line stub that answers the version question and refuses everything else. Installing a tool whose whole job would be to say "no" is worse.
- **The closure rule is different from every sibling's.** They assert "libc.so and nothing else"; this package cannot and should not. `assert_stage_elfs` asserts instead that every `DT_NEEDED` is either the card's libc *or a file in this asset*, checked by looking for it. That is what catches a library linked against and then not shipped — the `libatomic.so.1` failure `../llvm` shipped once, where every program on the card died at exec.
- **The file count is asserted, not just the contents.** Five ELF files: three programs and two libraries. A staged tree with four is a build that quietly dropped something.

## The Toolchain

Read out of `../llvm/Makefile`, where it was established by experiment. Do not "simplify" it:

- **It differs by build host** — messense publishes darwin-hosted builds only, bootlin (Buildroot) publishes Linux-hosted x86_64 builds only. Both are fetched by one recipe differing only in `TC_PREFIX`, `TC_ARCHIVE`, `TC_URL` and `TC_SUMS`, with `CROSS_COMPILE` as the escape hatch.
- **It must be the musl-targeting variant**, and `assert_cross_compiler` refuses a gnu one outright: these are programs, and a gnu toolchain would link them against glibc. (`../musl` accepts a gnu compiler, because a libc links against no libc. Do not copy that leniency here.)
- **`aarch64-unknown-linux-musl` is pinned, not inherited.** The vendors disagree — bootlin's compiler calls itself `aarch64-buildroot-linux-musl`.
- **Binaries built on macOS and on Linux are not byte-identical**, so macOS is the development host and release builds are cut on Linux.

## Conventions Inherited

Verified across `../boot`, `../rootfs`, `../llvm`, `../make`, `../e2fsprogs` and `../musl`, and followed here:

- **`gmake`, not `make`.** Hard error below GNU Make 4.0.
- **Nothing needs root**, on macOS or Linux.
- **Directory split:** `downloads/` (immutable upstream artifacts, survive `clean`), `build/` (everything generated, including the unpacked sources), `dist/`, `checksums/`.
- **A variable override touches no file, so Make cannot see it.** Hence the `FORCE` + `cmp -s` signature stamps.
- **Target naming:** an aggregate goal named after the product, plus `<thing>-info` and `<thing>-check`. Every aggregate goal ends with a `READY` line whether or not anything was rebuilt.
- **The `help` target's grep pattern allows digits and underscores**, or `wpa_supplicant` and `libnl` would not appear in it.
- **`print-%` exposes any variable to CI**, which makes the names it is called with a CI contract: `DIST_ASSET`, `LIBNL_VERSION`, `WPA_VERSION`, `TARGET_TRIPLE`, `TC_VENDOR`, `TC_VERSION`.
- **`.SHELLFLAGS := -eu -o pipefail`.** A pipeline ending in `head` SIGPIPEs its producer and **fails after printing the right answer**, which is why the library name is read with `sed -n 1p`.
- **Noisy tools log to a file and only their tail surfaces on failure** (`configure.log`, `build.log`). CI must upload those or a failure is 30 lines out of thousands.
- **The `.gitignore` deliberately omits the stock toptal C/C++ section.** Its `*.d` pattern also matches *directories* named `*.d`, which is how `../rootfs` silently failed to commit `overlay/etc/init.d`.
- **Apache 2.0** for this repository; libnl is LGPL-2.1 and wpa_supplicant is BSD, and both licences ship inside the release asset.
- **`README.md` is the specification and stays in sync.** Changing a target, a variable or a default means updating it in the same change.

## CI and Releases

Both files are the `../musl` pair with the names changed; `../boot/docs/CI.md` is the full reasoning:

- **`ci.yml` builds on every commit on every branch and every PR against `main`**, in `debian:trixie-slim`. The build is well under a minute, so there is no reason to narrow it.
- **The package list needs `jq`** — the musl release is resolved over the GitHub API — and deliberately no compiler: everything is built by the downloaded cross-toolchain.
- **Build tools go in *before* `actions/checkout`.** Without `git` in the container, checkout silently degrades to a tarball download.
- **Every product goal must reach the toolchain download by itself.** `../musl`'s first release build failed on exactly this: `ci.yml` runs `make toolchain` as its first step and a development machine passes `CROSS_COMPILE`, so nothing exercised the path where a single goal has to pull the toolchain in. Here `$(LIBNL_STAMP)` lists `$(TOOLCHAIN_DEP)` and `$(MUSL_STAMP)` does too.
- **Reproduce the release job in a container before cutting a release.** It is the only path that starts from nothing and asks one goal to pull the whole build in behind it. `--platform linux/amd64` is not optional — bootlin publishes x86_64-hosted toolchains only — and the tree is copied in with `docker cp` rather than bind-mounted, per the Docker Desktop permission failure `../rootfs` records.
- **Releases are never automatic.** Manual `workflow_dispatch` takes a version; a `gate` job validates it, resolves `main`'s head **once**, refuses a commit with no green CI run for that exact commit, and branches `main` to `rel-<version>`; `build` runs on that branch; `rollback` deletes it if the build fails.
- **`inputs.version` reaches bash through `env:`, never `${{ }}` interpolation into a script line.** Validate against `^[0-9][0-9A-Za-z.+-]*$`.
- **The release body is an interface.** `../rootfs` mines `| wpa_supplicant | \`2.12\` |` and `| libnl | \`3.12.0\` |` out of it. Restyling the notes breaks a consumer.
- Only the publishing job gets `contents: write`; `GITHUB_TOKEN` is the only credential needed.

## Build Environment

The user develops on **macOS** (`darwin`) with the repositories under `~/Projects/RaspberryPi/SepiaOS/`.

- **`gmake` (`brew install make`)**, not `/usr/bin/make`.
- Required tools: `gmake`, `curl`, `jq`, `tar`, `xz`. Notably not a host C compiler, and not pkg-config.
