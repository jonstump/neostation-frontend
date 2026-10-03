---
# status: one of proposed | accepted | deprecated | superseded (enum enforced by /sdd:status)
status: proposed
date: 2026-10-03
decision-makers: [Jon Stump]
related: [ADR-0020, ADR-0021]
---

# ADR-0022: Reset the app to first run from inside the app

## Context and Problem Statement

There is no way to put NeoStation back to its first-run state without leaving it. On Android that means Settings > Apps > Clear data, or `adb shell pm clear`; on desktop it means finding the user-data folder and deleting it by hand. Both are outside the app, both need another device or a keyboard, and both wipe more than most people mean to (the ROMs themselves sit beside the database when a custom user-data folder was chosen).

The state lives in several places: the SQLite database and the media cache under the user-data folder (which may be a custom location recorded in `SharedPreferences`), the RomM cover cache under the media cache, bootstrap preferences read before the database opens (`custom_user_data_path`, the startup theme colours, the pending game session, `skip_startup_scan`), credentials in the secure store (RomM API key, ScreenScraper, RetroAchievements, NeoSync token), the log file, and on Android the persisted SAF folder grants. Testing the setup wizard (ADR-0021) and recovering from a broken library both need a way to clear this that the user can reach on the device.

## Decision Drivers

* A user on a handheld should be able to start over without a PC or adb.
* ROM files are never the app's to delete.
* A reset must leave the app in a state the wizard can start from, including when the database is unreadable.
* The action must be hard to trigger by accident on a gamepad.
* One mechanism, reused: the pieces (database, media, credentials, preferences) should be clearable on their own later without a second implementation.

## Considered Options

* A "Reset NeoStation" row in Settings > About that wipes everything the app wrote, with a typed confirmation, and relaunches into the wizard
* The same, with a menu of partial resets (metadata, RomM, credentials) in the first version
* No in-app reset; document the platform way

## Decision Outcome

Chosen option: "A 'Reset NeoStation' row in About that wipes everything the app wrote", because it is the smallest thing that removes the need for a second device, and its implementation is a list of clearers that a later partial reset can pick from.

1. **What goes.** The database, the media cache (scraped art, the RomM cover cache), the log file, every credential the app stored, every `SharedPreferences` key the app wrote, and on Android the SAF grants the app holds. The custom user-data folder choice is forgotten too, so the wizard asks again; the folder itself and everything in it that the app did not create (ROMs, saves, BIOS) stay.
2. **What stays.** ROM files, save and state files, BIOS folders, and the System Art packs the user downloaded if they live outside the user-data folder. Downloads from RomM are ROM files and stay.
3. **How it is reached.** Settings > About, last row, below Export logs. Reachable by D-pad like every other row.
4. **Confirmation.** A dialog that names what will be deleted and what will be kept, and requires the user to type the word RESET (soft keyboard on Android, physical on desktop) before the destructive button enables. No hold-to-confirm: a held gamepad button is too easy to do by accident on a device in a bag.
5. **Afterwards.** The app does not try to run on from an empty state. On Android it finishes the activity and relaunches; on desktop it restarts the process where the platform allows and otherwise exits with a notice to start it again. The next launch runs the wizard.
6. **Order of operations.** Credentials and preferences first, then the database and caches, so a crash midway leaves a state that still restarts into the wizard rather than one with a database and no way to open it. Each clearer is independent and logs what it did and what it could not; one that fails does not stop the others.
7. **Mechanism.** A `ResetService` with one clearer per store and a `resetAll()` that runs them in that order. Partial resets, when wanted, are a menu over the same clearers and a separate decision.

### Consequences

* Good, because the wizard can be tested and a broken install recovered on the device.
* Good, because every store the app writes to is now enumerated in one place, which is also documentation.
* Bad, because a user who types RESET loses scraped metadata that took hours to fetch, with no partial option yet.
* Bad, because the Android SAF grants are released, so the wizard has to ask for the ROM folder again.
* Neutral, because the reset cannot clear what the app never wrote: an emulator's own config, RetroArch's folders, the NeoAssets packs outside the user-data folder.

### Confirmation

* Unit tests per clearer against temp directories and a fake credential backend; `resetAll` continues past a failing clearer and reports it.
* A widget test that the destructive button stays disabled until RESET is typed.
* On a device: reset, relaunch, the wizard runs, ROMs are still on disk, and the RomM tab asks to connect.

## Pros and Cons of the Options

### Reset everything with a typed confirmation

* Good, because small, and the typed word is the one confirmation a gamepad cannot produce by accident.
* Bad, because all-or-nothing.

### Partial resets in the first version

* Good, because "clear scraped metadata" and "forget RomM" are what troubleshooting usually wants.
* Bad, because each partial has its own consistency question (a cleared metadata table with RomM links still pointing at games) and deserves its own decision.

### No in-app reset

* Bad, because the handheld case stays unsolved.

## More Information

* Stores: `ConfigService.getUserDataPath`/`getMediaPath`/`getLogFilePath`, `UserDataLocationService.customPathKey`, `StartupThemeCache`, `GameSessionPersistence`, `CredentialStore.delete`, `RommCoverCache.directoryName`, Android `releasePersistableUriPermission`.
* Spec: SPEC-0021.
