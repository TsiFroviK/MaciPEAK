# Sources used by MaciPEAK

MaciPEAK builds a local app from three inputs. The table identifies which files a user supplies, which tools or runtimes the builder obtains, and which sources are present in this repository.

| Input | Source and use |
| --- | --- |
| PEAK for Windows | The user supplies their licensed Steam installation. Its assets, shader programs, map archives and managed assemblies are the inputs for local conversions. PEAK and its artwork belong to their respective owners. [PEAK on Steam](https://store.steampowered.com/app/3527290/PEAK/) |
| MaciPEAK sources | Shell and Python build tools, compatibility bridges in C/Objective-C and a C# assembly patcher. Identifiers and checksums select supported formats and versions. The Opus test generates its tone locally. |
| README banner | The supplied MaciPEAK illustration is included in the English and Russian README files. The game icon used in the app is generated separately from the user's copy of `PEAK.exe`. |
| Builder icon | An original illustration generated for MaciPEAK shows a desktop monitor with a mountain landscape in the banner's violet and peach palette. |
| Risk2Mac | The shader tool bootstrap and portions of the conversion approach come from the MIT-licensed Risk2Mac project. [Pinned source](https://github.com/TsiFroviK/Risk2Mac/tree/dfdbc490202a77e65204d5fb5aac3aef066286a9) · [MIT notice](licenses/Risk2Mac-MIT.txt) |
| Unity | The official Unity Editor package provides the matching macOS Mono libraries. Mac Build Support (Mono) supplies the universal player. These are extracted locally under Unity's terms. [Release and third-party notices](https://unity.com/releases/editor/whats-new/6000.3.15f1) |
| Build tools | Python reads and writes Unity data using UnityPy and LZ4. Roslyn compiles the C# tools and Steamworks wrapper. The builder can use existing tools or fetch its own copies. [CPython standalone builds](https://github.com/astral-sh/python-build-standalone) · [UnityPy](https://github.com/K0lb3/UnityPy) · [python-lz4](https://github.com/python-lz4/python-lz4) · [.NET](https://dotnet.microsoft.com/download) · [Roslyn](https://github.com/dotnet/roslyn) |
| Graphics converters | vkd3d translates the Windows shader bytecode to SPIR-V. SPIRV-Cross translates SPIR-V to Metal. Both are build-time tools. [vkd3d](https://gitlab.winehq.org/wine/vkd3d) · [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) · [SPIRV-Headers](https://github.com/KhronosGroup/SPIRV-Headers) |
| Steamworks | The builder checks the Windows ABI and compiles the macOS wrapper from pinned Steamworks.NET source using the supplied Unity assembly references. It installs Valve's matching macOS runtime from the SDK integration. The wrapper's MIT license and Valve's runtime terms apply to their respective components. [Steamworks.NET release](https://github.com/rlabrecque/Steamworks.NET/releases/tag/2025.161.0) · [Steamworks](https://partner.steamgames.com/) |
| Epic Online Services | The builder obtains the macOS SDK runtime from the pinned EOS-Contrib Unity plugin release. Epic's SDK terms apply to that binary. [Runtime and vendor notices](https://github.com/EOS-Contrib/eos_plugin_for_unity/tree/v6.1.0/Assets/Plugins/macOS) |
| Mono.Cecil | A build-time tool used to patch the user's copy of PhotonVoice. The patch lets gameplay continue while macOS requests microphone permission. [Mono.Cecil on NuGet](https://www.nuget.org/packages/Mono.Cecil/0.11.6) · [MIT notice](licenses/Mono.Cecil-MIT.txt) |
| Voice | Xiph Opus is compiled locally. A separately obtained, compatible Photon Voice SDK can supply additional native voice components. [Xiph Opus](https://downloads.xiph.org/releases/opus/) · [Photon Voice](https://www.photonengine.com/voice) |

Use of the builder does not change the license of the game, SDKs, or generated app. MaciPEAK is independent of the PEAK developers, Valve, Epic Games and Unity.
