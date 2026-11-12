/**
 * Foreground service so the music keeps playing with the app in the
 * background or the screen off (Android 8+ kills or suspends the process
 * when there is no foreground service of the mediaPlayback type).
 *
 * The notification reuses the same actions as the widget
 * (PlayerWidget.ACTION_*), so both control paths share the mailbox that
 * C++ polls. It also publishes a MediaSession with the artwork and the
 * track data: that is what makes the system (lock screen, quick settings,
 * watches, car) show the right controls instead of a text notification.
 */
package com.lotustuneremote.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.IBinder;
import android.os.PowerManager;

public class AudioService extends Service
{
    private static final String CHANNEL = "lotustune_playback";
    private static final int NOTIF_ID = 42;

    private PowerManager.WakeLock sWake = null;

    // Delayed stop: when a track ends the player goes through "stopped"
    // for an instant, and if the service was stopped in that gap the
    // process lost its foreground state (MIUI freezes it) and the next
    // track never started. A margin is left and the stop is cancelled when
    // playback starts again.
    // Audio focus: without it, MIUI (AudioHardening) mutes the music in
    // the background ("background playback would be muted") and the player
    // stops a few hundred milliseconds into every track. Asking for it
    // makes the app the owner of the audio.
    private static AudioManager sAudio = null;
    private static AudioFocusRequest sFocusReq = null;
    private static AudioManager.OnAudioFocusChangeListener sFocusListener = null;
    private static boolean sPausedByLoss = false;

    private static Handler sStopHandler = null;
    private static Runnable sStopRunnable = null;
    private static final long STOP_DELAY_MS = 15000L;

    // State shared with PlayerWidget (same process).
    private static Context sApp = null;
    private static MediaSession sSession = null;
    private static Bitmap sArt = null;
    private static String sArtLoaded = "\u0000";   // URL sArt came from
    private static boolean sArtBusy = false;

    /** Starts (or updates) the service. The app calls it when playback begins. */
    public static void start(Context c)
    {
        if (c == null)
            return;
        cancelStop();
        Intent i = new Intent(c, AudioService.class);
        if (Build.VERSION.SDK_INT >= 26)
            c.startForegroundService(i);
        else
            c.startService(i);
    }

    /**
     * Stops the service when playback ends, but with a margin: between the
     * end of one track and the start of the next the state goes through
     * "stopped", and stopping it there left the process without its
     * foreground state right when it is needed the most.
     */
    public static void stop(Context c)
    {
        if (c == null)
            return;
        final Context app = c.getApplicationContext();
        if (sStopHandler == null)
            sStopHandler = new Handler(Looper.getMainLooper());
        cancelStop();
        sStopRunnable = new Runnable() {
            @Override public void run() {
                sStopRunnable = null;
                app.stopService(new Intent(app, AudioService.class));
            }
        };
        sStopHandler.postDelayed(sStopRunnable, STOP_DELAY_MS);
    }

    private static void cancelStop()
    {
        if (sStopHandler != null && sStopRunnable != null) {
            sStopHandler.removeCallbacks(sStopRunnable);
            sStopRunnable = null;
        }
    }

    static void refresh(Context c)
    {
        if (c == null)
            return;
        final Context app = c.getApplicationContext();
        // C++ calls from the Qt thread, which has NO Looper: creating the
        // MediaSession there (it builds a Handler internally) threw
        // NullPointerException and the notification was never repainted.
        // Everything that touches the notification/session moves to the main
        // thread.
        if (Looper.myLooper() == Looper.getMainLooper()) {
            doRefresh(app);
            return;
        }
        new Handler(Looper.getMainLooper()).post(new Runnable() {
            @Override public void run() { doRefresh(app); }
        });
    }

    /**
     * Only the position of the session (every second): the system media
     * card extrapolates between refreshes, so with this the bar does not
     * fall behind when the track changes and does not run ahead when the
     * app comes back from the background. It does not repaint the
     * notification.
     */
    static void syncPosition(Context c)
    {
        if (c == null)
            return;
        if (Looper.myLooper() == Looper.getMainLooper()) {
            updateSession();
            return;
        }
        new Handler(Looper.getMainLooper()).post(new Runnable() {
            @Override public void run() { updateSession(); }
        });
    }

