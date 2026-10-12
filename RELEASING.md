# Releasing Kept

Releases are notarized Developer ID builds, published as GitHub releases. Only the maintainer can make one. They come from `release.sh`, not from Xcode's Archive: the Xcode project is for working on Kept.

## Once

- A **Developer ID Application** certificate in the keychain: Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application.
- Its **provisioning profile**, saved as `app/Kept.provisionprofile`: developer.apple.com → Profiles → + → Developer ID, for the App ID `com.chipcressman.Kept`. The portal names the download after the profile, so rename it. It's gitignored. Without it, `release.sh` refuses, because the seal key would stay in the login keychain.
- **Notarization credentials** under the keychain profile `kept-notary`:

  ```bash
  xcrun notarytool store-credentials "kept-notary" --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
  ```

## Each release

1. **Bump the version** in `app/Info.plist`: `CFBundleShortVersionString` (`1.2`) and `CFBundleVersion` (one more than last time). Edit the two values by hand. `PlistBuddy -c Set` rewrites the whole file and drops its comments.
2. **Point the README** at the new zip: the Download section names `Kept-<version>.zip`.
3. **Commit** as `Kept <version>`, push, and wait for both CI jobs to pass.
4. **Build:** `cd app && ./release.sh`. It checks the certificate and the notary profile first, then builds with the secure timestamp and without the review tools, checks the app's Python packages against the lock, submits for notarization (usually a few minutes), staples the ticket, and runs a Gatekeeper check. The first time, codesign asks for the Developer ID key; choose Always Allow, or it asks for each of ~200 files. You get `app/dist/Kept-<version>.zip` and its SHA-256. If notarization is rejected, the script prints Apple's log, which names every file and why.
5. **Install it yourself** from the zip: quit Kept, replace `/Applications/Kept.app`, open it, check the version in Settings → Advanced, and run Test Library Access.
6. **Tag** the commit it was built from, and push the tag:

   ```bash
   git tag -a v<version> <commit> -m "Kept <version>"
   git push origin v<version>
   ```

   The tag must be plain, `v1.2` or `v1.2.3`. Kept's update check only recognises that form. Anything else, such as `v1.2-beta`, is ignored.
7. **Publish:**

   ```bash
   gh release create v<version> app/dist/Kept-<version>.zip --title "Kept <version>" --notes-file notes.md --latest
   ```

   Then download the zip from the release and check its SHA-256 matches. A beta goes out with `--prerelease` instead, which GitHub's "latest", and so Kept's update check, leaves out.

## Release notes

Follow the earlier releases:

- One sentence on what the release is for.
- **Install:** download, open, follow setup.
- **Updating:** anything people coming from older versions need to know. Say it whenever setup runs again, as it did from 1.0 to 1.1.
- **What's new:** outcomes, in the app's voice (see CONTRIBUTING.md).
- **Requirements:** macOS 26 or later, Apple silicon, room for the library.
- **Checksum:** the zip's SHA-256.

## After

From 1.2 on, Kept checks GitHub once a day, so people see the new version in the menubar within a day. Copies older than 1.2 don't check, and reach the release only through the README and GitHub.
