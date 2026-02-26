package org.koreader.backgroundonyxsynckoreader.contentprovider;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.util.Log;

import java.util.Optional;

public class OnyxAccountContentProvider {
    private static final String TAG = "OnyxAccountProvider";

    private static final Uri ACCOUNT_URI = Uri.parse(
            "content://com.onyx.account.database.ContentProvider.KSyncAccountContentProvider/OnyxAccountModel"
    );

    private static OnyxAccountContentProvider instance;

    private final ContentResolver resolver;

    private OnyxAccountContentProvider(Context context) {
        this.resolver = context.getApplicationContext().getContentResolver();
    }

    public static void init(Context context) {
        if (instance == null) {
            instance = new OnyxAccountContentProvider(context);
        }
    }

    public static OnyxAccountContentProvider getInstance() {
        if (instance == null) throw new IllegalStateException("Call init() first");
        return instance;
    }

    public Optional<String> getAccountId() {
        Cursor cursor = null;
        try {
            cursor = this.resolver.query(
                    ACCOUNT_URI,
                    new String[]{"accountId"},
                    "loggedIn = ?", new String[]{"1"}, null
            );

            if (cursor == null || cursor.getCount() == 0) {
                return Optional.empty();
            }

            cursor.moveToFirst();
            return Optional.ofNullable(cursor.getString(0));
        } catch (Exception e) {
            Log.w(TAG, "getAccountId error: " + e.getMessage());
        } finally {
            if (cursor != null) {
                cursor.close();
            }
        }
        return Optional.empty();
    }
}
