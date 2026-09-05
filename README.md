# wifi

This repository builds and provides the `wifi` package for SepiaOS.

The result is **libnl** and **wpa_supplicant** cross-compiled for **aarch64**,
linked dynamically against the musl from
[musl](https://github.com/Sepia-OS/musl), and installed into `/usr/lib` and
`/usr/sbin` on the device. Together they are what turns a Broadcom radio and an
nl80211 driver into a device that can join a network: `wpa_supplicant` speaks
WPA and WPA2, libnl carries it to the kernel.

> The Broadcom **firmware blobs are not here**. They are a download — an
> unpacked Debian package — rather than a build, they are five times the size
> of everything this repository produces, and they are tied to the kernel that
> loads them. [rootfs](https://github.com/Sepia-OS/rootfs) still fetches them.

The sources are the release tarballs from GitHub (libnl) and w1.fi
(wpa_supplicant), pinned to a version and checked against digests recorded in
[checksums/](checksums) — the same two files `rootfs` carried while it built
these itself.

## Prerequisites

`gmake` (GNU Make ≥ 4.0), `curl`, `jq`, `tar` and `xz`.

```sh
brew install make jq xz                       # macOS (13+ already has jq)
sudo apt install make curl jq xz-utils        # Debian / Ubuntu
```

`jq` is needed to read the musl release metadata from the GitHub API. No host C
compiler is needed: everything is compiled by the downloaded cross-toolchain.

> **On macOS, run `gmake`, not `make`.** `/usr/bin/make` is GNU Make 3.81,
> which compares file timestamps only to the whole second and will silently
> reuse a stale object after a fast edit. The Makefile refuses to run on it.

The cross-toolchain is downloaded automatically — messense on macOS, bootlin
on Linux, because no single vendor publishes a musl-targeting aarch64
toolchain for both hosts. Point `CROSS_COMPILE` at one you already have to skip
the download.

## Quick start

```sh
gmake toolchain-check    # prove the compiler builds C against musl
gmake musl-check         # fetch the musl sysroot and link C against it
gmake wifi               # cross-build libnl and wpa_supplicant
gmake stage-check        # prove the result is aarch64 and self-contained
gmake dist               # pack it as a release asset
```

Run `gmake help` for the full list.

## Targets

| Target | What it does |
|---|---|
| `help` | targets and variables (the default goal) |
| `toolchain` | fetch and verify the musl-targeting cross-compiler |
| `toolchain-check` | compile and link C against musl, dynamically and statically |
| `musl` | fetch, verify and unpack the `Sepia-OS/musl` sysroot, plus the Linux UAPI headers |
| `musl-check` | link a test program against that sysroot, both ways |
| `libnl` | cross-build `libnl-3` and `libnl-genl-3` |
| `wpa_supplicant` | cross-build `wpa_supplicant`, `wpa_cli` and `wpa_passphrase` |
| `wifi` | both of the above |
| `stage` | copy the five shipped files into a staged tree and strip them |
| `stage-check` | assert aarch64, the musl loader, and that every library they need is in the asset |
| `dist` | pack the staged tree into `dist/` with `SHA256SUMS` |
| `*-info` | what version, from where, how big |
| `clean` / `distclean` | drop `build/` / also drop `downloads/` and `dist/` |

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `LIBNL_VERSION` | `3.12.0` | upstream libnl release |
| `WPA_VERSION` | `2.12` | upstream wpa_supplicant release |
| `MUSL_TAG` | *(empty)* | pin a `Sepia-OS/musl` release instead of the newest |
| `MUSL_REPO` | `Sepia-OS/musl` | where musl comes from |
| `PREFIX` | `/usr` | where the package lands on the device |
| `WPA_CONFIG` | see `gmake help` | the `.config` wpa_supplicant is built from |
| `CROSS_COMPILE` | *(empty)* | use a musl cross-toolchain you already have |
| `WITH_STRIP` | `1` | strip the staged files |
| `DIST_TAG` | *(empty)* | release tag to name the asset after |
| `JOBS` | host CPUs | parallelism for the builds |

## What ships

Five files, 1.1 MiB staged, **348 KB** compressed:

```
usr/sbin/wpa_supplicant                        the supplicant itself
usr/sbin/wpa_cli                               the control interface client
usr/sbin/wpa_passphrase                        passphrase -> PSK
usr/lib/libnl-3.so.200 -> libnl-3.so.200.26.0
usr/lib/libnl-genl-3.so.200 -> libnl-genl-3.so.200.26.0
usr/share/licenses/wifi/COPYING.libnl          LGPL-2.1
usr/share/licenses/wifi/COPYING.wpa_supplicant BSD
```

Only the two libnl libraries wpa_supplicant actually needs are built — not the
route, xfrm, nf and idiag libraries, the command line tools, or the parser that
wants yacc and flex.

`wpa_supplicant` is built with `CONFIG_TLS=internal` and
`CONFIG_INTERNAL_LIBTOMMATH`, so **nothing here needs OpenSSL**. That covers WPA
and WPA2 with a passphrase, which is what a Pi on a home or office network
needs; WPA3/SAE and EAP-TLS would need a real crypto library and are not built.

**The closure claim is one step weaker than the other packages', and one step
stricter.** `wpa_supplicant` needs `libnl-3.so.200` and `libnl-genl-3.so.200`,
which is the whole reason libnl is built here — so instead of "musl and nothing
else", `stage-check` asserts that every `DT_NEEDED` of every shipped file is
either the card's libc *or a file in this asset*. That catches the failure that
matters: a library linked against and then not shipped.

musl itself is deliberately **not** in the asset: the device's libc comes from
`Sepia-OS/musl`, and a second copy on the card is two libcs disagreeing.

A local build produces `dist/sepiaos-wifi-<wpa version>-aarch64-musl.tar.xz`
and its `SHA256SUMS`, which is what `rootfs` unpacks into the root filesystem —
siblings consume each other's published releases, never each other's build
trees.

```sh
sha256sum -c SHA256SUMS
tar -C / -xf sepiaos-wifi-2.12-aarch64-musl.tar.xz
```
