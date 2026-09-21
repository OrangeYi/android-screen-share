package dev.androidscreenshare.companion;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

public final class StopReceiver extends BroadcastReceiver {
    private static final String TAG = "AndroidScreenShare";

    @Override
    public void onReceive(final Context context, Intent intent) {
        final String mode = intent.getStringExtra("mode");
        final boolean mirror = "mirror".equals(mode);
        final int defaultPort = mirror
                ? MirrorShareService.DEFAULT_PORT
                : DesktopShareService.DEFAULT_PORT;
        final int port = intent.getIntExtra("port", defaultPort);
        final Class<?> serviceClass = mirror
                ? MirrorShareService.class
                : DesktopShareService.class;
        final PendingResult result = goAsync();

        new Thread(new Runnable() {
            @Override
            public void run() {
                boolean confirmed = false;
                Exception lastError = null;

                for (int attempt = 0; attempt < 3 && !confirmed; attempt++) {
                    try (Socket socket = new Socket()) {
                        socket.connect(new InetSocketAddress("127.0.0.1", port), 2000);
                        socket.setSoTimeout(3000);
                        OutputStream output = socket.getOutputStream();
                        output.write("STOP\n".getBytes(StandardCharsets.US_ASCII));
                        output.flush();

                        BufferedReader reader = new BufferedReader(new InputStreamReader(
                                socket.getInputStream(), StandardCharsets.US_ASCII));
                        confirmed = "OK".equals(reader.readLine());
                    } catch (Exception error) {
                        lastError = error;
                        try {
                            Thread.sleep(350);
                        } catch (InterruptedException ignored) {
                            Thread.currentThread().interrupt();
                            break;
                        }
                    }
                }

                if (confirmed) {
                    Log.i(TAG, "Computer confirmed stop request for " + mode);
                    context.stopService(new Intent(context, serviceClass));
                } else {
                    Log.e(TAG, "Computer did not confirm stop request for " + mode, lastError);
                }
                result.finish();
            }
        }, "screen-share-stop").start();
    }
}
