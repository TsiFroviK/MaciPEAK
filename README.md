# MaciPEAK

![MaciPEAK banner with a mountain peak against a purple sky](docs/macipeak-banner.png)

[Инструкция на русском](README.ru.md)

Build a native macOS `PEAK.app` from your own Windows Steam installation of **PEAK 3.1.0, BuildID 26542162**. The builder supports Apple silicon and Intel. This is an unofficial community project.

## With MaciPEAK Builder

1. Open the [MaciPEAK Builder disk image](https://github.com/TsiFroviK/MaciPEAK/releases/latest/download/MaciPEAK-Builder-macOS.dmg), drag **MaciPEAK Builder** to **Applications**, then open it from Applications. Copy the complete Windows PEAK folder to the Mac or a connected drive.
2. Sign in to Steam on the Mac with the account that owns PEAK and open its Library page. Finish any running Steam games. Allow about 30 GB of free space beyond the Windows files on an APFS or Mac OS Extended volume.
3. Choose the Windows folder containing `PEAK.exe`, then click **Build**. Under **Advanced options**, you can select Apple silicon, Intel, or a universal game for both. The default matches the physical Mac running the builder.
4. When the build finishes, open **Steam → Library → PEAK → Play**. The app uses the same build script as the Terminal instructions below.

MaciPEAK Builder 1.0.1 is locally signed and has no Apple notarization ticket. If macOS asks for approval on first launch, follow [Apple’s guide to opening downloaded apps](https://support.apple.com/en-us/102445).

To rebuild an existing port, quit PEAK and move the old `PEAK.app` from `steamapps/common/PEAK` to a backup folder on the same volume first. Leave the Windows game folder and Steam files in place.

## Build on a Mac

1. Install PEAK on Windows using Steam. Copy the entire unmodified `steamapps/common/PEAK` directory to your Mac or an external drive. Keep `PEAK.exe`, `version.txt` and `PEAK_Data` together.
2. Download and unzip this repository. In Terminal, open the directory containing `build.sh`. Choose an APFS or Mac OS Extended destination for the app. For a first build, allow around 30 GB of free space **in addition to** the Windows copy. The build uses Apple's Command Line Tools and an internet connection.
3. For a library install, open Steam on your Mac, sign in to the account that owns PEAK and open its Library page so Steam can cache its game information. Finish any running games, then build from your Windows copy.

```sh
sh build.sh --game "/Volumes/Games/PEAK"
```

The script builds a universal game by default. Add `--arch arm64` for Apple silicon or `--arch x86_64` for Intel.

The default destination is `steamapps/common/PEAK/PEAK.app` in your Steam library. To select an external library, add `--steam-library "/Volumes/Games/SteamLibrary"`. An exFAT drive can hold the Windows input. For the library on that drive, use a mounted APFS disk image and mount it before starting Steam. For a standalone Finder build, pass `--output "/path/to/PEAK.app"` with an existing parent directory.

4. Sign in to the Steam account that owns PEAK. Open **Library → PEAK → Play**. The builder asks a running Steam client to exit and then reopens it when registering the install. If Steam was closed, start it yourself. The game uses its retail AppID `3527290`. [PEAK on Steam](https://store.steampowered.com/app/3527290/PEAK/)

On first launch, PEAK opens in borderless fullscreen. To play in a window, select **Windowed** under **Settings → Graphics → Window Mode**. The game remembers this choice on later launches.

On macOS 14 or later, the builder asks Gatekeeper to scan the finished game in its installation folder. This moves the initial verification wait into the build. macOS can assess the game again if you move or change it.

### Steam registration and overlay

PEAK's publisher supplies Windows launch options. MaciPEAK adds a macOS launch option to the local Steam catalog for this game and records the installation in your library. Steam can refresh that catalog. If the Play button disappears, or if Steam was busy when the build finished, restore the registration without rebuilding the app. Supply the same `--steam-library` if you selected an external library.

```sh
sh build.sh --register-steam
```

To remove the local registration and keep your built app, run `sh build.sh --unregister-steam` with the same library. For the overlay, launch using the Steam **Play** button and press **Shift+Tab** after the title screen appears. The Steam overlay must be enabled in **Steam → Settings → In Game** and **PEAK → Properties → General**. On the M1, Play launched the arm64 app and successive presses opened and closed Steam's overlay. [Valve's overlay guide](https://help.steampowered.com/en/faqs/view/3978-072C-18DF-FBF9)

### Render FPS and Metal HUD

MaciPEAK sets `UNITY_DISPLAYLINK_BLIT=0` in the app environment before Unity starts. When launched from Steam or Finder, Apple's Metal HUD can report presentation rates above 60 FPS. Turn off VSync in PEAK and set the game's frame-rate limit above 60. Keep the system Metal HUD enabled.

PEAK's VSync setting controls the game's Metal layer directly. This keeps Unity's simulation clock advancing at the correct rate in both display modes. Photon processes incoming messages on physics updates. When those updates stalled, the menu could show **Connecting…** and then **Disconnected** even after Steam had authenticated successfully.

On a MacBook Air M1 with a 60 Hz panel, the previous presentation path produced about 60 FPS in the HUD even when Unity rendered faster. With the new path, Apple's HUD reported **78.85 FPS** with a **12.68 ms** frame interval in the foreground 640×360 window. With the game capped at 45 FPS it reported **44.97**. In an inactive window we also observed `inf` with a zero frame interval. Take comparative readings with the game in the foreground. [Apple's Metal HUD metrics](https://developer.apple.com/documentation/xcode/understanding-metal-performance-hud-metrics)

For a separate count of frames rendered by Unity, enter `-macipeak-fps` under **PEAK → Properties → General → Launch Options**. It appears at the bottom left.

## What the builder obtains

MaciPEAK looks for Unity **6000.3.15f1**, revision **c1aa84e375f6**, and the matching Mac Mono support module. Unity Hub is optional. On a clean Mac it downloads the universal Mac player package (about 725 MB) and reads the first 1,032 MiB of the official Editor package. It extracts 30 macOS Mono libraries, verifies each checksum and caches about 20 MiB of libraries. [Unity release and installers](https://unity.com/releases/editor/whats-new/6000.3.15f1)

The builder reuses a compatible Python and C# compiler when available. It can fetch these tools, its Python packages, shader converters, Steamworks.NET, the macOS EOS SDK, Mono.Cecil and Xiph Opus. Apple's installer handles Command Line Tools if they are missing. The game assets and platform SDK downloads stay on the machine doing the build. [Dependency sources and attribution](THIRD_PARTY.md)

Reusable downloads and intermediate shaders go to `.macipeak-cache` in the Steam library root or beside a standalone app. Use `--cache DIR` to move that cache, or `--editor PATH` and `--support PATH` for an existing matching Unity installation or downloaded Unity packages. `--deps DIR` accepts local SDK files, including a compatible `PhotonVoice.unitypackage` for optional WebRTC audio processing. The default voice path uses the Unity microphone and Opus. Run `sh build.sh --help` for all options.

## How the port is built and checked

The builder reads the scenes, materials, shader programs, map archives and managed assemblies from the supplied Windows game. It translates the graphics and compute programs to Metal, applies the render and microphone fixes locally, builds the native compatibility libraries and assembles the app using Unity's macOS player. It checks the selected CPU slices and the app's ad-hoc signature before installation.

To package the builder for Releases, run `sh scripts/package-gui.sh MaciPEAK-Builder-macOS.dmg` on a Mac with Apple's Command Line Tools. The disk image contains the universal builder and its build scripts. You can also pass a `.zip` output path. Packaging works without a copy of PEAK and uses a local signature by default. For a notarized disk image, set `MACIPEAK_SIGN_IDENTITY` to your Developer ID Application identity and `MACIPEAK_NOTARY_PROFILE` to your notarytool keychain profile. The script signs the app and disk image, submits the image to Apple and attaches the ticket. [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

The Finder and Dock icon is generated at build time from the icon resources in your copy of `PEAK.exe`.

The port has been tested on a MacBook Air M1. Twelve matched views on `Level_0` and `Level_32` were compared with Windows Direct3D 11. The regular airport boarding flow also loaded `Level_111` under both arm64 and x86_64 via Rosetta 2. Physical Intel hardware and multiplayer voice with a second player have not been verified.

The MaciPEAK build scripts and original compatibility code are available under the [MIT License](LICENSE). Use your own licensed copy of PEAK. Keep the resulting app, your Steam installation and the build cache private. [Third-party notices](THIRD_PARTY.md)
