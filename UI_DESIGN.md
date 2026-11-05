# UI and localization verification

## Change boundary

The UI refresh covers the iOS app: its shared dark palette, materials, navigation,
library, search, playlists, artist/genre management, duplicate manager, full and
mini players, playback settings, sleep timer, import screens, Mac connection,
YouTube preview and language settings. `AppTheme.swift` centralizes colors and
surface treatments. Native glass uses availability checks, with material/solid
fallbacks. Controls use larger touch areas; layout adaptations and reduced-motion
and reduced-transparency behavior are implemented where the views support them.

The localization scope is German and English app-owned labels, counts,
accessibility text, status messages and errors. German source phrases remain
catalog keys. SwiftUI literals use the selected environment locale; dynamic
app-owned strings use `L10n.text`, formatted values use `L10n.format`, and explicit
integer plurals use `L10n.count`. Selection is read when rendering, so an existing
message can follow a language change. Earlier translations for the other language
options are preserved; those languages are not claimed to have complete coverage.

Real song titles, artists, albums, filenames, playlist names and server-provided
metadata remain user content. Known German/English unknown-artist and unknown-album
sentinels are translated for display only through `MetadataText`. Stored metadata
must not be rewritten to implement a language change. System permission prompts
are a separate InfoPlist localization concern and follow iOS language selection.

This verification task changes only tests and this document. Production fixes
found by the audit are handed to the agents owning those files. It does not change
models, persistence, audio-engine behavior, network protocols, signing or user
data. No commits are made by this task.

## Independent automated check

Run with full Xcode selected for the process, without changing `xcode-select`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 Tests/check_localization.py --report /private/tmp/localization-audit.json
```

For an audit without invoking the compiler:

```sh
python3 Tests/check_localization.py --static-only \
  --report /private/tmp/localization-audit.json
