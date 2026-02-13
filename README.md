# Onyx Progress Sync

Syncs KOReader reading progress into the Onyx Android content provider so progress stays visible in the Onyx library.

## Features
- Updates Onyx metadata with in-flow page/total pages.
- Marks the book as reading or finished and updates last access timestamp.
- Debounced syncing on page turns plus immediate sync on lifecycle events.

## Requirements
- KOReader on an Android-based Onyx device.
- Access to the Onyx content provider (available on Onyx Android builds).

## Installation
1. Copy this folder into your KOReader `plugins` directory.
2. Restart KOReader.
3. Ensure the plugin is enabled in KOReader settings.

## When It Syncs
- On page updates (debounced, ~3s).
- When a document is closed.
- When settings are saved.
- When the app is suspended (sent to background).
- When end of book is reached.

## Notes
- Only runs on Android devices (no effect on other platforms).
- Only tested on Boox Go 7.
- If the Onyx provider row does not exist, the plugin inserts it.
- Completion is detected from KOReader summary status or when the last page in the main flow is reached.

## Bulk Update

The plugin adds a menu entry under **Onyx Progress Sync → Update all books in Onyx library** in KOReader's main menu (☰).
This scans your entire reading history and pushes progress for every book that has been opened at least once, so the Onyx library shows up-to-date percentages and reading statuses without having to open each book individually.

## ADB Cheat-Sheet

**Query all Onyx metadata (reading progress)**

```sh
adb shell content query --uri content://com.onyx.content.database.ContentProvider/Metadata
```

**Query Onyx reading statistics**

```sh
adb shell content query --uri content://com.onyx.kreader.statistics.provider/OnyxStatisticsModel
```

**Deploy the plugin during development**

```sh
adb push ./main.lua /sdcard/koreader/plugins/onyx_sync.koplugin/main.lua
```

**View plugin logs**

```sh
adb logcat -s KOReader:*
```

## License
MIT. See [LICENSE](LICENSE).
