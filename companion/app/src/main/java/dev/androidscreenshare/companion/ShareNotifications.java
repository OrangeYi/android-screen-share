package dev.androidscreenshare.companion;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;

final class ShareNotifications {
    static final String CHANNEL_ID = "screen_share";

    private ShareNotifications() {}

    static void ensureChannel(Context context) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.channel_name),
                NotificationManager.IMPORTANCE_LOW);
        channel.setDescription(context.getString(R.string.channel_description));
        channel.setSound(null, null);
        channel.enableVibration(false);
        manager.createNotificationChannel(channel);
    }

    static Notification create(
            Context context,
            String mode,
            int port,
            int requestCode,
            int textResource) {
        Intent stopIntent = new Intent(context, StopReceiver.class)
                .setAction("dev.androidscreenshare.companion.STOP")
                .putExtra("mode", mode)
                .putExtra("port", port);
        PendingIntent stopPendingIntent = PendingIntent.getBroadcast(
                context,
                requestCode,
                stopIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Intent statusIntent = new Intent(context, StatusActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent statusPendingIntent = PendingIntent.getActivity(
                context,
                requestCode + 100,
                statusIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Action stopAction = new Notification.Action.Builder(
                android.R.drawable.ic_menu_close_clear_cancel,
                context.getString(R.string.stop_sharing),
                stopPendingIntent).build();

        return new Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_screen_share)
                .setContentTitle(context.getString(R.string.notification_title))
                .setContentText(context.getString(textResource))
                .setContentIntent(statusPendingIntent)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(true)
                .addAction(stopAction)
                .build();
    }
}