    private static void doRefresh(Context c)
    {
        sApp = c;
        ensureChannel(sApp);
        ensureSession(sApp);
        loadArt(sApp);
        updateSession();
        // The widget is refreshed here: without this it keeps the RemoteViews
        // of the last time (or the one the launcher mounted when it was added)
        // and the new buttons never arrive.
        PlayerWidget.attach(sApp);
        PlayerWidget.render(sApp);
        beat(sApp);
        try {
            NotificationManager nm = sApp.getSystemService(NotificationManager.class);
            if (nm != null)
                nm.notify(NOTIF_ID, build(sApp));
        } catch (Throwable t) {
            // With no channel (or no permission) the service goes on, it is just
            // not seen.
        }
    }

    // ---- canal y MediaSession ----------------------------------------

    private static void ensureChannel(Context c)
    {
        if (c == null || Build.VERSION.SDK_INT < 26)
            return;
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        if (nm == null || nm.getNotificationChannel(CHANNEL) != null)
            return;
        NotificationChannel ch = new NotificationChannel(CHANNEL, "Reproduccion",
                NotificationManager.IMPORTANCE_LOW);
        ch.setShowBadge(false);
        ch.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
        nm.createNotificationChannel(ch);
    }

    private static synchronized void ensureSession(Context c)
    {
        if (sSession != null || c == null)
            return;
        MediaSession s = new MediaSession(c, "LotusTune");
        // The system asks through here (headphones, watch, car): it is turned
        // into the same actions as the widget and C++ runs them.
        s.setCallback(new MediaSession.Callback() {
            @Override public void onPlay() { push("PLAY"); }
            @Override public void onPause() { push("PAUSE"); }
            @Override public void onSkipToNext() { push("NEXT"); }
            @Override public void onSkipToPrevious() { push("PREV"); }
            // Extra buttons of the system media cards (MIUI, Samsung, car...):
            // they arrive as custom actions.
            @Override public void onCustomAction(String action, android.os.Bundle args)
            {
                android.util.Log.i("LotusTune", "[media] accion propia: " + action);
                if (action != null)
                    push(action);
            }
        });
        s.setActive(true);
        sSession = s;
    }

    /** Asks for the audio focus (once; asking again does no harm). */
    private static void ensureFocus(Context c)
    {
        AudioManager am = (AudioManager) c.getSystemService(Context.AUDIO_SERVICE);
        if (am == null)
            return;
        sAudio = am;
        if (sFocusListener == null) {
            sFocusListener = new AudioManager.OnAudioFocusChangeListener() {
                @Override public void onAudioFocusChange(int change)
                {
                    if (change == AudioManager.AUDIOFOCUS_LOSS) {
                        // Perdida definitiva (otra app pone musica): pausar
                        // y no reanudar solos.
                        sPausedByLoss = false;
                        push("PAUSE");
                    } else if (change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                        // Call, notification, short video: pause and resume when the focus comes
                        // back, BUT only when it really was playing. If the user had paused it
                        // by hand, it stays paused after the video (it used to resume on its
                        // own).
                        sPausedByLoss = PlayerWidget.sPlaying;
                        push("PAUSE");
                    } else if (change == AudioManager.AUDIOFOCUS_GAIN
                               && sPausedByLoss) {
                        sPausedByLoss = false;
                        push("PLAY");
                    }
                }
            };
        }
        if (Build.VERSION.SDK_INT >= 26) {
            if (sFocusReq == null) {
                sFocusReq = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                        .setAudioAttributes(new AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                                .build())
                        .setOnAudioFocusChangeListener(
                                sFocusListener, new Handler(Looper.getMainLooper()))
                        .setWillPauseWhenDucked(true)
                        .build();
            }
            am.requestAudioFocus(sFocusReq);
        } else {
            am.requestAudioFocus(sFocusListener, AudioManager.STREAM_MUSIC,
                                 AudioManager.AUDIOFOCUS_GAIN);
        }
    }

