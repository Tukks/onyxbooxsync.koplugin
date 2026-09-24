package org.koreader.backgroundonyxsynckoreader.helper;

import android.content.BroadcastReceiver;
import android.util.Log;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Runs receiver work off the main thread.
 * <p>
 * A single worker thread serializes all syncs, so concurrent page turns can't
 * both see the same rows as missing and insert them twice.
 */
public final class BackgroundWork {

    private static final String TAG = "BackgroundWork";

    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();

    private BackgroundWork() {
    }

    /**
     * Must be called from {@link BroadcastReceiver#onReceive}. Keeps the receiver
     * alive until {@code work} finishes.
     */
    public static void run(BroadcastReceiver receiver, Runnable work) {
        final BroadcastReceiver.PendingResult pendingResult = receiver.goAsync();
        EXECUTOR.execute(() -> {
            try {
                work.run();
            } catch (Throwable t) {
                Log.e(TAG, "Background work failed", t);
            } finally {
                pendingResult.finish();
            }
        });
    }
}
