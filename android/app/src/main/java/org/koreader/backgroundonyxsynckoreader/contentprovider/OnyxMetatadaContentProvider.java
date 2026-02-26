package org.koreader.backgroundonyxsynckoreader.contentprovider;

import android.content.ContentProviderClient;
import android.content.ContentProviderOperation;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.res.Resources;
import android.database.Cursor;
import android.net.Uri;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

public class OnyxMetatadaContentProvider {

    private static final String TAG = "OnyxContentProvider";
    private static final Uri METADATA_URI = Uri.parse(
            "content://com.onyx.content.database.ContentProvider/Metadata"
    );

    private static OnyxMetatadaContentProvider instance;

    private final ContentResolver resolver;

    private OnyxMetatadaContentProvider(Context context) {
        this.resolver = context.getApplicationContext().getContentResolver();
    }

    public static void init(Context context) {
        if (instance == null) {
            instance = new OnyxMetatadaContentProvider(context);
        }
    }

    public static OnyxMetatadaContentProvider getInstance() {
        if (instance == null) throw new IllegalStateException("Call init() first");
        return instance;
    }

    public boolean syncProgress(String path, String progress, Long timestamp, int readingStatus) {
        Log.d(TAG, "syncProgress: " + path + " -> " + progress + " status=" + readingStatus);
        try {
            if (path == null) return false;
            int rows = blindUpdate(path, progress, timestamp, readingStatus);
            if (rows > 0) {
                Log.i(TAG, "Updated " + rows + " row(s)");
                return true;
            }
            Log.w(TAG, "No rows updated - book not in Onyx database: " + path);
            return false;
        } catch (Throwable e) {
            Log.e(TAG, "syncProgress error: " + e.getMessage(), e);
            return false;
        }
    }

    public int batchSync(List<BookDataInsertRequest> books) {
        int updated = 0;
        try (ContentProviderClient client = resolver.acquireUnstableContentProviderClient(METADATA_URI)) {
            if (client == null) {
                Log.e(TAG, "batchSync: could not acquire ContentProviderClient");
                return 0;
            }
            var operation = new ArrayList<ContentProviderOperation>();
            for (BookDataInsertRequest book : books) {
                operation.add(ContentProviderOperation
                        .newUpdate(METADATA_URI)
                        .withValues(book.toContentValues())
                        .withSelection("nativeAbsolutePath = ?", new String[]{book.path}).build());

            }
            client.applyBatch(
                    operation);

        } catch (Exception e) {
            Log.e(TAG, "batchSync error", e);
        }
        return updated;
    }

    private int blindUpdate(String path, String progress, Long timestamp, int readingStatus) {
        try (ContentProviderClient client = resolver.acquireUnstableContentProviderClient(METADATA_URI)) {
            if (client == null) {
                Log.w(TAG, "blindUpdate: could not acquire ContentProviderClient");
                return -1;
            }

            ContentValues values = new ContentValues();
            values.put("progress", progress);
            values.put("readingStatus", readingStatus);
            values.put("lastAccess", timestamp);

            int rows = client.update(METADATA_URI, values, "nativeAbsolutePath = ?", new String[]{path});
            Log.d(TAG, "blindUpdate: " + rows + " row(s)");
            return rows;
        } catch (Exception e) {
            Log.w(TAG, "blindUpdate failed: " + e.getMessage());
            return -1;
        }
    }

    /**
     * Debug method
     */
    public void logAllBooks() {
        ContentProviderClient client = null;
        Cursor cursor = null;
        try {
            client = resolver.acquireUnstableContentProviderClient(METADATA_URI);
            if (client == null) {
                Log.w(TAG, "logAllBooks: could not acquire ContentProviderClient");
                return;
            }
            cursor = client.query(
                    METADATA_URI,
                    new String[]{"id", "name", "nativeAbsolutePath", "hashTag", "uuid"},
                    null, null, null
            );
            if (cursor == null) {
                Log.w(TAG, "logAllBooks: cursor is null");
                return;
            }
            Log.i(TAG, "logAllBooks: " + cursor.getCount() + " row(s) found");
            while (cursor.moveToNext()) {
                String id = cursor.getString(0);
                String name = cursor.getString(1);
                String p = cursor.getString(2);
                String md5 = cursor.getString(3);
                String uuid = cursor.getString(4);
                Log.i(TAG, "  [" + id + "] " + name + " -> " + p + "md5=" + md5 + " uuid=" + uuid);
            }
        } catch (Exception e) {
            Log.w(TAG, "logAllBooks error: " + e.getMessage());
        } finally {
            if (cursor != null) try {
                cursor.close();
            } catch (Exception ignored) {
            }
            if (client != null) client.close();
        }
    }

    public Optional<BookDataQueryResult> getBookDataQueryResult(String path) {
        Cursor cursor = null;
        try {

            cursor = this.resolver.query(
                    METADATA_URI,
                    new String[]{"hashTag", "uuid", "nativeAbsolutePath", "progress", "readingStatus"},
                    "nativeAbsolutePath = ?", new String[]{path}, null
            );

            if (cursor == null) {
                throw new Resources.NotFoundException();
            }

            Log.i(TAG, "getBookDataQueryResult: " + cursor.getCount() + " row(s) found");
            cursor.moveToFirst();
            return Optional.of(new BookDataQueryResult(cursor.getString(0),
                    cursor.getString(1), cursor.getString(2),
                    cursor.getString(3), cursor.getInt(4)));

        } catch (Exception e) {
            Log.w(TAG, "logAllBooks error: " + e.getMessage());
        }
        return Optional.empty();
    }

    public static class BookDataInsertRequest {
        public String path;
        public String progress;
        public long timestamp;
        public int readingStatus;

        public ContentValues toContentValues() {
            ContentValues values = new ContentValues();
            values.put("readingStatus", readingStatus);
            if (readingStatus != 0) {
                values.put("progress", progress);
                values.put("lastAccess", timestamp);
            } else {
                values.putNull("progress");
                values.putNull("lastAccess");
            }
            return values;
        }
    }


    public static class BookDataQueryResult {
        public String hashTag;
        public String uuid;
        public String path;
        public String progress;
        public int readingStatus;

        public BookDataQueryResult(String hashTag, String uuid, String path, String progress, int readingStatus) {
            this.hashTag = hashTag;
            this.uuid = uuid;
            this.path = path;
            this.progress = progress;
            this.readingStatus = readingStatus;
        }
    }
}
