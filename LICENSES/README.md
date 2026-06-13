# Third-party licenses

TrueYield itself is licensed under Apache-2.0 (see the top-level `LICENSE` and
`NOTICE`). This directory reproduces the full license texts of the third-party
components that are **bundled into the application binary**, with the versions
this project depends on:

| Component | Version | License | File |
|---|---|---|---|
| Flutter & Dart SDK | (toolchain) | BSD-3-Clause | `flutter-sdk.txt` |
| http | 1.6.0 | BSD-3-Clause | `http.txt` |
| shared_preferences | 2.5.5 | BSD-3-Clause | `shared_preferences.txt` |
| url_launcher | 6.3.2 | BSD-3-Clause | `url_launcher.txt` |
| cupertino_icons | 1.0.9 | MIT | `cupertino_icons.txt` |

These are the direct, shipped (`direct main`) dependencies. Their **transitive**
dependencies (platform-channel packages, `meta`, `collection`, etc.) are also
bundled and are attributed at runtime by Flutter's aggregated license page,
reachable from the app's **Info** tab (`showLicensePage`), which lists every
package in the dependency tree with its full text.

Dev-only and build tooling (`flutter_lints`, `flutter_test`,
`integration_test`, `flutter_launcher_icons`, and the Python tools `pypdf` /
`pdfplumber`) are **not** shipped in the binary; see `NOTICE` for their
attribution.
