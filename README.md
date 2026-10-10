# Kept

[![Tests](https://github.com/cressmancm/KeptApp/actions/workflows/tests.yml/badge.svg)](https://github.com/cressmancm/KeptApp/actions/workflows/tests.yml)

A macOS menubar app that copies your whole Photos library to a folder you choose, every night, and tells you when it hasn't.

The backup is ordinary files in date folders (`2024/03/01/IMG_1234.HEIC`), so you can open it in the Finder without Kept. It works with a folder on a NAS, an external drive, or another disk.

## What it does

- **Nightly, weekly or manual backups.** After the first one, only new and changed photos are copied.
- **Catches up on missed nights.** If the Mac was asleep or on battery, Kept backs up when it wakes or is plugged in. A failed backup is retried an hour later, up to twice.
- **Keeps deleted photos for a while.** A photo deleted from your library moves to `Removed from Photos` in the backup and is deleted after 30, 90 or 365 days.
- **Warns you if backups stop.** A daily check runs even when Kept isn't open, and posts a notification if the last good backup is older than you allow.
- **Explains problems in plain words.** "Couldn't reach nas.local at 2:04 AM. Check that it's on and connected, and Kept will try again."
- **Removes itself cleanly.** Settings → Advanced → Remove Kept… takes its login item, daily check, settings, history and logs with it, and never touches your backup.

Your photos never leave your Mac and your network: no accounts, no cloud, no analytics. Once a day Kept asks GitHub whether there's a newer version, and says so in the menubar if there is; turn that off in Settings → Advanced.

## Requirements

- macOS 26 or later, on Apple silicon (M1 or later)
- Full Disk Access for Kept, which you turn on during setup
- A backup folder with room for your library

## Download

Get **Kept-1.2.zip** from the [latest release](https://github.com/cressmancm/KeptApp/releases/latest), unzip it, drag Kept to Applications and open it. It's signed with a Developer ID and notarized by Apple, so it opens without warnings. Setup then walks you through turning on Full Disk Access and choosing a backup folder.

## Building from source

You need Xcode 26 or later. [CONTRIBUTING.md](CONTRIBUTING.md) has the details: where Kept keeps its state, how to exercise the parts you can't click, and why signing matters. [ARCHITECTURE.md](ARCHITECTURE.md) is a one-page map of the code.

```bash
cd app
./make-cert.sh       # once, if you don't have a Developer ID: a self-signed signing certificate
./bundle-python.sh   # once: the Python and osxphotos that ship inside the app
./build.sh           # builds, signs, installs to /Applications and launches
```

`build.sh` signs with your Developer ID Application certificate if one is in your keychain, and otherwise with the self-signed "Kept Dev" one from `make-cert.sh`. Either way the signature stays the same from build to build, so Full Disk Access only has to be turned on once. Local builds don't need notarizing: macOS only checks that on apps downloaded from the internet.

Run the tests with:

```bash
cd app
swift test
```

`release.sh` builds a notarized release with a Developer ID certificate and its provisioning profile, saved as `app/Kept.provisionprofile`. The profile lets Kept keep the key that seals its folder setting in the data-protection keychain; `build.sh` uses it too when it's there, and without it falls back to the login keychain. [RELEASING.md](RELEASING.md) has the whole checklist.

### On GitHub

Two workflows run on GitHub's `macos-26` runner, macOS 26 being the oldest version Kept supports:

- **Tests** runs on every push and pull request, in two jobs. One runs `swift build` and `swift test`, and checks the runner's Xcode isn't older than [`.xcode-version`](.xcode-version). The other builds Kept.app with its bundled Python, signed ad-hoc, and runs the tests that put Kept's real arguments through that app's osxphotos.
- **CodeQL** scans the Swift, the Python scripts and the workflow files for security problems on every push and pull request, and every Monday. Results are under the repository's Security tab.

## How it works

Kept is a SwiftUI menubar app that drives [osxphotos](https://github.com/RhetTbull/osxphotos), bundled with its own Python, to export the library. Kept handles everything around the export:

- **Scheduling and catch-up:** wakes, retries, and the rule against unattended backups on battery.
- **The network drive:** reconnects a NAS share, including one that's stuck.
- **Deleted photos:** moves them aside instead of deleting them, then expires them.
- **The interface:** the menubar panel, setup and settings.
- **Safety checks:** refusing home, system and cloud folders, and any folder holding a Photos library, as the backup folder; sealing the saved folder setting and checking the disk or share is still the one you chose; never following links inside the backup; and running osxphotos in an isolated environment.

| Folder | What's in it |
|---|---|
| `app/Sources/Kept` | The app |
| `app/Tests/KeptTests` | Unit tests, including some that run Kept's real arguments through osxphotos |
| `app/*.sh` | Certificate, Python bundling, build and release scripts |
| `app/python-requirements.lock` | Every Python package, pinned with hashes |

## Credits

- [osxphotos](https://github.com/RhetTbull/osxphotos) by Rhet Turnbull does the exporting.
- Python comes from [python-build-standalone](https://github.com/astral-sh/python-build-standalone).
- Every build writes the licenses of everything bundled into `LICENSES.txt` inside the app.

## How it was built

Kept was built with [Claude Code](https://claude.com/claude-code). Each commit names the Claude model that worked on it in a `Co-Authored-By` line.

## License

MIT. See [LICENSE](LICENSE). The bundled osxphotos, Python and their dependencies keep their own licenses, listed in `LICENSES.txt` inside the app.
