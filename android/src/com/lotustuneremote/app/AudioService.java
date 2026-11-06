/**
 * Servicio en primer plano para que la musica siga sonando con la app en
 * segundo plano o la pantalla apagada (Android 8+ mata o suspende el
 * proceso si no hay un foreground service del tipo mediaPlayback).
 *
 * La notificacion reutiliza las mismas acciones que el widget
 * (PlayerWidget.ACTION_*), asi que ambas vias de control comparten el
 * buzon que sondea el C++. Ademas publica un MediaSession con la caratula
 * y los datos de la pista: es lo que hace que el sistema (pantalla de
 * bloqueo, ajustes rapidos, relojes, coche) muestre los controles buenos y
 * no una notificacion de texto.
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

    // Apagado con retardo: al acabar una pista el reproductor pasa un
    // instante por "stopped" y si se paraba el servicio en ese hueco el
    // proceso se quedaba sin primer plano (MIUI lo congela) y la pista
    // siguiente no llegaba a sonar. Se deja un margen y se cancela si
    // vuelve a arrancar.
    // Foco de audio: sin el, MIUI (AudioHardening) silencia la musica en
    // segundo plano ("background playback would be muted") y el
    // reproductor se queda parado a los pocos cientos de milisegundos de
    // empezar cada pista. Pidiendolo, la app es la duena del audio.
    private static AudioManager sAudio = null;
    private static AudioFocusRequest sFocusReq = null;
    private static AudioManager.OnAudioFocusChangeListener sFocusListener = null;
    private static boolean sPausedByLoss = false;

    private static Handler sStopHandler = null;
    private static Runnable sStopRunnable = null;
    private static final long STOP_DELAY_MS = 15000L;

    // Estado compartido con PlayerWidget (mismo proceso).
    private static Context sApp = null;
    private static MediaSession sSession = null;
    private static Bitmap sArt = null;
    private static String sArtLoaded = "\u0000";   // URL de la que salio sArt
    private static boolean sArtBusy = false;

    /** Arranca (o actualiza) el servicio. Lo llama la app al empezar a sonar. */
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
     * Para el servicio cuando la reproduccion termina, pero con margen:
     * entre el fin de una pista y el arranque de la siguiente el estado
     * pasa por "stopped" y apagarlo ahi dejaba el proceso sin primer
     * plano justo cuando mas falta hace.
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
        // El C++ llama desde el hilo de Qt, que NO tiene Looper: crear ahi
        // el MediaSession (lo hace internamente un Handler) lanzaba
        // NullPointerException y el aviso se quedaba sin repintar. Todo lo
        // que toca notificacion/sesion pasa al hilo principal.
        if (Looper.myLooper() == Looper.getMainLooper()) {
            doRefresh(app);
            return;
        }
        new Handler(Looper.getMainLooper()).post(new Runnable() {
            @Override public void run() { doRefresh(app); }
        });
    }

    /**
     * Solo la posicion de la sesion (cada segundo): la tarjeta de medios del
     * sistema extrapola entre refrescos, asi que con esto la barra no se
     * queda atras al cambiar de pista ni se adelanta al volver de segundo
     * plano. No repinta el aviso.
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
        // El widget se refresca aqui: sin esto se queda con el RemoteViews
        // de la ultima vez (o con el que monto el lanzador al añadirlo) y
        // los botones nuevos no llegan nunca.
        PlayerWidget.attach(sApp);
        PlayerWidget.render(sApp);
        try {
            NotificationManager nm = sApp.getSystemService(NotificationManager.class);
            if (nm != null)
                nm.notify(NOTIF_ID, build(sApp));
        } catch (Throwable t) {
            // Sin canal (o sin permiso) el servicio sigue: solo no se ve.
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
        // El sistema pregunta por aqui (cascos, reloj, coche): se traduce a
        // las mismas acciones del widget y el C++ las ejecuta.
        s.setCallback(new MediaSession.Callback() {
            @Override public void onPlay() { push("PLAY"); }
            @Override public void onPause() { push("PAUSE"); }
            @Override public void onSkipToNext() { push("NEXT"); }
            @Override public void onSkipToPrevious() { push("PREV"); }
            // Botones extra de las tarjetas de medios del sistema (MIUI,
            // Samsung, coche...): llegan como acciones personalizadas.
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

    /** Pide el foco de audio (una vez; repetirlo es inofensivo). */
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
                        // Llamada, aviso, video corto: pausar y reanudar
                        // cuando nos devuelvan el foco, PERO solo si de
                        // verdad estaba sonando. Si el usuario lo habia
                        // pausado a mano, al volver del video se queda en
                        // pausa (antes se reanudaba solo).
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
                // Acciones propias: la tarjeta de medios del sistema las
                // pinta como botones (aleatorio y me gusta) en las ROM que
                // las soportan; en las que no, se ignoran sin romper nada.
                .addCustomAction(new PlaybackState.CustomAction.Builder(
                        "SHUFFLE", "Aleatorio", R.drawable.ic_w_shuffle).build())
                .addCustomAction(new PlaybackState.CustomAction.Builder(
                        "FAV", "Me gusta", R.drawable.ic_w_heart_outline).build());
        // Sin posicion/duracion a proposito: asi el sistema no pinta una
        // barra de progreso que no se puede arrastrar.
        // Con velocidad 1 y una posicion valida el sistema extrapola solo:
        // la barra del aviso avanza sin que la app tenga que refrescar
        // cada segundo.
        ps.setState(PlayerWidget.sPlaying ? PlaybackState.STATE_PLAYING
                                          : PlaybackState.STATE_PAUSED,
                    PlayerWidget.sPosMs, PlayerWidget.sPlaying ? 1f : 0f);
        s.setPlaybackState(ps.build());
    }

    // ---- caratula -----------------------------------------------------

    /** Descarga la caratula (URL de i.ytimg) en segundo plano y repinta. */
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

    /** Caratula ya descargada (null si no hay): la usa el widget. */
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
            sWake.acquire(6 * 60 * 60 * 1000L);   // tope de 6 h por si acaso
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