    private static void abandonFocus()
    {
        if (sAudio == null)
            return;
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                if (sFocusReq != null)
                    sAudio.abandonAudioFocusRequest(sFocusReq);
            } else {
                sAudio.abandonAudioFocus(sFocusListener);
            }
        } catch (Throwable ignore) {
        }
        sAudio = null;
    }

    private static void push(String a)
    {
        PlayerWidget.sAction = a;
        PlayerWidget.sSeq++;
    }

    // ---- heartbeat of the lyrics widget --------------------------------
    // The lyrics of the widget are worked out from the files the engine
    // publishes (lyrics.json / lyrics-runtime.json). QML already pushes the
    // line every 250 ms, but when the activity died the widget froze.
    // This 1 Hz heartbeat, only while playing, reads the published clock
    // and repaints only when the line changes (not every second).
    private static Handler sBeatHandler = null;
    private static Runnable sBeatRunnable = null;

    private static void beat(Context c)
    {
        if (c == null)
            return;
        if (sBeatHandler == null)
            sBeatHandler = new Handler(Looper.getMainLooper());
        if (sBeatRunnable == null) {
            sBeatRunnable = new Runnable() {
                @Override public void run()
                {
                    if (!PlayerWidget.sPlaying)
                        return;
                    LyricsWidget.tick(sApp);
                    if (sBeatHandler != null)
                        sBeatHandler.postDelayed(this, 1000);
                }
            };
        }
        sBeatHandler.removeCallbacks(sBeatRunnable);
        if (PlayerWidget.sPlaying)
            sBeatHandler.postDelayed(sBeatRunnable, 1000);
    }

    private static void updateSession()
    {
        MediaSession s = sSession;
        if (s == null)
            return;
        MediaMetadata.Builder md = new MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE,
                           PlayerWidget.sTitle)
                .putString(MediaMetadata.METADATA_KEY_ARTIST,
                           PlayerWidget.sArtist)
                .putString(MediaMetadata.METADATA_KEY_ALBUM,
                           PlayerWidget.sArtist)
                .putLong(MediaMetadata.METADATA_KEY_DURATION,
                         PlayerWidget.sDurMs);
        if (sArt != null)
            md.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, sArt);
        s.setMetadata(md.build());
        PlaybackState.Builder ps = new PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY
                          | PlaybackState.ACTION_PAUSE
                          | PlaybackState.ACTION_PLAY_PAUSE
                          | PlaybackState.ACTION_SKIP_TO_NEXT
                          | PlaybackState.ACTION_SKIP_TO_PREVIOUS)
                // Actions of its own: the system media card paints them as buttons
                // (shuffle and like) on the ROMs that support them; on the others they
                // are ignored without breaking anything.
                .addCustomAction(new PlaybackState.CustomAction.Builder(
                        "SHUFFLE", "Aleatorio", R.drawable.ic_w_shuffle).build())
                .addCustomAction(new PlaybackState.CustomAction.Builder(
                        "FAV", "Me gusta", R.drawable.ic_w_heart_outline).build());
        // No position or duration on purpose: that way the system does not
        // paint a progress bar that cannot be dragged.
        // With speed 1 and a valid position the system extrapolates on its
        // own: the bar of the notification moves without the app refreshing it
        // every second.
        ps.setState(PlayerWidget.sPlaying ? PlaybackState.STATE_PLAYING
                                          : PlaybackState.STATE_PAUSED,
                    PlayerWidget.sPosMs, PlayerWidget.sPlaying ? 1f : 0f);
        s.setPlaybackState(ps.build());
    }

    // ---- caratula -----------------------------------------------------

    /** Downloads the artwork (i.ytimg URL) in the background and repaints. */
    private static void loadArt(Context c)
    {
        String url = PlayerWidget.sArt == null ? "" : PlayerWidget.sArt.trim();
        if (url.equals(sArtLoaded) || sArtBusy)
            return;
        sArtLoaded = url;
        if (url.isEmpty()) {
            sArt = null;
            return;
        }
        sArt = null;                     // no mezclar caratulas
        sArtBusy = true;
        new Thread(new Runnable() {
            @Override public void run()
            {
                Bitmap b = null;
                try {
                    java.net.HttpURLConnection cn =
                        (java.net.HttpURLConnection) new java.net.URL(url)
                            .openConnection();
                    cn.setConnectTimeout(8000);
                    cn.setReadTimeout(8000);
                    cn.setInstanceFollowRedirects(true);
                    cn.addRequestProperty("User-Agent", "Mozilla/5.0");
                    java.io.InputStream in = cn.getInputStream();
                    b = BitmapFactory.decodeStream(in);
                    in.close();
                    cn.disconnect();
                } catch (Throwable t) {
                    b = null;
                }
                sArt = b;
                sArtBusy = false;
                final Context app = sApp;
                if (app == null)
                    return;
                new Handler(Looper.getMainLooper()).post(new Runnable() {
                    @Override public void run()
                    {
                        updateSession();
                        PlayerWidget.render(app);
                        try {
                            NotificationManager nm =
                                app.getSystemService(NotificationManager.class);
                            if (nm != null)
                                nm.notify(NOTIF_ID, build(app));
                        } catch (Throwable ignore) {
                        }
                    }
                });
            }
        }).start();
    }

    /** Artwork already downloaded (null when there is none): the widget uses it. */
    static Bitmap artBitmap()
    {
        return sArt;
    }

    private static PendingIntent act(Context c, String action, int code)
    {
        Intent i = new Intent(c, PlayerWidget.class);
        i.setAction(action);
        return PendingIntent.getBroadcast(c, code, i,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static Notification build(Context c)
    {
        ensureChannel(c);
        ensureSession(c);
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= 26)
            b = new Notification.Builder(c, CHANNEL);
        else
            b = new Notification.Builder(c);
        Intent open = new Intent(c, MainActivity.class);
        open.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent openPi = PendingIntent.getActivity(c, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        b.setContentTitle(PlayerWidget.sTitle.isEmpty()
                ? "Lotus Tune" : PlayerWidget.sTitle)
         .setContentText(PlayerWidget.sArtist)
         .setSubText(PlayerWidget.sPlaying ? "Reproduciendo" : "En pausa")
         .setSmallIcon(R.drawable.ic_launcher)
         .setContentIntent(openPi)
         .setOnlyAlertOnce(true)
         .setOngoing(PlayerWidget.sPlaying)
         .setVisibility(Notification.VISIBILITY_PUBLIC);
        if (sArt != null)
            b.setLargeIcon(sArt);
        b.addAction(android.R.drawable.ic_media_previous, "Anterior",
                    act(c, PlayerWidget.ACTION_PREV, 3));
        b.addAction(PlayerWidget.sPlaying
                        ? android.R.drawable.ic_media_pause
                        : android.R.drawable.ic_media_play,
                    PlayerWidget.sPlaying ? "Pausar" : "Reproducir",
                    act(c, PlayerWidget.ACTION_TOGGLE, 1));
        b.addAction(android.R.drawable.ic_media_next, "Siguiente",
                    act(c, PlayerWidget.ACTION_NEXT, 2));
        b.addAction(android.R.drawable.btn_star, "Me gusta",
                    act(c, PlayerWidget.ACTION_FAV, 6));
        if (Build.VERSION.SDK_INT >= 21) {
            Notification.MediaStyle ms = new Notification.MediaStyle()
                    .setShowActionsInCompactView(0, 1, 2);
            if (sSession != null)
                ms.setMediaSession(sSession.getSessionToken());
            b.setStyle(ms);
        }
        return b.build();
    }

    // ---- ciclo de vida ------------------------------------------------

    @Override
    public void onCreate()
    {
        super.onCreate();
        sApp = getApplicationContext();
        ensureChannel(sApp);
        ensureSession(sApp);
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        if (pm != null) {
            sWake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,
                                   "lotustune:playback");
            sWake.setReferenceCounted(false);
            sWake.acquire(6 * 60 * 60 * 1000L);   // 6 h cap, just in case
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId)
    {
        ensureFocus(this);
        updateSession();
        startForeground(NOTIF_ID, build(this));
        return START_STICKY;
    }

    @Override
    public void onDestroy()
    {
        abandonFocus();
        if (sBeatHandler != null && sBeatRunnable != null)
            sBeatHandler.removeCallbacks(sBeatRunnable);
        sBeatRunnable = null;
        if (sWake != null && sWake.isHeld())
            sWake.release();
        sWake = null;
        if (sSession != null) {
            sSession.setActive(false);
            sSession.release();
            sSession = null;
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent)
    {
        return null;
    }
}
