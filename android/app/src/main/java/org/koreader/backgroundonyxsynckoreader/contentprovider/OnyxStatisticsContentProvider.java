package org.koreader.backgroundonyxsynckoreader.contentprovider;

import android.content.ContentProviderClient;
import android.content.ContentProviderOperation;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.net.Uri;
import android.util.Log;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * Inserts reading statistics into the Onyx ContentProvider.
 * <p>
 * URI: content://com.onyx.kreader.statistics.provider/OnyxStatisticsModel
 * <p>
 * To query the account info manually:
 * adb shell content query \
 * --uri content://com.onyx.account.database.ContentProvider.KSyncAccountContentProvider/OnyxAccountModel
 */
public class OnyxStatisticsContentProvider {

    private static final String TAG = "OnyxStatisticsProvider";

    // -------------------------------------------------------------------------
    // Public constants
    // -------------------------------------------------------------------------

    public static final Uri CONTENT_URI =
            Uri.parse("content://com.onyx.kreader.statistics.provider/OnyxStatisticsModel");

    /**
     * Reading sessions longer than this are capped (10 minutes, mirrors MAX_PAGE_DURATION_TIME).
     */
    public static final long MAX_PAGE_DURATION_MS = 600_000L;

    // Stat types (reverse-engineered from StatisticsUtils)
    public static final int TYPE_READ_TIME = 1;
    public static final int TYPE_ANNOTATION = 2;
    public static final int TYPE_FINISH = 6;

    public static final int TYPE_OPENED = 0;


    // Sync status
    public static final int STATUS_LOCAL = 0; // not yet pushed to server
    public static final int STATUS_PUSHED = 1; // synced

    // -------------------------------------------------------------------------
    // Column names
    // -------------------------------------------------------------------------

    private static final String COL_ACCOUNT_ID = "accountId";
    private static final String COL_DOC_ID = "docId";
    private static final String COL_MD5 = "md5";
    private static final String COL_NAME = "name";
    private static final String COL_TITLE = "title";
    private static final String COL_PATH = "path";
    private static final String COL_TYPE = "type";
    private static final String COL_STATUS = "status";
    private static final String COL_EVENT_TIME = "eventTime";
    private static final String COL_DURATION_TIME = "durationTime";
    private static final String COL_CURR_PAGE = "currPage";
    private static final String COL_LAST_PAGE = "lastPage";
    private static final String COL_READING_PROGRESS = "readingProgress";
    private static final String COL_POSITION = "position";
    private static final String COL_CHAPTER = "chapter";
    private static final String COL_ORG_TEXT = "orgText";
    private static final String COL_NOTE = "note";
    private static final String COL_COMMENT = "comment";
    private static final String COL_SCORE = "score";
    private static final String COL_HIDE_RECORD = "hideRecord";

    // -------------------------------------------------------------------------
    // StatEntry data class
    // -------------------------------------------------------------------------

    public static final class StatEntry {
        // Book identity
        public String docId;
        public String md5;
        public String title;
        public String name;
        public String path;

        // Session identity
        public String accountId;
        public String sid;
        public String action;

        // Event metadata
        public int type;
        public int status = STATUS_LOCAL;
        public long eventTime; // epoch ms

        // Reading progress
        public long durationTime;
        public Integer currPage;
        public Integer lastPage;
        public float readingProgress;

        // Position
        public String position;
        public String chapter;

        // Annotation fields
        public String orgText;
        public String note;
        public String comment;
        public Integer score;

        public boolean hideRecord = false;
    }

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------


