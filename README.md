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

## How It Works
The plugin uses Android JNI calls to update the Onyx content provider:
- `content://com.onyx.content.database.ContentProvider/Metadata`
- Updates or inserts a row keyed by `nativeAbsolutePath`.
- Only syncs when the current page is in the main flow (skips footnotes and cover flows).

## When It Syncs
- On page updates (debounced, ~3s).
- When a document is closed.
- When settings are saved.
- When the app is suspended (sent to background).
- When end of book is reached.

## Notes
- Only runs on Android devices (no effect on other platforms).
- If the Onyx provider row does not exist, the plugin inserts it.
- Completion is detected from KOReader summary status or when the last page in the main flow is reached.

## License
MIT. See [LICENSE](LICENSE).
