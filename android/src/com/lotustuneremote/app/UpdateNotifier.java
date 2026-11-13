package com.lotustuneremote.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

// The notice of a new version, in the phone's notification shade.
//
// Inside the app the new version is already told (the notice at the bottom
// and the line in Ajustes), but on a phone an update is only useful if it is
// seen while the app is closed: this posts a real notification. Tapping it
// opens the download of the .apk in the browser.
//
// One notification per version: the one that was already told is kept in the
// preferences, so it does not come back on every start.
public final class UpdateNotifier
{
    private static final String CHANNEL = "updates";
    private static final int NOTIF_ID = 4103;

    private UpdateNotifier() {}

    public static void notifyUpdate(Context c, final String version, final String url)
    {
        if (c == null || version == null || version.isEmpty())
            return;
        SharedPreferences p =
                c.getSharedPreferences("updates", Context.MODE_PRIVATE);
        if (version.equals(p.getString("notified", "")))
            return;

        // Android 13 asks for POST_NOTIFICATIONS when the app starts (the
        // playback service needs it too). While the answer is not there the
        // post is refused, so it is tried again in a while instead of losing
        // the notice for this launch.
        if (!canPost(c)) {
            final Context app = c.getApplicationContext();
            new Handler(Looper.getMainLooper()).postDelayed(new Runnable() {
                @Override public void run() { post(app, version, url); }
            }, 20000);
            return;
        }
        post(c, version, url);
    }

    private static boolean canPost(Context c)
    {
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        if (nm == null)
            return false;
        if (Build.VERSION.SDK_INT >= 24)
            return nm.areNotificationsEnabled();
        return true;
    }

    private static void post(Context c, String version, String url)
    {
        if (!canPost(c))
            return;
        ensureChannel(c);
        Intent open;
        if (url != null && !url.isEmpty())
            open = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
        else
            open = new Intent(c, MainActivity.class);
        open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        PendingIntent pi = PendingIntent.getActivity(c, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder b = (Build.VERSION.SDK_INT >= 26)
                ? new Notification.Builder(c, CHANNEL)
                : new Notification.Builder(c);
        b.setContentTitle(c.getString(R.string.app_label) + " " + version)
         .setContentText(c.getString(R.string.update_text))
         .setSmallIcon(R.drawable.ic_launcher)
         .setContentIntent(pi)
         .setAutoCancel(true)
         .setVisibility(Notification.VISIBILITY_PUBLIC);
        try {
            NotificationManager nm = c.getSystemService(NotificationManager.class);
            if (nm == null)
                return;
            nm.notify(NOTIF_ID, b.build());
            // Only remembered once it is really in the shade.
            c.getSharedPreferences("updates", Context.MODE_PRIVATE)
             .edit().putString("notified", version).apply();
        } catch (Throwable t) {
            // No permission, no channel, an OEM without this API: the app
            // goes on, the notice is just not seen.
        }
    }

    private static void ensureChannel(Context c)
    {
        if (Build.VERSION.SDK_INT < 26)
            return;
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        if (nm == null || nm.getNotificationChannel(CHANNEL) != null)
            return;
        NotificationChannel ch = new NotificationChannel(CHANNEL,
                c.getString(R.string.update_channel),
                NotificationManager.IMPORTANCE_DEFAULT);
        ch.setDescription(c.getString(R.string.update_channel_desc));
        ch.setShowBadge(true);
        nm.createNotificationChannel(ch);
    }
}
