# In-app updates and release publishing

FarReach 0.6 uses [Sparkle 2](https://sparkle-project.org/documentation/) for signed in-app updates. Users install `FarReach.app` once in `/Applications`; later releases replace that bundle in place. They do not need Git, source code, or a fresh app copy in Downloads for each update. Sparkle uses temporary download/staging storage during installation.

## Current repository state

`Resources/UpdateConfiguration.json` contains the official GitHub release-feed URL and the public Ed25519 update-verification key. The private signing key stays in the maintainer’s login Keychain under the `FarReach-updates` account and is not part of this repository. The public feed is served from the latest published GitHub release.

Fork maintainers should replace both the feed URL and public key with their own before distributing builds. Clearing both fields disables update requests; partial or invalid configuration is rejected.

Version 0.5.1 and earlier do not contain an updater. Install the first configured 0.6-or-later release manually once on each Mac. An unconfigured development build also needs a manually installed configured release before it can discover updates.

## User behavior

- **FarReach → Check for Updates…**, the menu-bar menu, and **Setup → App updates** expose update controls.
- Configured builds check automatically and download/install updates automatically by default. Both preferences can be changed in Setup.
- An update waits while sharing is enabled, a viewer is connected or paused, a connection/recovery is in progress, or a local diagnostic is running. Stop sharing and close background connections to allow installation and restart.
- Restarting the app preserves Keychain pairing and user preferences. It does not automatically re-enable sharing.
- Sparkle verifies signed feeds and update archives; archive verification is required before extraction. System profiling is disabled. The release host still sees ordinary HTTP request metadata, such as IP address and user-agent.

## One-time setup for a fork or new signing identity

1. Create a public GitHub repository for the project. No repository credentials belong in the app.
2. Resolve the pinned dependency and generate a dedicated signing key in your login Keychain:

   ```sh
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account FarReach-updates
   ```

3. Copy only the displayed **public** key into `Resources/UpdateConfiguration.json`:

   ```json
   {
     "feedURL": "https://github.com/OWNER/REPO/releases/latest/download/appcast.xml",
     "publicEDKey": "BASE64_PUBLIC_KEY_FROM_GENERATE_KEYS"
   }
   ```

4. Keep the private key in Keychain and maintain a secure backup outside the repository. Losing it can break the update chain. The public key is safe to commit. The example above is documentation, not a usable configuration.
5. For a public release, use a Developer ID certificate and notarize the finished app. Ed25519 update signatures authenticate downloads; they do not replace Gatekeeper notarization or stabilize TCC permissions for ad-hoc builds.

The update feed and the Cloudflare desktop-signaling service are independent. Configuring one does not configure the other.

## Prepare a release

1. Update `CFBundleShortVersionString` and increase `CFBundleVersion` in `Resources/Info.plist`. Keep the bundle identifier and installed app name unchanged.
2. Run regression tests, then build:

   ```sh
   ./scripts/build-app.sh
   ```

   Set `FARREACH_SIGN_IDENTITY` to your Developer ID signing identity when available. The script signs nested Sparkle code, the networking helper, and the app in order. Without that setting it creates an ad-hoc development build.

3. If notarizing, submit the app archive with your own `notarytool` credential profile, wait for acceptance, and staple the ticket to `dist/FarReach.app`. Do this before the next step. Do not store Apple account credentials in the repository.
4. Prepare signed assets locally:

   ```sh
   python3 scripts/prepare-release.py --repository OWNER/REPO --notes release-notes.md
   ```

   `--notes` is optional. The script checks the built app matches the configured feed/key, verifies its code signature, creates a metadata-normalized ZIP preserving framework symlinks, signs the archive/feed with Sparkle, and verifies both signatures. It does not upload or publish anything. It uses the `FarReach-updates` Keychain account by default. CI can supply `--key-file /secure/path/update.key`; the file must be outside the repository.

5. Review `dist/releases/<version>-<build>/`. Create a GitHub release tagged `v<version>` and attach the generated app ZIP, `appcast.xml`, and `SHA256SUMS.txt`. Publish as a normal latest release, not a prerelease. The feed URL is stable; each archive URL points to its versioned release.
6. Never edit a signed appcast or replace an already published archive in place. Rebuild, increment the build number, and publish a new version. The current script emits a single-version feed without delta updates; future releases must remain compatible with the previous install or add a reviewed bridge-release strategy.

## Validation before enabling distribution

Automated checks cover configuration rejection, deferred restarts, packaging symlinks/permissions, and signed artifact generation/tamper rejection. A local smoke test also downloaded and verified a signed update, replaced an isolated closed FarReach bundle from build 10 to 11 at the same path, and preserved a test preference. It used a temporary signing key and separate bundle identifier; it did not exercise production Keychain pairing or a remote session.

For each release, verify the actual published feed/archive, signing/notarization status, persistent pairing, and active-session behavior. A first release can only report “up to date”; a later published build is needed to test a real public old-to-new update.

Reference: [Sparkle setup](https://sparkle-project.org/documentation/), [publishing](https://sparkle-project.org/documentation/publishing/), and [update settings](https://sparkle-project.org/documentation/customization/).
