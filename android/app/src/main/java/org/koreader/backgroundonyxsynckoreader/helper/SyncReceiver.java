package org.koreader.backgroundonyxsynckoreader.helper;

import static org.koreader.backgroundonyxsynckoreader.helper.PageTurnReceiver.sDbPath;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.PowerManager;
import android.text.TextUtils;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

import org.koreader.backgroundonyxsynckoreader.contentprovider.OnyxMetatadaContentProvider;
import org.koreader.backgroundonyxsynckoreader.contentprovider.OnyxStatisticsContentProvider;

public class SyncReceiver extends BroadcastReceiver {
    private static final String TAG = "SyncReceiver";
    public static final String ACTION_SINGLE = "org.koreader.onyx.SYNC_PROGRESS";
    public static final String ACTION_BULK = "org.koreader.onyx.BULK_SYNC";
    public static final String EXTRA_BOOKS_JSON = "bookData";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null) {
            Log.w(TAG, "Intent is null");
            return;
        }

        if (TextUtils.isEmpty(intent.getAction())) {
            Log.w(TAG, "Action is empty");
            return;
        }

        PowerManager powerManager = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        PowerManager.WakeLock wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,
                "BackgroundOnyxSyncKOReader::SyncWakelock");
        wakeLock.acquire(60 * 1000L /* 1 minute */);

        try {
            onHandleWork(context, intent);
            Log.i(TAG, "Finish update");
        } catch (Exception e) {
            Log.e(TAG, "Error in onReceive", e);
        } finally {
            wakeLock.release();
        }
    }

    protected static void onHandleWork(Context applicationContext, Intent intent) {
        OnyxMetatadaContentProvider.init(applicationContext);

        String action = intent.getAction();
        Log.i(TAG, "Handling action: " + action);

        if (ACTION_SINGLE.equals(action)) {
            handleSingleSync(applicationContext, intent);
        } else if (ACTION_BULK.equals(action)) {
            handleBulkSync(applicationContext, intent);
        } else {
            Log.w(TAG, "Unknown action: " + action);
        }
    }

    private static void handleSingleSync(Context applicationContext, Intent intent) {
        String path = intent.getStringExtra("path");
        String progress = intent.getStringExtra("progress");
        Long timestamp = intent.getLongExtra("timestamp", System.currentTimeMillis());
        String title = intent.getStringExtra("title");

        int status = intent.getIntExtra("readingStatus", 1);
        if (status == 0) {
            timestamp = null;
            progress = null;
        }
        Log.d(TAG, "Single sync: path=" + path + " progress=" + progress
                + " timestamp=" + timestamp + " status=" + status);

        if (TextUtils.isEmpty(path)) {
            Log.w(TAG, "Single sync with empty path");
            return;
        }

        try {
            boolean ok = OnyxMetatadaContentProvider.getInstance().syncProgress(path, progress, timestamp, status);
            if (status == 2) {
                OnyxStatisticsContentProvider
                        .insertBookFinished(applicationContext, title, path, timestamp);
            } else if (status == 1) {
                OnyxStatisticsContentProvider
                        .insertBookOpened(applicationContext, title, path, timestamp);
            }
            // Force refresh of onyx widget
            applicationContext.sendBroadcast(new Intent("com.onyx.statisticswidget.action.UPDATE"));
            Log.i(TAG, "Single sync " + path + " -> " + (ok ? "OK" : "FAIL"));
        } catch (Exception e) {
            Log.e(TAG, "Error in single sync", e);
        }
    }

    private static void handleBulkSync(Context applicationContext, Intent intent) {
        String jsonStr = intent.getStringExtra(EXTRA_BOOKS_JSON);

        if (TextUtils.isEmpty(jsonStr)) {
            Log.w(TAG, "Bulk sync with no JSON data");
            return;
        }

        List<OnyxMetatadaContentProvider.BookDataInsertRequest> books = new ArrayList<>();
        try {
            JSONArray array = new JSONArray(jsonStr);
            Log.i(TAG, "Parsing " + array.length() + " books from JSON");

            for (int i = 0; i < array.length(); i++) {
                JSONObject obj = array.getJSONObject(i);
                OnyxMetatadaContentProvider.BookDataInsertRequest book = new OnyxMetatadaContentProvider.BookDataInsertRequest();
                book.path = obj.optString("path");
                book.progress = obj.optString("progress");
                book.timestamp = obj.optLong("timestamp", System.currentTimeMillis());
                book.readingStatus = obj.optInt("readingStatus", 1);
                book.md5 = obj.optString("md5");
                book.title = obj.optString("title");
                if (!TextUtils.isEmpty(book.path)) {
                    books.add(book);
                    Log.d(TAG, "Bulk book: " + book.path + " (" + book.progress + ")");
                }
            }
        } catch (JSONException e) {
            Log.e(TAG, "Bulk sync JSON parse error", e);
            return;
        }

        try {
            int updated = OnyxMetatadaContentProvider.getInstance().batchSync(books);
            books.forEach(book -> OnyxStatisticsContentProvider
                    .syncBookHistory(applicationContext, sDbPath, book.md5, book.title, book.path));
            books.stream()
                    .filter(bookDataInsertRequest -> bookDataInsertRequest.readingStatus == 2)
                    .filter(req ->
                            req.title != null && !req.title.trim().isEmpty()
                    ).forEach(book -> OnyxStatisticsContentProvider
                            .insertBookFinished(applicationContext, book.title, book.path, book.timestamp));
            books.stream()
                    .filter(bookDataInsertRequest -> bookDataInsertRequest.readingStatus == 1)
                    .filter(req ->
                            req.title != null && !req.title.trim().isEmpty()
                    )
                    .forEach(book -> OnyxStatisticsContentProvider
                            .insertBookOpened(applicationContext, book.title, book.path, book.timestamp));

            // Force refresh of onyx widget
            applicationContext.sendBroadcast(new Intent("com.onyx.statisticswidget.action.UPDATE"));
            Log.i(TAG, "Bulk sync updated " + updated + " of " + books.size() + " books");
        } catch (
                Exception e) {
            Log.e(TAG, "Error in bulk sync", e);
        }
    }
}