    /**
     * Backfills all missing reading history for a book from KOReader's stats DB.
     * <p>
     * Called on every page turn so that any gaps (e.g. from sessions recorded before
     * this app was installed, or missed intents) are filled incrementally.
     * <p>
     * Flow:
     * 1. Fetch all (start_time, page, duration, total_pages) rows for this book from KOReader DB.
     * 2. Fetch all eventTime values already recorded in Onyx for this book path.
     * 3. Batch-insert only the rows whose start_time (×1000) is not already in Onyx.
     *
     * @param koReaderDbPath path to KOReader's shared statistics.sqlite
     * @param md5            file MD5 — used to resolve id_book in KOReader's DB
     * @param title          book title from KOReader
     * @param bookPath       absolute path to the book file — used as the Onyx path key
     */
    public static void syncBookHistory(Context context,
                                       String koReaderDbPath,
                                       String md5,
                                       String title,
                                       String bookPath) {

        OnyxMetatadaContentProvider.init(context);
        OnyxAccountContentProvider.init(context);

        OnyxMetatadaContentProvider metadataProvider = OnyxMetatadaContentProvider.getInstance();
        OnyxAccountContentProvider accountProvider = OnyxAccountContentProvider.getInstance();

        Optional<OnyxMetatadaContentProvider.BookDataQueryResult> bookDataOpt =
                metadataProvider.getBookDataQueryResult(bookPath);
        if (bookDataOpt.isEmpty()) {
            Log.w(TAG, "syncBookHistory: no Onyx metadata for " + bookPath);
            return;
        }

        Optional<String> accountIdOpt = accountProvider.getAccountId();
        if (accountIdOpt.isEmpty()) {
            Log.w(TAG, "syncBookHistory: no logged-in Onyx account");
            return;
        }

        String docId = bookDataOpt.get().uuid;
        String hashTag = bookDataOpt.get().hashTag;
        String accountId = accountIdOpt.get();

        // ------------------------------------------------------------------
        // 1. Load all KOReader rows for this book.
        // ------------------------------------------------------------------
        // Each row: (start_time seconds, page, duration seconds, total_pages)
        ArrayList<KoRow> koRows = new ArrayList<>();
        int canonicalTotalPages = 0;

        try (SQLiteDatabase db = SQLiteDatabase.openDatabase(
                koReaderDbPath, null, SQLiteDatabase.OPEN_READONLY)) {

            // Resolve id_book via MD5.
            long idBook = -1;
            try (Cursor c = db.rawQuery(
                    "SELECT id FROM book WHERE md5 = ?",
                    new String[]{md5})) {
                if (c.moveToFirst()) idBook = c.getLong(0);
            }

            if (idBook == -1) {
                Log.w(TAG, "syncBookHistory: no KOReader book row for md5=" + md5);
                return;
            }

            // Canonical total pages from book.pages.
            try (Cursor c = db.rawQuery(
                    "SELECT pages FROM book WHERE id = ?",
                    new String[]{String.valueOf(idBook)})) {
                if (c.moveToFirst() && c.getInt(0) > 0) {
                    canonicalTotalPages = c.getInt(0);
                }
            }

            // All page_stat_data rows for this book.
            try (Cursor c = db.rawQuery(
                    "SELECT start_time, page, duration, total_pages " +
                            "FROM page_stat_data " +
                            "WHERE id_book = ? " +
                            "ORDER BY start_time ASC",
                    new String[]{String.valueOf(idBook)})) {

                while (c.moveToNext()) {
                    koRows.add(new KoRow(
                            c.getLong(0),
                            c.getInt(1),
                            c.getLong(2),
                            c.getInt(3)
                    ));
                }
            }

        } catch (Exception e) {
            Log.e(TAG, "syncBookHistory: failed to read KOReader DB", e);
            return;
        }

        if (koRows.isEmpty()) {
            Log.d(TAG, "syncBookHistory: no KOReader rows for " + bookPath);
            return;
        }

        // ------------------------------------------------------------------
        // 2. Fetch all eventTime values already present in Onyx for this path.
        // ------------------------------------------------------------------
        Set<Long> existingEventTimes = new HashSet<>();
        try (Cursor c = context.getContentResolver().query(
                CONTENT_URI,
                new String[]{COL_EVENT_TIME},
                "path = ?",
                new String[]{bookPath},
                null)) {
            if (c != null) {
                while (c.moveToNext()) {
                    existingEventTimes.add(c.getLong(0));
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "syncBookHistory: could not query existing eventTimes — " +
                    "will fall back to per-row dedup", e);
        }

        // ------------------------------------------------------------------
        // 3. Build batch of missing inserts.
        // ------------------------------------------------------------------
        ArrayList<ContentProviderOperation> ops = new ArrayList<>();

        for (KoRow row : koRows) {
            long eventTimeMs = row.startTimeSec * 1000L;

            if (existingEventTimes.contains(eventTimeMs)) {
                continue; // already synced
            }

            int totalPages = canonicalTotalPages > 0 ? canonicalTotalPages : row.totalPages;
            float progress = totalPages > 0 ? (float) row.page / totalPages : 0f;
            long durationMs = Math.min(row.durationSec * 1000L, MAX_PAGE_DURATION_MS);

            StatEntry entry = new StatEntry();
            entry.accountId = accountId;
            entry.docId = docId;
            entry.md5 = hashTag;
            entry.title = title;
            entry.path = bookPath;
            entry.type = TYPE_READ_TIME;
            entry.eventTime = eventTimeMs;
            entry.durationTime = durationMs;
            entry.currPage = row.page;
            entry.lastPage = totalPages;
            entry.readingProgress = progress;
            entry.sid = UUID.randomUUID().toString();
            entry.action = "add";

            ops.add(ContentProviderOperation
                    .newInsert(CONTENT_URI)
                    .withValues(toContentValues(entry))
                    .build());
        }

        if (ops.isEmpty()) {
            Log.d(TAG, "syncBookHistory: nothing to backfill for " + bookPath);
            return;
        }

        // ------------------------------------------------------------------
        // 4. Apply batch.
        // ------------------------------------------------------------------
        try (ContentProviderClient client =
                     context.getContentResolver()
                             .acquireUnstableContentProviderClient(CONTENT_URI)) {

            if (client == null) {
                Log.e(TAG, "syncBookHistory: could not acquire ContentProviderClient");
                return;
            }

            client.applyBatch(ops);
            Log.i(TAG, "syncBookHistory: inserted " + ops.size()
                    + " missing rows for " + bookPath);

        } catch (Exception e) {
            Log.e(TAG, "syncBookHistory: batch insert failed", e);
        }
    }

    /**
     * Records that the user finished a book.
     * No-ops if a TYPE_FINISH entry already exists for this book.
     */
    public static void insertBookFinished(Context context,
                                          String title,
                                          String path,
                                          long timestamp) {
        OnyxMetatadaContentProvider.init(context);
        OnyxAccountContentProvider.init(context);

        OnyxMetatadaContentProvider metadataProvider = OnyxMetatadaContentProvider.getInstance();
        OnyxAccountContentProvider accountProvider = OnyxAccountContentProvider.getInstance();

        Optional<OnyxMetatadaContentProvider.BookDataQueryResult> bookDataOpt =
                metadataProvider.getBookDataQueryResult(path);
        if (bookDataOpt.isEmpty()) {
            Log.w(TAG, "Could not find book data for path: " + path);
            return;
        }

        Optional<String> accountIdOpt = accountProvider.getAccountId();
        if (accountIdOpt.isEmpty()) {
            Log.w(TAG, "Could not find accountId for logged in user");
            return;
        }

        // Dedup: skip if a TYPE_FINISH entry already exists for this book.
        try (Cursor c = context.getContentResolver().query(
                CONTENT_URI,
                new String[]{"id"},
                "docId = ? AND type = ?",
                new String[]{bookDataOpt.get().uuid, String.valueOf(TYPE_FINISH)},
                null)) {
            if (c != null && c.moveToFirst()) {
                Log.d(TAG, "TYPE_FINISH already exists for " + path + " — skipping");
                return;
            }
        } catch (Exception e) {
            Log.w(TAG, "Dedup query for TYPE_FINISH failed — proceeding with insert", e);
        }

        StatEntry entry = new StatEntry();
        entry.accountId = accountIdOpt.get();
        entry.docId = bookDataOpt.get().uuid;
        entry.md5 = bookDataOpt.get().hashTag;
        entry.title = title;
        entry.path = path;
        entry.name = title;
        entry.type = TYPE_FINISH;
        entry.eventTime = timestamp;
        entry.sid = UUID.randomUUID().toString();
        entry.action = "add";

        insert(context, entry);
    }

    public static void insertBookOpened(Context context,
                                        String title,
                                        String path,
                                        long timestamp) {
        OnyxMetatadaContentProvider.init(context);
        OnyxAccountContentProvider.init(context);

        OnyxMetatadaContentProvider metadataProvider = OnyxMetatadaContentProvider.getInstance();
        OnyxAccountContentProvider accountProvider = OnyxAccountContentProvider.getInstance();

        Optional<OnyxMetatadaContentProvider.BookDataQueryResult> bookDataOpt =
                metadataProvider.getBookDataQueryResult(path);
        if (bookDataOpt.isEmpty()) {
            Log.w(TAG, "Could not find book data for path: " + path);
            return;
        }

        Optional<String> accountIdOpt = accountProvider.getAccountId();
        if (accountIdOpt.isEmpty()) {
            Log.w(TAG, "Could not find accountId for logged in user");
            return;
        }

        // Dedup: skip if a TYPE_OPENED entry already exists for this book.
        try (Cursor c = context.getContentResolver().query(
                CONTENT_URI,
                new String[]{"id"},
                "docId = ? AND type = ?",
                new String[]{bookDataOpt.get().uuid, String.valueOf(TYPE_OPENED)},
                null)) {
            if (c != null && c.moveToFirst()) {
                Log.d(TAG, "TYPE_OPENED already exists for " + path + " — skipping");
                return;
            }
        } catch (Exception e) {
            Log.w(TAG, "Dedup query for TYPE_OPENED failed — proceeding with insert", e);
        }

        StatEntry entry = new StatEntry();
        entry.accountId = accountIdOpt.get();
        entry.docId = bookDataOpt.get().uuid;
        entry.md5 = bookDataOpt.get().hashTag;
        entry.title = title;
        entry.path = path;
        entry.name = title;
        entry.type = TYPE_OPENED;
        entry.eventTime = timestamp;
        entry.sid = UUID.randomUUID().toString();
        entry.action = "add";

        insert(context, entry);
    }

    /**
     * Inserts a raw {@link StatEntry} into the ContentProvider.
     */
    public static Uri insert(Context context, StatEntry entry) {
        return context.getContentResolver().insert(CONTENT_URI, toContentValues(entry));
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    private static ContentValues toContentValues(StatEntry e) {
        if (e.eventTime == 0) {
            e.eventTime = System.currentTimeMillis();
        }

        ContentValues cv = new ContentValues();

        cv.put(COL_TYPE, e.type);
        cv.put(COL_STATUS, e.status);
        cv.put(COL_EVENT_TIME, e.eventTime);
        cv.put(COL_DURATION_TIME, e.durationTime);
        cv.put(COL_READING_PROGRESS, e.readingProgress);
        cv.put(COL_HIDE_RECORD, e.hideRecord ? 1 : 0);

        putIfNotNull(cv, COL_ACCOUNT_ID, e.accountId);
        putIfNotNull(cv, COL_DOC_ID, e.docId);
        putIfNotNull(cv, COL_MD5, e.md5);
        putIfNotNull(cv, COL_NAME, e.name);
        putIfNotNull(cv, COL_TITLE, e.title);
        putIfNotNull(cv, COL_PATH, e.path);
        putIfNotNull(cv, COL_POSITION, e.position);
        putIfNotNull(cv, COL_CHAPTER, e.chapter);
        putIfNotNull(cv, COL_ORG_TEXT, e.orgText);
        putIfNotNull(cv, COL_NOTE, e.note);
        putIfNotNull(cv, COL_COMMENT, e.comment);

        if (e.currPage != null) cv.put(COL_CURR_PAGE, e.currPage);
        if (e.lastPage != null) cv.put(COL_LAST_PAGE, e.lastPage);
        if (e.score != null) cv.put(COL_SCORE, e.score);

        return cv;
    }

    private static void putIfNotNull(ContentValues cv, String key, String value) {
        if (value != null) cv.put(key, value);
    }

    private static final class KoRow {
        final long startTimeSec;
        final int page;
        final long durationSec;
        final int totalPages;

        KoRow(long startTimeSec, int page, long durationSec, int totalPages) {
            this.startTimeSec = startTimeSec;
            this.page = page;
            this.durationSec = durationSec;
            this.totalPages = totalPages;
        }
    }
}