```

The script exits nonzero for catalog or literal-coverage failures. The JSON report
separates failures from candidates requiring review. `--baseline REVISION` selects
the git snapshot used to check preservation; the default is `HEAD`. After committing
a localization change, use its parent revision to repeat the original comparison.

The check performs these specific operations:

- Compares every existing `translated` string unit, including its state and text,
  against the baseline, across all languages. Removing a key or translation fails.
- Requires German source keys and English coverage, checks nonempty translated
  English units, format argument types/positions and required `one`/`other` forms.
- Scans every `OfflineMusic/*.swift` file, including non-view error/status
  producers. Its lexical reader handles comments, ordinary/raw/multiline strings
  and nested string interpolation. Literal UI/helper arguments absent from the
  catalog fail. Dynamic consumers and German-looking uncatalogued literals are
  listed for human review.
- Optionally checks Xcode's exact extracted SwiftUI keys (including interpolation
  argument types) with `--extracted-strings DIRECTORY`. Supply the directory
  containing the current build's `.stringsdata` files, produced with
  `SWIFT_EMIT_LOC_STRINGS=YES`; older build output can be stale.
- Compiles a snapshot of the actual catalog with `xcstringstool` into real
  `de.lproj`/`en.lproj` resources. Both strings and stringsdict products are required.
- Compiles `InfoPlist.xcstrings` and checks explicit DE/EN bundle lookups for the
  camera and local-network permission descriptions.
- Compiles the actual production `Localization.swift` with
  `Tests/check_localization.swift` into a temporary macOS application bundle,
  without mocking the helper or substituting a translation dictionary.
- Exercises every plain DE/EN catalog lookup and changes DE → EN → DE in one
  process. Every single-integer catalog key is also formatted at 0, 1, 2 and 21
  against the matching catalog plural branch. Independent expectations cover
  0, 1, 2 and 21 songs, seconds and
  minutes; explicit formatted and stored interpolated errors; unknown-key fallback;
  and re-rendering an existing message after language changes.
- Exercises the actual `MetadataText` enum independently of SwiftUI: both legacy
  sentinel spellings change display language, while real names and empty metadata
  stay unchanged. Joined revocation/retry messages must translate both their
  surrounding text and their embedded plain or formatted error.
- Verifies `L10n.error` keeps app-owned `LocalizedError` source keys and normalizes
  generic, network, timeout and disk-space OS errors before DE/EN rendering.

Build products and module caches use a temporary directory. The test overrides
language preferences through a volatile defaults domain. It does not open the
music library, modify the app's persisted settings or contact a service. Compiler
execution may require sandbox approval, including for existing Swift macro tests.

## Limits and other checks

The lexical audit is not Swift type checking or a proof that every dynamic string
has the correct provenance. It cannot establish SwiftUI interpolation overloads,
traverse arbitrary data flow, or decide whether text such as a playlist name is
app-owned. Review dynamic `Text`, `Section`, accessibility and navigation consumers,
especially ternaries, persisted sentinel values, error messages and formatted
metadata. A passing static check does not imply that its review list is empty.

The compiled helper test uses Foundation on macOS. It validates the compiled
catalog/helper contract; it does not render SwiftUI, validate an installed iOS
bundle, or test iOS permission prompts. The unsigned simulator build and the seven
existing Swift regression suites are run separately by main. Existing regression
coverage and reproduction commands are described in `QUALITY_CHECK.md`.

No simulator screenshots or visual validation are claimed by this task. Device/UI
checks still required include switching DE/EN while sheets and errors are open;
long metadata and translated labels; all accessibility text sizes; VoiceOver;
reduced motion/transparency; empty and populated libraries; player/queue states;
and all import failure states. Real lock-screen/Control Center behavior,
Bluetooth/AirPlay and hardware audio remain device checks.

## Recorded result

On 2026-11-05, the independent check passed with full Xcode selected through
`DEVELOPER_DIR`: 457 app catalog keys, two permission-description keys, 1,481
compiled DE/EN assertions and all 253 originally translated string units preserved
against `HEAD`. The source audit covered 27 Swift files and 610 UI/localization
consumers; compiler extraction covered 31 files and 445 distinct exact keys.
There were no catalog, format, preservation or literal-coverage failures.

The 136 review candidates were inspected: dynamic catalog keys and branches,
localized errors, user/server metadata, numeric/date/bitrate displays and control
overloads. Remaining German-looking uncatalogued literals were actual artist
names/aliases and the `Türkçe` language autonym. Metadata headings remain raw when
they represent user/server content. The audit found and reported raw sentinel
displays, QR errors, a playlist-heading collision, joined errors and overly broad
legacy count matching; production owners applied the fixes before the passing run.

Comparison with `HEAD` confirmed `OfflineMusicApp.swift`, including models and the
audio engine, remained byte-identical, and the `PlaybackTiming` logic was unchanged. Main reported that
the existing seven Swift regression suites passed. Simulator builds and any
screenshots are separate from this independent helper/catalog verification.

## Final app validation and design tokens

The final unsigned arm64 iOS Simulator build succeeded using Xcode 27.2 with
the iOS 17 deployment target retained. Earlier intermediate builds also compiled
both arm64 and x86_64. All seven existing Swift regression suites passed. The
final empty-library Home screen was launched and visually inspected in English
and German on an isolated iOS 26.2 iPhone simulator. This does not establish
visual correctness of populated libraries, every sheet, player state or
accessibility size. Temporary simulator data was separate from personal libraries.

| Token | Color | Use |
| --- | --- | --- |
| `AppTheme.background` | `#0C0E10` | Main canvas |
| `AppTheme.header` | `#070809` | Opaque scrolling/navigation header |
| `AppTheme.surface` | `#1E2124` | List rows and cards |
| `AppTheme.separator` | `#3A3E42` | Visible row and selection dividers |
| `AppTheme.accent` | `#45E881` | Selection, primary playback and progress |
| `AppTheme.text` | `#F5FFF6` | Main text |
| `AppTheme.secondaryText` | `#A4B7AC` | Supporting text |
| `AppTheme.onAccent` | `#0C0E10` | Text/icons on bright green |

Native Liquid Glass is availability-gated to iOS 26. The mini player uses the
native tab accessory there, with a safe-area material inset on older systems.
Reduce Transparency uses solid custom surfaces; Reduce Motion disables optional
UI animations. Artwork thumbnails are downsampled off the main thread with a
bounded cache. The player volume control uses the system `MPVolumeView`; its
route-button suppression currently produces a deprecation warning but builds.

## Changed production files

- `OfflineMusic/AppTheme.swift`: shared palette, surfaces, glass/fallbacks,
  thumbnail cache, metadata placeholder presentation and system volume view.
- `OfflineMusic/Views.swift`: main navigation, Home, library, search, playlists,
  song rows, artwork, mini player, full player and queue.
- `OfflineMusic/SmartPlaylists.swift`: themed smart playlist screen and dynamic
  localization boundaries.
- `OfflineMusic/MusicCatalog.swift` and `OfflineMusic/LibraryManagement.swift`:
  genre/artist screens, duplicate management, adaptable layouts and errors.
- `OfflineMusic/PlaybackOptions.swift`: crossfade settings and sleep timer.
- `OfflineMusic/ImportHubView.swift`, `MacImportView.swift`,
  `MacSourcesView.swift`, `MacJobDetailView.swift`, `MacConnectionView.swift`,
  `MacQRCodeScanner.swift` and `YouTubePlayerView.swift`: import, connection,
  preview and scanner interfaces.
- `OfflineMusic/Localization.swift`, `Localizable.xcstrings` and
  `InfoPlist.xcstrings`: language selection, complete German/English catalog,
  native plurals, dynamic messages and permission descriptions.
- `OfflineMusic.xcodeproj/project.pbxproj`: new source/resource membership only.

The existing additional language translations are preserved but remain partial.
There are no known missing German/English app-owned keys in the audited source.
System permission dialogs follow iOS language settings, while the existing
in-app language preference controls the app interface. Physical-device VoiceOver,
audio routes, background playback and full visual-state testing remain open.
