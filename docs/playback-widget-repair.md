# YouTube Music playback and widget repair

## Evidence from the supplied IPAs

- YouTube Music 9.44.2: `com.google.ios.youtubemusic`; stock WidgetKit extension present and decrypted. The main and widget XML entitlement dictionaries both declare `group.com.google.ios.youtubemusic` and `group.com.google.common`.
- The supplied `YTMusicUltimate.dylib` contains neither `MRMediaRemoteSetParentApplication` nor the current repository's launch-fix preference string. The source-level launch repair was not present in this supplied binary.
- Vitrine beta.28 wraps Spotify 9.1.90, `com.spotify.client`. Its main executable declares `8W66MEA7DD.com.spotify.client`; YouTube Music declares `EQHXZ8M8AV.com.google.ios.youtubemusic`. The supplied main entitlement App IDs are different and match their respective bundle IDs. These files do not demonstrate a shared Spotify App ID collision.
- Neither IPA contains an embedded provisioning profile. The original vendor entitlement declarations and ad-hoc signatures do not establish the permissions granted after Feather signs and installs the apps.
- Vitrine includes `SpotifyGlassAppGroups.dylib`, loaded for sharing with extensions after signing. The supplied YouTube Music IPA has no equivalent bridge.

The cause of the reported on-device Spotify launch cannot be conclusively established from these unsigned/repackaged inputs. The missing playback repair and missing post-signing storage bridge are concrete differences addressed here. Final Feather signing remains part of the outcome.

## Changes

- Bind the installed on-disk YouTube Music bundle ID after metadata publication and when playback resumes. Do not bind merely because the app enters the foreground or someone retrieves a default media center before publishing metadata.
- Limit the source-level Google identity spoof to main executable callers, preserving real bundle identity for system frameworks and extensions.
- Load a standalone companion in the host and stock WidgetKit executable. It selects a sorted intersection of the App Groups in their final on-disk XML signatures and the current process's grants. Original Google groups, if not directly granted, use separate folders in that common group for both file storage and defaults suites.
- Leave directly entitled groups untouched. No common readable group, unsupported signature metadata or unavailable container means no redirect; it never claims that private Documents is a shared widget container.
- Package and sign the host/widget executables ad-hoc without altering their entitlement dictionaries. Feather must perform the complete installation signing. The source workflow uses a groups-only companion because the main tweak already includes the launch repair.

The supplied-IPA overlay adds the playback and group repair. It preserves the older main tweak, including its old login hooks. The separate source patch includes the identity-spoof changes for future full builds.

## Validation completed in Linux

- Cross-compiled both Objective-C repair sources for arm64 iOS 13+ against the Theos iPhoneOS16.5 SDK using Clang/LLD 19.1.7.
- Built ldid from ProcursusTeam/ldid, then signed both modified executable files while preserving their original entitlement dictionaries.
- 10 Python regression tests passed: load command injection/idempotence, payload preservation, malformed/unsupported/encrypted input rejection and widget preservation/identity checks.
- Verified the generated IPA ZIP CRC, preserved every original archive member, changed exactly the host and WidgetKit executable, and added one dylib.
- Independently verified CodeDirectory page hashes and XML/DER entitlement blob hashes on all three changed/added Mach-O files. This verifies internal ad-hoc signature consistency, not Apple provisioning authorization.
- Confirmed the WidgetKit executable loads the same repair dylib as the host. The original files are retained.

No iPhone or macOS runtime was available. The MediaRemote mock harness, final Feather signing, widget rendering, Google login and real Lock Screen/Dynamic Island launch have not been executed here. No GitHub push or environment publication was performed.

## Install and validate

1. Import `YTMUltimate_9.44_Playback_Widget_Fix.ipa` into Feather. Keep the WidgetKit extension and sign the entire app, extensions and dylibs.
2. Use a YouTube Music bundle ID whose signed application-identifier suffix matches it. Do not use Spotify's identity. The signing profiles must grant at least one identical App Group to both host and widget. This code cannot create a missing entitlement or provisioning capability.
3. Launch YouTube Music and play a track. Add or refresh its Home Screen widget and check artwork/data changes after another track.
4. Play in Spotify, return to YouTube Music and start playback. Lock the phone and tap the Now Playing card; repeat after pause/resume and from Dynamic Island.
5. Check Google login and the in-app launch diagnostics in the WireGuard settings screen. The bridge logs `[YTMU] Widget bridge: no readable common signed App Group` if it cannot select a shared group.

If a widget stays gray, inspect the *Feather-signed exported IPA* or runtime grants; the original IPA's vendor entitlement declarations do not prove that Feather retained them. DER-only/unsupported metadata and signing profiles without shared App Groups remain blockers to this implementation.
