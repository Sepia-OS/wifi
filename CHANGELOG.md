# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases are named after the **upstream wpa_supplicant version** they package:
`v2.12` is wpa_supplicant 2.12 with the libnl it needs, cross-built to run on
the Raspberry Pi.

## [Unreleased]

## [2.12] - 2026-09-05

### Added

- The whole build, extracted from `rootfs` so that one repository owns it:
  fetch libnl and wpa_supplicant, verify both against the digests committed in
  `checksums/`, cross-build them against the musl release and pack the five
  files that ship.
- The musl sysroot comes from the `Sepia-OS/musl` **release** rather than being
  built here — the first package repository in the family to consume it that
  way.
- Only the two libnl libraries wpa_supplicant needs are built (`libnl-3`,
  `libnl-genl-3`), not the route, xfrm, nf and idiag libraries, the command
  line tools, or the parser that wants yacc and flex.
- `wpa_supplicant` is built with `CONFIG_TLS=internal` and
  `CONFIG_INTERNAL_LIBTOMMATH`, so nothing here needs OpenSSL. That covers WPA
  and WPA2 with a passphrase.
- `stage-check`, whose closure rule is one step weaker and one step stricter
  than the family's: every `DT_NEEDED` has to be either the card's libc **or a
  file in this asset**, and there have to be exactly five ELF files.
- CI on every commit and branch, and a manual release workflow.

### Notes

- `cp -P`, never plain `cp`, for the libraries: `libnl-3.so.200` is a symlink
  to `libnl-3.so.200.26.0` and the short name is what wpa_supplicant records as
  `DT_NEEDED`.
- The Broadcom firmware is deliberately **not** here. It is a download rather
  than a build, four times the size of this package, and tied to the kernel
  that loads it; `rootfs` still fetches it.

[Unreleased]: https://github.com/Sepia-OS/wifi/compare/v2.12...HEAD
[2.12]: https://github.com/Sepia-OS/wifi/releases/tag/v2.12
