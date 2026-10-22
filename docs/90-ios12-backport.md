# 90 — The iOS 12.2 backport

Upstream Husk ships for iOS 15.5 and later. This document records the backport
that takes the same source tree down to **iOS 12.2** — AltStore's floor, and so
the oldest iOS a sideloader install can reach.

Nothing here is a fork: the tree still builds 15.5+ exactly as before. One IPA
serves every version, and which half of it runs is decided at launch.

## What runs where

| | iOS 12.2 – 14.4 | iOS 15 and later |
|---|---|---|
| Entry point | `HuskAppDelegate` (`@UIApplicationMain`) | same |
| Interface | `LegacyRootViewController` — UIKit, `src/app/LegacyUI` | `ContentView` in a `UIHostingController`, as upstream |
| Old prototype loader (CPU framebuffer) | yes | yes |
| Native runtime (Unity, cocos2d-x, Minecraft, SDL, Unreal, Godot, GTA, GameMaker, Java, Flutter) | no — `CAMetalLayer` is iOS 13+ | yes |
| Web apps (Capacitor, Cordova) | no — the WKWebView bridge is iOS 15+ | yes |
| Full Android (QEMU guest) | no — display and RAM budget are iOS 13+ | yes |
| PS4 layer | no — iOS 17.4+ | where it was |
| JIT | debugger attach or jailbreak (below) | as upstream |

The split is a *runtime* decision in `didFinishLaunching`, not a build flag. The
SwiftUI screens are annotated `@available(iOS 15.0, *)` wholesale (see below) and
are never touched on older systems; the legacy shell is deliberately
SwiftUI-free and Combine-free, and shares only the plain model types
(`TLApp`, `TLReport`, `TranslationLayer`, `BundleUnpacker`, `HuskLog`,
`JITBootstrap`, `TLScreenUIView`), none of which carry an availability
annotation.

## Why the SwiftUI layer is annotated 15.0 and not 13.0

Upstream targets 15.5, so iOS 15 APIs (`foregroundStyle`, `.background(_:in:)`,
`AnyShapeStyle`, `Date.FormatStyle`, …) are used without guards — they compile
because the deployment target already covers them. iOS 16 APIs *are* guarded,
through the stand-ins in `Compat15.swift` (`LabeledContent`,
`NavigationStack`, `huskNavigationBar`, …).

Dropping the deployment target to 12.2 makes every one of those unguarded iOS 15
uses a compile error, and guarding them one by one is not a change that can be
made safely without a compiler in the loop. The backport therefore annotates
each top-level declaration that uses a newer API with `@available(iOS 15.0, *)`
— 226 of them, inserted mechanically and then cross-checked. Inside such a
declaration the floor is 15.0, so:

* iOS 13/14/15 APIs are simply available — nothing else to do;
* iOS 16/17 APIs keep the `if #available(iOS 16, *)` guards upstream already
  wrote, which still work above the new floor.

The one structural consequence: a declaration annotated 15.0 cannot be
referenced from one annotated lower, so the annotation had to be applied
transitively across the whole SwiftUI call graph. That is why the SwiftUI UI as
a whole is iOS 15+ rather than 13+, and why iOS 13/14 devices — which could not
install upstream at all — get the legacy shell rather than a stripped SwiftUI.

`SaveBackup.swift` is the one file kept *un*annotated on purpose: it is plain
Foundation, and `Date().formatted(.iso8601…)` was replaced with a `DateFormatter`
so it stays available to the legacy shell.

## The legacy shell (`src/app/LegacyUI`)

Eight files, UIKit only:

| file | what it is |
|---|---|
| `LegacyCompat.swift` | colours, label/button/scroll factories, banners |
| `LegacyStore.swift` | mirrors `TranslationLayerStore.load`'s folder scan; import/remove/mark-played; runnability (`canRunOnThisiOS`/`unavailableReason`) |
| `LegacyAttemptRunner.swift` | `husk_tl_attempt_*` on a DispatchQueue, 10 Hz status polling |
| `LegacyRootViewController.swift` | three tabs: Library, JIT, Settings |
| `LegacyLibraryViewController.swift` | the app list, `+` imports through `UIDocumentPickerViewController` |
| `LegacyJITViewController.swift` | live JIT state, and the two routes below |
| `LegacyGameViewController.swift` | full-screen `TLScreenUIView` for a running app |
| `LegacySettingsViewController.swift` | about, what works, log viewer, issue link |

