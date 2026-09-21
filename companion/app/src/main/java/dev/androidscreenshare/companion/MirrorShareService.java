package dev.androidscreenshare.companion;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

public final class MirrorShareService extends Service {
    public static final int NOTIFICATION_ID = 2317;
    public static final int DEFAULT_PORT = 27285;

    @Override
    public void onCreate() {
        super.onCreate();
        ShareNotifications.ensureChannel(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        int port = intent == null
                ? DEFAULT_PORT
                : intent.getIntExtra("port", DEFAULT_PORT);
        startForeground(
                NOTIFICATION_ID,
                ShareNotifications.create(
                        this,
                        "mirror",
                        port,
                        2,
                        R.string.mirror_sharing));
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        stopForeground(true);
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
