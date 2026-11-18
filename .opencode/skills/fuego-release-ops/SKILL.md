---
name: fuego-release-ops
description: Fuego Valise release channel operator — status, triage, and shipping for the 9 GitHub workflows (desktop CI, mobile CI, macOS, iOS, Android Play Store, F-Droid, Flatpak, Snap, App Store). Use when checking release status, a release workflow is stuck or red, cutting a release, tagging, or deciding which channels ship a version — covers trigger types, secrets, and per-channel gotchas from ANDROID_RELEASE_SETUP.md and IOS_DEVELOPMENT_SETUP.md.
---

# Fuego Release Ops

Release surface = 9 workflows. Two are continuous (CI), seven are release channels with different triggers.

## Workflow map

| Workflow | Trigger | What it ships | Manual input |
|---|---|---|---|
| `fuego-wallet-ci.yml` | push/PR → master | analyze (flutter analyze + format + test/coverage), macOS build, Linux build | — |
| `fuego-wallet-mobile-ci.yml` | push/PR → master | Android + iOS native builds (cargo ndk both Rust crates) | — |
| `macos-release.yml` | `workflow_dispatch` | macOS app → release | `version` |
| `appstore-release.yml` | **release published** + dispatch | App Store | — |
| `android-playstore-release.yml` | `workflow_dispatch` | Play Store | `version` |
| `ios-release.yml` | `workflow_dispatch` | TestFlight/App Store Connect | `version` |
| `fdroid-release.yml` | `workflow_dispatch` | F-Droid | `version` |
| `linux-flatpak-release.yml` | `workflow_dispatch` | Flathub/flatpak | `version` |
| `linux-snap-release.yml` | `workflow_dispatch` | Snap Store | `version` |

Key asymmetry: **App Store releases fire automatically on GitHub release publish; everything else needs `workflow_dispatch` with the version string.** Cutting a release and only seeing App Store move is not a failure — dispatch the other six by hand.

## Cutting a release (canonical order)

1. Desktop CI + mobile CI must be green on master first (they gate nothing downstream automatically — check manually).
2. Tag + publish the GitHub release → App Store workflow fires on its own.
3. Dispatch the manual ones, passing the same `version` input: `gh workflow run macos-release.yml -f version=vX.Y.Z` (repeat for android-playstore, ios, fdroid, linux-flatpak, linux-snap).
4. Watch with `gh run watch` or `gh run list --workflow=<name>`.

## Status / triage commands

```bash
gh run list --limit 20                                   # recent runs across workflows
gh run list --workflow=fuego-wallet-ci.yml --limit 5
gh run view <run-id> --log-failed                        # failed step logs
gh release list --limit 5
```

## Per-channel gotchas (from the setup docs)

- **Android / Play Store / F-Droid**: signing + keystore config; see `ANDROID_RELEASE_SETUP.md`. F-Droid additionally tracks tags differently — read the doc before "just re-running".
- **iOS / App Store**: certificates, provisioning profiles, Xcode selection; see `IOS_DEVELOPMENT_SETUP.md`. macOS builds must select the full Xcode (`sudo xcode-select -s /Applications/Xcode.app/...`), not the CLT.
- **macOS bundle rule**: `fuegod` and `xfg-swapd` are REQUIRED in the bundle — CI fails the build rather than shipping a local-mode-broken app. If the optional `unified` (PaymentGateService) build fails, that's `continue-on-error` and fine.
- **Flutter pin**: 3.44.4 everywhere (CI, snapcraft.yaml, flatpak). Bump all of them together or releases drift.
- **Runner pin**: ubuntu-22.04 (glibc 2.35) for CI; release workflows carry their own pins — keep consistent when touching CI.
- **linux-snap / linux-flatpak**: snapcraft.yaml and flatpak/com.fuego.fuego_wallet.yml are the sources of truth for store metadata and runtime versions.

## Local-mode regression check before shipping desktop

The bundle step in `fuego-wallet-ci.yml` already enforces fuegod + xfg-swapd presence. What it cannot check: that the Rust `fuego_walletd` build actually succeeded from `rust-fuego-wallet/core` (the workspace copies binaries around — see the cp fallback in the workflow). When triaging a failed macOS/Linux build, the failure is usually in the xfgo (fuego-suite) clone+cmake step: `Daemon` target failure is fatal, `PaymentGateService` failure is tolerated.

## Rust gate context

As of Sep 2026, CI runs `cargo test` + build for the SDK crates and a binding-consistency check (see the `rust-sdk` job in `fuego-wallet-ci.yml`), plus non-blocking clippy. If the binding-consistency job fails, a Dart FFI lookup points at a symbol the Rust side no longer exports — fix the Rust export, not the check. Operator background for that surface lives in the `fuego-ffi-bridge` skill.
