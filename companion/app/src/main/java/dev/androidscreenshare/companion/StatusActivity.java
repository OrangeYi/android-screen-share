package dev.androidscreenshare.companion;

import android.app.Activity;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.provider.Settings;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class StatusActivity extends Activity {
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private TextView statusText;
    private Button stopMirrorButton;
    private Button stopDesktopButton;
    private int mirrorPort = MirrorShareService.DEFAULT_PORT;
    private int desktopPort = DesktopShareService.DEFAULT_PORT;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(padding, padding, padding, padding);
        layout.setBackgroundColor(Color.WHITE);

        TextView title = new TextView(this);
        title.setText(R.string.status_title);
        title.setTextSize(24);
        title.setTextColor(Color.BLACK);
        layout.addView(title);

        statusText = new TextView(this);
        statusText.setText(R.string.status_checking);
        statusText.setTextSize(17);
        statusText.setTextColor(Color.DKGRAY);
        statusText.setPadding(0, padding, 0, padding);
        layout.addView(statusText);

        Button refreshButton = new Button(this);
        refreshButton.setText(R.string.refresh_status);
        refreshButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                refreshStatus();
            }
        });
        layout.addView(refreshButton);

        stopMirrorButton = new Button(this);
        stopMirrorButton.setText(R.string.stop_mirror);
        stopMirrorButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                requestStop("mirror", mirrorPort);
            }
        });
        layout.addView(stopMirrorButton);

        stopDesktopButton = new Button(this);
        stopDesktopButton.setText(R.string.stop_desktop);
        stopDesktopButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                requestStop("desktop", desktopPort);
            }
        });
        layout.addView(stopDesktopButton);

        Button notificationSettingsButton = new Button(this);
        notificationSettingsButton.setText(R.string.notification_settings);
        notificationSettingsButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                Intent intent = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName());
                startActivity(intent);
            }
        });
        layout.addView(notificationSettingsButton);

        setContentView(layout);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshStatus();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        refreshStatus();
    }

    @Override
    protected void onDestroy() {
        executor.shutdownNow();
        super.onDestroy();
    }

    private void refreshStatus() {
        statusText.setText(R.string.status_checking);
        stopMirrorButton.setEnabled(false);
        stopDesktopButton.setEnabled(false);
        mirrorPort = getSharedPreferences("share_state", MODE_PRIVATE)
                .getInt("mirror_port", MirrorShareService.DEFAULT_PORT);
        desktopPort = getSharedPreferences("share_state", MODE_PRIVATE)
                .getInt("desktop_port", DesktopShareService.DEFAULT_PORT);
        final int checkedMirrorPort = mirrorPort;
        final int checkedDesktopPort = desktopPort;
        executor.execute(new Runnable() {
            @Override
            public void run() {
                final boolean mirrorActive = isComputerChannelActive(checkedMirrorPort);
                final boolean desktopActive = isComputerChannelActive(checkedDesktopPort);
                final boolean notificationsEnabled = areShareNotificationsEnabled();
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        StringBuilder result = new StringBuilder();
                        result.append(getString(mirrorActive
                                ? R.string.mirror_active
                                : R.string.mirror_inactive));
                        result.append("\n");
                        result.append(getString(desktopActive
                                ? R.string.desktop_active
                                : R.string.desktop_inactive));
                        result.append("\n\n");
                        result.append(getString(notificationsEnabled
                                ? R.string.notifications_enabled
                                : R.string.notifications_disabled));
                        if (!mirrorActive && !desktopActive) {
                            result.append("\n\n").append(getString(R.string.no_share_advice));
                        }
                        statusText.setText(result.toString());
                        stopMirrorButton.setEnabled(mirrorActive);
                        stopDesktopButton.setEnabled(desktopActive);
                    }
                });
            }
        });
    }

    private boolean isComputerChannelActive(int port) {
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress("127.0.0.1", port), 600);
            return true;
        } catch (Exception ignored) {
            return false;
        }
    }

    private boolean areShareNotificationsEnabled() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (!manager.areNotificationsEnabled()) {
            return false;
        }
        NotificationChannel channel = manager.getNotificationChannel(ShareNotifications.CHANNEL_ID);
        return channel == null || channel.getImportance() != NotificationManager.IMPORTANCE_NONE;
    }

    private void requestStop(String mode, int port) {
        Intent intent = new Intent(this, StopReceiver.class)
                .setAction("dev.androidscreenshare.companion.STOP")
                .putExtra("mode", mode)
                .putExtra("port", port);
        sendBroadcast(intent);
        statusText.postDelayed(new Runnable() {
            @Override
            public void run() {
                refreshStatus();
            }
        }, 1500);
    }
}
