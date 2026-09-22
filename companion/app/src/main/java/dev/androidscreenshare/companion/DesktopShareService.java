package dev.androidscreenshare.companion;

import android.app.Service;
import android.app.NotificationManager;
import android.content.Intent;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;

public final class DesktopShareService extends Service {
    public static final int NOTIFICATION_ID = 2316;
    public static final int DEFAULT_PORT = 27284;
    private static final long REFRESH_INTERVAL_MS = 5000L;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private Runnable notificationRefresh;
    private int currentPort = DEFAULT_PORT;

    private void showNotification() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.notify(
                NOTIFICATION_ID,
                ShareNotifications.create(
                        this,
                        "desktop",
                        currentPort,
                        1,
                        R.string.desktop_sharing));
    }

    @Override
    public void onCreate() {
        super.onCreate();
        ShareNotifications.ensureChannel(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        currentPort = intent == null
                ? DEFAULT_PORT
                : intent.getIntExtra("port", DEFAULT_PORT);
        getSharedPreferences("share_state", MODE_PRIVATE)
                .edit()
                .putInt("desktop_port", currentPort)
                .apply();
        startForeground(
                NOTIFICATION_ID,
                ShareNotifications.create(
                        this,
                        "desktop",
                        currentPort,
                        1,
                        R.string.desktop_sharing));
        if (notificationRefresh != null) {
            handler.removeCallbacks(notificationRefresh);
        }
        notificationRefresh = new Runnable() {
            @Override
            public void run() {
                showNotification();
                handler.postDelayed(this, REFRESH_INTERVAL_MS);
            }
        };
        handler.postDelayed(notificationRefresh, REFRESH_INTERVAL_MS);
        return START_REDELIVER_INTENT;
    }

    @Override
    public void onDestroy() {
        if (notificationRefresh != null) {
            handler.removeCallbacks(notificationRefresh);
        }
        stopForeground(true);
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