Tabs are text-only because SF Symbols is iOS 13+. The document picker uses the
iOS 8 `documentTypes:` spelling rather than `UTType`.

## JIT on iOS 12.2

StikDebug is iOS 17.4+, TrollStore is iOS 14+, StikJIT is iOS 26+. None of the
usual routes exist. What does:

1. **Debugger attach.** A debugged process (CS_DEBUGGED) can map its own RWX→RX
   region on any pre-TXM iOS, which is every iOS 12 device. From a Mac:
   `ios-deploy --debug --bundle Husk.app` (Cydia Impactor installs it, then
   `ios-deploy` attaches), or on a jailbroken device
   `debugserver 0.0.0.0:1234 --attach=<PID>` plus `lldb -s` from the computer.
   The app does not detach you; the region stays mapped.
2. **Jailbreak.** `husk_self_dual_mapping()` in `husk-ios-jit.c` tries the
   self-granted route when the process is marked debugged *or* a jailbreak is
   detected. The iOS 12 backport added the rootful markers (`/Applications/Cydia.app`,
   Sileo, Zebra, `/bin/bash`, `/usr/sbin/sshd`, `/etc/apt`,
   `/Library/MobileSubstrate`) beside `/var/jb`, because every iOS 12 jailbreak
   is rootful and leaves no `/var/jb`.

The JIT tab shows which route is live (`debuggedFlag`, `isJailbroken`, `ready`,
`mapJITWorks`) and walks through both. `jitBytes` is capped at a quarter of
physical RAM (floor 128 MiB) because the phones that run iOS 12 have 1–2 GB.

## Build

Mac only, as upstream — or GitHub Actions, see below.

### Toolchain: Xcode 16.4, not 26

Build with **Xcode 16.4** (Swift 6.1, iOS 18.4 SDK). This is not a preference:
binaries produced by Xcode 26 install on an iOS 12 device but **abort at launch,
before `didFinishLaunchingWithOptions`** — Apple feedback thread 829511, same
project and deployment target, launches fine from Xcode 16 — and Xcode 26
refuses deployment targets below 15 in the first place. GitHub's `macos-15`
runner image carries 16.4 as its default Xcode; the workflow selects it
explicitly so a future image default cannot silently regress the IPA.

Three consequences of 16.4, all already applied:

* `nonisolated(unsafe)` (Swift 6.2) is stripped from the seven files that used
  it (28 declarations). Plain `nonisolated` and `static var` compile under
  Swift 5 language mode, which is what `project.yml` sets
  (`SWIFT_VERSION: "5.0"`); the mutable statics emit at most a warning.
* `HuskJITHelper`'s deployment target moved 26.0 → 18.4: Xcode 16.4 rejects a
  target above its SDK version. The helper is only ever launched by the iOS 26
  StikJIT flow (`JITBootstrap` gates it there), so behaviour is unchanged.
* `libFilePickerFix.dylib` — the only prebuilt binary the app **links** at
  launch — declared `LC_BUILD_VERSION` min 15.0.0, which dyld on iOS 12 refuses
  whatever the app's own target says. Its min is patched to 12.2.0 in
  `src/app/Frameworks/` (the binary references only `NSURL` and
  `UIDocumentPickerViewController`, both iOS 8 era). `package_ipa.sh` re-signs
  it ad hoc, so the invalidated signature is regenerated at package time.

The dependency cross-compiles (`QEMU`, `ANGLE`, `MoltenVK`, `libqemu-*`) pass
`-miphoneos-version-min=12.2` / `IPHONEOS_DEPLOYMENT_TARGET=12.2`
(`scripts/build_ios.sh`'s `SDKMINVER`, `build_angle_ios.sh`,
`build_rppairing_ios.sh`), for the same dyld reason. Two escape hatches exist
because not every dependency's floor is known:

* **ANGLE**: `ci_build.sh` builds it for 12.2 and, if WebKit's current revision
  will not, retries at 15.5 (`ANGLE_MINVER=15.5`). Harmless: the dylib is
  embedded but never linked, and the only dlopen is the guest GL path, which
  the iOS 12.2 backport never reaches.
* **PS4 layer**: its sources (Bachata-S4 branch `husk`, husk-fex branch
  `husk-fex`) are private trees and it is iOS 17.4+ only, so `ci_build.sh`
  compiles a stub `libhuskps4.dylib` when the real one is absent — the app
  embeds it without linking and opens it by path only on 17.4+. A Mac with the
  trees builds the real one (`scripts/build_ps4_ios.sh`) and the stub step
  leaves it alone.

Then, in `src/app`:

```
xcodegen generate        # project.yml carries deploymentTarget iOS 12.2
./scripts/ci_build.sh    # fetches, cross-compiles, packages IPA + .tipa
```

The widget extension keeps its own floor (`HuskDownloadsWidget` 16.1): it is
only ever loaded on systems that support it, and an extension newer than the
app is the direction iOS tolerates.

### CI: `.github/workflows/build-ipa.yml`

`macos-15`, Xcode 16.4 selected explicitly, Homebrew deps
(`meson ninja pkg-config cmake xcodegen qemu`) plus the Rust iOS target, then
`ci_build.sh`. The IPA and the TrollStore `.tipa` are attached to the run as an
artifact **and** to a release tagged `ios12-<sha>`; on a public repository the
release asset downloads without authentication. Triggered by a push to
`ios12-backport` or manually (`workflow_dispatch`).

How the first build was actually delivered: the authoring machine is a Windows
box whose network reaches `api.github.com` but not `github.com` over git
smart-HTTP, and the available token could not fork or create repositories. The
branch was therefore pushed as **`husk-ios12-build`** (content-identical to
`ios12-backport`, hence the extra trigger name above) into an existing public
repository of the token's account, as a single root commit uploaded through the
Git Data API. That branch is a temporary build host only and is meant to be
deleted once the IPA has been retrieved; the canonical branch remains
`ios12-backport`.

## Install on iOS 12.2

* **AltStore / SideStore** — 12.2 is exactly AltStore's floor, so this is the
  intended route. Refresh weekly, as ever.
* **Cydia Impactor** — works, certificate included.
* **Jailbroken** — install the IPA however you like; the jailbreak is also the
  JIT route.

## Known gaps

* **No scene lifecycle.** `@main struct App` is iOS 14+ and its `WindowGroup` is
  what gave multi-window; the backport uses `var window` + `UIHostingController`,
  which iOS 13+ runs in the legacy (non-scene) mode. `scenePhase` in
  `ContentView` became `didBecomeActive`/`willResignActive` notifications, which
  is also why an app-clip deep link (`husk://open_app?…`) opens the library on
  the legacy shell instead of a specific game.
* **Nothing was compiled locally.** The backport was authored without access to
  a Mac, so every change here — the 226 annotations included — is verified by
  inspection and by a script (`tools/check_availability.py`) that
  cross-references annotated types, not by a compiler. The `build-ipa` workflow is the first
  compile; expect it (or a local first build) to shake out a handful of
  diagnostics, and the failures will be of the form "'X' is only available in
  iOS N or newer" with the fix being to raise the offending declaration's
  annotation, never to lower one.
* **Dependency floors.** ANGLE's WebKit build, MoltenVK 1.4.2, QEMU 10.0.12 and
  glib 2.83 have never been compiled against a 12.2 minimum. The scripts set it;
  whether each of them accepts it is the first thing a Mac build will say.
* **RAM.** A 1 GB iPhone (5s, 6) is below what the translation layer is
  comfortable with even before a game is loaded. 2 GB (6 Plus, 6s, SE 1st gen,
  7) is the realistic floor for actual play.
