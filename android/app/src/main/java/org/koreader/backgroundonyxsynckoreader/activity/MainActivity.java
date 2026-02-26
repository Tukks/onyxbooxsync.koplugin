package org.koreader.backgroundonyxsynckoreader.activity;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.provider.Settings;
import android.util.Log;

public class MainActivity extends Activity {
    private static final String TAG = "MainActivity";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        if (needsAllFilesPermission()) {
            showAllFilesPermissionDialog();
        } else {
            Log.i(TAG, "All files access already granted");
            finish();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        // User came back from the system settings screen — check if they granted it.
        if (hasAllFilesPermission()) {
            Log.i(TAG, "All files access granted");
            finish();
        }
        // If still not granted, leave the dialog visible (they may still be deciding).
    }

    // -------------------------------------------------------------------------

    private boolean needsAllFilesPermission() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !hasAllFilesPermission();
    }

    private boolean hasAllFilesPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager();
        }
        return true; // below API 30 READ_EXTERNAL_STORAGE is enough; declare it in manifest
    }

    private void showAllFilesPermissionDialog() {
        new AlertDialog.Builder(this)
                .setTitle("Storage permission required")
                .setMessage(
                        "This app needs access to all files to read KOReader's statistics " +
                                "database and sync your reading history to your Onyx account.\n\n" +
                                "Please enable \"Allow access to manage all files\" on the next screen.")
                .setPositiveButton("Open settings", (d, w) -> openAllFilesSettings())
                .setNegativeButton("Cancel", (d, w) -> {
                    Log.w(TAG, "User declined all-files permission");
                    finish();
                })
                .setCancelable(false)
                .show();
    }

    private void openAllFilesSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                Intent intent = new Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:" + getPackageName()));
                startActivity(intent);
            } catch (Exception e) {
                // Fallback: open the general manage-all-files screen
                Log.w(TAG, "Could not open app-specific settings, falling back", e);
                startActivity(new Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION));
            }
        }
    }
}