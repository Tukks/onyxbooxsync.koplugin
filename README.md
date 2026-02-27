# Onyx Progress Sync

Syncs KOReader reading progress and statistics into the Onyx Boox library so progress and reading time stay visible in the Onyx library and Onyx account.

## Features

- Updates Onyx metadata with in-flow page/total pages.
- Marks the book as reading, unopened or finished and updates last access timestamp.
- Records reading time per page into Onyx reading statistics.
- Backfills full reading history from KOReader's statistics database on every page turn.
- Debounced syncing on page turns plus immediate sync on lifecycle events.

## Requirements

- KOReader on an Android-based Onyx device.
- The **All files access** (`MANAGE_EXTERNAL_STORAGE`) permission must be granted to the companion app once — required to read KOReader's statistics database.

## How It Works

The plugin communicates with a small companion app running as a background service. This is necessary because KOReader's JNI bridge is not stable enough to write to the Onyx content provider directly from Lua. The companion app has no UI — it runs silently in the background and handles all content provider writes on behalf of the plugin.

### Reading Statistics

On every page turn, the companion app reads KOReader's `statistics.sqlite3` database and syncs any missing reading sessions into the Onyx statistics provider. This means:

- **Live tracking**: each page turn is recorded with its duration and reading progress.
- **Automatic backfill**: any sessions recorded before the app was installed are synced incrementally, so your full reading history appears in your Onyx account without any manual migration step.
- **Duplicate prevention**: sessions already present in Onyx (matched by timestamp) are never inserted twice.
- **Book opened/finished events**: recorded automatically when KOReader reports the book status as reading or complete.

## Installation

### 1. Companion App

1. Download and install `onyx-sync.apk` from the [latest release](../../releases/latest).
2. Long press the app icon on the home screen and tap **Unfreeze** — Onyx freezes newly installed apps by default, which would prevent the service from running in the background.
3. Launch the app once — a permission dialog will appear asking for **All files access**. Grant it so the app can read KOReader's statistics database. Nothing else will appear on screen; the app will close automatically.

### 2. Plugin

1. Create the folder `koreader/plugins/onyx_sync.koplugin` on your device.
2. Copy `main.lua` and `_meta.lua` into the folder.
3. Restart KOReader.
4. Ensure the plugin is enabled in KOReader settings.

## When It Syncs

### Progress & metadata
- On page updates (debounced, ~3s).
- When a document is closed.
- When settings are saved.
- When the app is suspended (sent to background).
- When end of book is reached.

### Reading statistics
- On every page turn — records the duration spent on the previous page and backfills any missing history for the current book.
- When a book is marked as finished — inserts a completion event with the last-read timestamp.
- When a book is opened/reading — inserts an opened event.

### Bulk update
- When **Scan and update all books** is triggered manually — syncs progress metadata and full reading history for every book in the current directory.

## Notes

- Only runs on Android devices (no effect on other platforms).
- Only tested on Boox Go 7.
- Completion is detected from KOReader summary status or when the last page in the main flow is reached.
- The companion app has no UI. Launching it once is only needed to grant the storage permission and initialize the background service.
- Reading time shown in your Onyx account may differ slightly from KOReader's own statistics screen if the book was previously opened in the native Onyx reader — those sessions are counted in Onyx but not in KOReader.

## Bulk Update

The plugin adds a menu entry under **Onyx Progress Sync → Scan and update all books in current directory** in KOReader's FILE BROWSER menu (only visible in the library).

This scans the current folder and pushes progress and reading history for every book, so the Onyx library shows up-to-date percentages, reading statuses and statistics without having to open each book individually.

![menu](/asset/librarymenudetail.png)

## ADB Cheat-Sheet

**Query all Onyx metadata (reading progress)**
```sh
adb shell content query --uri content://com.onyx.content.database.ContentProvider/Metadata
```

**Query Onyx reading statistics**
```sh
adb shell content query --uri content://com.onyx.kreader.statistics.provider/OnyxStatisticsModel
```

**Query statistics for a specific book**
```sh
adb shell content query \
  --uri content://com.onyx.kreader.statistics.provider/OnyxStatisticsModel \
  --projection "id,eventTime,durationTime,type,path" | grep "YourBookName"
```

**Deploy the plugin during development**
```sh
adb push ./main.lua /sdcard/koreader/plugins/onyx_sync.koplugin/main.lua
```

**View companion app logs**
```sh
adb logcat -s OnyxStatisticsProvider:* PageTurnReceiver:* SyncReceiver:*
```

**View plugin logs**
```sh
adb logcat -s KOReader:*
```


## Troubleshooting

**Books not showing up in the Onyx library after a bulk update**

The Onyx library needs to be rescanned to pick up newly indexed books:

1. Open the Onyx Library app.
2. Tap the menu icon in the upper right corner.
3. Go to **Library Settings → Select folders → Rescan** (upper right corner).
4. Come back to KOReader and run **Scan and update all books in current directory** again.

## License

MIT. See [LICENSE](LICENSE).