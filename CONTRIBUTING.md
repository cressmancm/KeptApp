# Working on Kept

Thanks for looking. This covers getting a build running, where Kept keeps its state, and the parts that are awkward to exercise by hand. For how the code fits together, see [ARCHITECTURE.md](ARCHITECTURE.md).

## What you need

- A Mac with Apple silicon. The bundled Python is arm64, and `build.sh` refuses anything else.
- macOS 26 or later.
- Xcode 26 or later. [`.xcode-version`](.xcode-version) holds the minimum, and CI checks it.

## First build

```bash
cd app
./make-cert.sh       # once, unless you have a Developer ID: a self-signed "Kept Dev" certificate
./bundle-python.sh   # once: downloads Python and installs osxphotos from the lock, into .build/python-env
./build.sh           # builds, signs, installs to /Applications and opens Kept
```

Or, from `app`, `make setup` then `make install`; `make` on its own lists the rest. `make-cert.sh` may ask for your login password; it adds a code-signing certificate trusted for your account only. `bundle-python.sh` checks the Python download against a pinned SHA-256 and installs every package from `python-requirements.lock` with hashes.

`build.sh` options:

- `--no-install` builds and signs `.build/Kept.app` and stops there.
- `--debug` makes a debug build a debugger can attach to (below).
- `--force` installs even while a backup is running. Normally it refuses, because installing kills the backup partway through.
- `KEPT_INSTALL_TO=~/Applications/Kept.app` installs there instead of `/Applications/Kept.app`. The script deletes what's at that path before copying, so it refuses anything that isn't an absolute path to a `.app`, or that's already there and isn't Kept.
- `KEPT_SIGN_IDENTITY="Name"` signs with that identity and never falls back; `KEPT_SIGN_IDENTITY=-` signs ad-hoc on purpose, as CI does.

**If you also use Kept for your own backups,** install your builds with `KEPT_INSTALL_TO` so they don't replace that copy. Only one Kept runs at a time, though: opening either quits the other unless it's mid-backup, and both share the same settings, history and backup folder. When you're done, open the copy you use day to day again, so the daily check points at it. A build signed differently from that copy needs Full Disk Access turned on for it separately (see Signing below).

## Debugging the real app

`app/Package.swift` opens in Xcode for editing and running the tests. Xcode can't build the app bundle itself, because the bundled Python, its signing and the provisioning profile are assembled by `build.sh`, but it can debug the bundle:

1. `./build.sh --debug` (or `make debug`): a debug build, with symbols, that allows a debugger to attach. The hardened runtime refuses debuggers otherwise. It keeps your provisioning profile, so it reads the same keychain item as your installed Kept and doesn't ask for the backup folder again.
2. In Xcode, Debug → Attach to Process → Kept. To catch it from launch, use Debug → Attach to Process by PID or Name, enter `Kept`, then open the app.

From a terminal, `lldb -n Kept --wait-for` does the same as step 2.

## Running and testing

```bash
cd app
swift test
```

The two tests in `ExportArgumentsTests` run osxphotos itself: they use `.build/python-env`, fall back to an installed Kept, and skip when there's neither. Set `KEPT_TEST_PYTHON` to an interpreter to test that one instead.

New tests must not touch real state. Use `SecurityTests.scratchDefaults(named:for:)` for preferences, a temporary folder for files, and your own service name for keychain items. `EngineTests` shows how to drive the engine with fake commands and a stand-in for osxphotos.

`swift run --package-path app` starts Kept without a bundle. That's enough for the panel and the setup screens, but there are no notifications, login item or daily check, there's no bundled Python (a backup fails at once), and its preferences are kept apart from the installed app's.

## The parts you can't click

- **Review tools.** In a debug build or a local `build.sh` build, hold Option while opening Settings → Advanced. You can force the panel into any state, force the menubar icon, open any setup screen, and show the warnings, alerts, update row and notifications that are otherwise hard to reach. Nothing they do is saved. Release builds leave them out.
- **The daily check.** `launchctl kickstart gui/$(id -u)/com.chipcressman.Kept.staleness` makes launchd run it now, which also proves launchd can start it. Running `Kept.app/Contents/MacOS/Kept --staleness-check` yourself does the same work without that proof.
- **Moving deleted photos.** `Kept --hold-removed` refuses to act unless a running Kept backup started it, so run a real backup. Delete a test photo from Photos first, or point Kept at a folder with a stray file in it. `RemovedPhotosTests` covers the moving itself.

## Where Kept keeps its state

| Where | What |
|---|---|
| `~/Library/Application Support/Kept/` | `export.db` (the backup index), `runs.json` (history), `report.csv`, `.backup.pid` |
| `~/Library/Logs/Kept/` | One log per backup, stall samples, `access-test.log` |
| Preferences, `com.chipcressman.Kept` | Settings, the sealed backup folder, setup state |
| Keychain, `com.chipcressman.Kept.settings-seal` | The key that seals the backup folder setting |
| `~/Library/LaunchAgents/com.chipcressman.Kept.staleness.plist` | The daily check |

To start over, use Settings → Advanced → Remove Kept…, which removes all of it and leaves the backup alone. Its checkbox keeps `export.db`. Without that file, the next backup copies the whole library again, which takes hours.

## Signing, and why it matters here

Kept reads the Photos library as files, which needs Full Disk Access. macOS ties that grant to the app's signature, so the signature has to stay the same from build to build:

- **A Developer ID**, if you have one, is used automatically, and its builds match the published releases. With its provisioning profile saved as `app/Kept.provisionprofile`, the seal key goes into the data-protection keychain.
- **The self-signed "Kept Dev" certificate** works the same way for your own builds. Without a profile, the seal key lives in the login keychain.
- **Ad-hoc signing** changes with every build, so Full Disk Access has to be granted again each time. Fine for CI, painful otherwise.

Switching between identities resets Full Disk Access and the seal once.

Only the maintainer can produce releases. Notarizing needs the Developer ID, its provisioning profile and the notarization credentials. See [RELEASING.md](RELEASING.md).

## Writing text people see

Kept's copy is short, plain and says the outcome first:

- Say what's true and what to do. Give the reason only when someone needs it to decide.
- Titles of six words or fewer, a subtitle of one clause, a caption of one sentence, an alert of two sentences, three if data is at risk.
- Full stops, not dashes. A single status phrase takes no full stop.
- Paths, exit codes and tool names go in the log, never the interface.
- One name per thing: **backup folder** (not destination or mirror), **backup** (not run or export), **stop** (dialogs keep Cancel), **connected** (not mounted), **copying** (not exporting), **backup index** (not export database).

## Pull requests

Run `swift test` first, and `./build.sh --no-install` if you touched the bundle or the scripts. CI runs both on `macos-26`, Kept's minimum. Keep comments in the house style: say why the code is the way it is, including what went wrong before.
