package org.koreader.backgroundonyxsynckoreader.helper;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

import org.koreader.backgroundonyxsynckoreader.contentprovider.OnyxStatisticsContentProvider;
// Todo add intent book finished
// todo add sync on book finished
public class PageTurnReceiver extends BroadcastReceiver {

    private static final String TAG = "PageTurnReceiver";
    public static final String ACTION_PAGE_TURN = "org.koreader.onyx.PAGE_TURN";

    /**
     * Path to KOReader's shared statistics SQLite database.
     */
    public static final String sDbPath = "/storage/emulated/0/koreader/settings/statistics.sqlite3";


    // -------------------------------------------------------------------------

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!ACTION_PAGE_TURN.equals(intent.getAction())) return;

        // Intent extras sent by KOReader on every page turn:
        //   book_path — absolute path to the book file
        //   md5       — MD5 hash of the book file (matches book.md5 in KOReader's DB)
        //   title     — book title from KOReader
        final String bookPath = intent.getStringExtra("book_path");
        final String md5      = intent.getStringExtra("md5");
        final String title    = intent.getStringExtra("title");

        if (bookPath == null || md5 == null) {
            Log.e(TAG, "Missing required extras: book_path or md5");
            return;
        }

        // Sync all missing history for this book from KOReader's DB into Onyx.
        // This handles both the current page turn and any historical gaps
        // (e.g. sessions recorded before this app was installed).
        OnyxStatisticsContentProvider.syncBookHistory(
                context,
                sDbPath,
                md5,
                title != null ? title : "",
                bookPath
        );
    }
}