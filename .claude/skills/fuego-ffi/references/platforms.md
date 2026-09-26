# libfuego_ffi per platform

Read this when a build, bundle or load step fails, or when adding a crate,
a C source or a system library that changes how the library links.

| Platform | Artifact | Built by | Ends up at | Dart loads with |
|---|---|---|---|---|
| macOS | `libfuego_ffi.dylib` (cdylib) | `.github/actions/build-desktop-backends` copies it to `macos/Runner/` | `Contents/Frameworks/` via Xcode's "Bundle Framework" copy phase | `DynamicLibrary.open` over candidate paths, `Frameworks/` first |
| Linux | `libfuego_ffi.so` (cdylib) | `build-desktop-backends` → `backends/` | `<bundle>/lib/libfuego_ffi.so` via `bundle-desktop-backends` | `DynamicLibrary.open('<exe dir>/lib/libfuego_ffi.so')`, falling back to the bare name |
| Android | `libfuego_ffi.so` per ABI (cdylib) | `.github/actions/build-android-natives` (cargo-ndk, `--platform 25`, 16 KB pages) | `android/app/src/main/jniLibs/<abi>/` | `DynamicLibrary.open('libfuego_ffi.so')` |
| iOS | `libfuego_ffi.a` (staticlib) | `cargo build -p fuego-ffi --target <triple>` | linked into the Runner binary | `DynamicLibrary.process()` |
| Windows | `fuego_ffi.dll` | **nothing**; no workflow builds it | — | `DynamicLibrary.open('fuego_ffi.dll')` |

## macOS

- `macos/Runner/libfuego_ffi.dylib` is gitignored and is built, never
  committed. A committed copy went stale once and shipped old crypto. For
  local builds, `scripts/build-and-run.sh` builds it.
- The Xcode project references the file by name, so a missing dylib fails
  the Xcode build at the copy phase, not at runtime.
- `scripts/bundle-macos-dylibs.sh` handles the C++ daemons' Homebrew
  dylibs. It does not touch `libfuego_ffi`. `bundle-desktop-backends`
  asserts `Contents/Frameworks/libfuego_ffi.dylib` exists.
- Signing: `scripts/sign-macos-app.sh <app> <identity>` signs
  `Contents/MacOS/*`, then `Contents/Frameworks/*`, then the app. After
  any `install_name_tool` edit to the dylib, re-sign it.

## Linux

- The executable is `fuegowallet` (`BINARY_NAME` in `linux/CMakeLists.txt`); "Fuego Valise"
  is only the display name. The `fuego-valise` symlink is the launch name for the
  `.desktop` `Exec`, snap and flatpak. FFI loading uses
  `Platform.resolvedExecutable`, which resolves the symlink.
- The flatpak (`flatpak/com.fuego.fuego_wallet.yml`) and the snap
  (`snap-root` layout) both keep the bundle's `lib/` directory. If a
  packaging change moves `lib/`, the fallback bare-name `dlopen` will fail
  unless the directory is on the loader path.

## Android

- Four ABIs: `arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`. A missing ABI
  crashes only on devices of that ABI. Check
  `unzip -l app-release.apk | grep libfuego_ffi` shows all four.
- `useLegacyPackaging = true` in `android/app/build.gradle` exists for
  `libfuego_walletd.so` (a spawned executable that must be extracted).
  It is harmless for the FFI library.
- Mobile CI, `android-playstore-release.yml` and `fdroid-release.yml` all
  use `.github/actions/build-android-natives`. It builds `libfuego_ffi.so`
  and `fuego_walletd` for four ABIs with
  `-Wl,-z,max-page-size=16384`, then fails if any `LOAD` segment is not
  `0x4000`-aligned or `fuego_mine_share` is not exported. Android 15+
  devices with 16 KB pages refuse 4 KB-aligned libraries.
- CryptoNight on Android takes the portable path (no ARM crypto
  extension in the NDK default). See `cryptonight.md`.

## iOS

- The app cannot load a loose `.dylib` (App Store rejects it, and the
  sandbox forbids it), so the staticlib is linked into Runner. In
  `ios/Runner.xcodeproj/project.pbxproj`, all three Runner configs
  (Debug, Release, Profile) set:
  - `OTHER_LDFLAGS[sdk=iphoneos*]` → `-force_load
    $(PROJECT_DIR)/../rust-fuego-wallet/target/aarch64-apple-ios/release/libfuego_ffi.a`
  - `OTHER_LDFLAGS[sdk=iphonesimulator*][arch=arm64]` → `aarch64-apple-ios-sim`
  - `OTHER_LDFLAGS[sdk=iphonesimulator*][arch=x86_64]` → `x86_64-apple-ios`
  - each followed by `-Xlinker -export_dynamic`
  - `STRIP_STYLE = non-global`
- Why `-force_load`: nothing in Runner's Objective-C/Swift references the
  `fuego_*` symbols, so a plain link would drop every object file. Dart
  looks them up at runtime, which the linker cannot see.
- Why `-export_dynamic`: `-force_load` pulls the objects in, but release
  links dead-strip, and ld64 does not treat a main executable's global
  symbols as roots, so unreferenced `fuego_*` functions are removed. The
  first CI archive built with only `-force_load` had none of them.
- Why `STRIP_STYLE = non-global`: release builds strip symbols.
  `DynamicLibrary.process()` resolves through `dlsym`, which needs the
  global `fuego_*` symbols to survive stripping. Symptom when this is
  wrong: `Failed to lookup symbol 'fuego_…'` in release builds only,
  while debug builds work.
- The Runner build phase "Build fuego-ffi" runs `scripts/build-ios-ffi.sh`,
  which builds the `.a` for the SDK/arch being built (and unsets Xcode's
  `SDKROOT` so Cargo's host build scripts don't link against the iOS SDK).
  Needs Rust with `aarch64-apple-ios`, `aarch64-apple-ios-sim` and
  `x86_64-apple-ios` installed. "cargo not found" means Rust is missing.
- Check the result with `scripts/check-ios-ffi-symbols.sh <Runner | .xcarchive | .ipa>`.
  Stripping happens on archive/install (`DEPLOYMENT_POSTPROCESSING`), and
  the export can strip again (`stripSwiftSymbols`), so a plain
  `flutter build ios` output proves little. Both release workflows run
  the script on the xcarchive and on the exported IPA.
- `ios-release.yml` maps `IOS_P12_BASE64` and `APPSTORE_ISSUER_ID` from
  secrets into the job `env`. Its `if: env.… != ''` gates depend on
  that; without the mapping every signing and archive step skipped.
- A new Rust dependency that needs a system framework (for example
  `Security` for Keychain) needs `-framework <Name>` added to the same
  `OTHER_LDFLAGS` entries, because the staticlib does not carry link
  directives the way a dylib does.
- `fuego_walletd` does not run on iOS at all. See
  `docs/IOS_WALLETD_FFI_SCOPE.md`.

## Windows

`fuego_native.dart` loads `fuego_ffi.dll` from the DLL search path, but
no workflow builds it and nothing in `windows/` bundles it. Treat Windows
FFI as unimplemented, not merely untested. Wiring it needs:
- a `cargo build -p fuego-ffi` step on a Windows runner (MSVC target)
- compiling the suite CryptoNight C there (`build.rs` passes `-maes`,
  which is GCC/Clang only)
- copying the `.dll` next to the `.exe` in the Flutter Windows bundle
