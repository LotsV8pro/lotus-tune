/**
 * Widget de pantalla de inicio: caratula? no (RemoteViews puro: titulo,
 * artista y controles). Se actualiza desde la app y devuelve las acciones
 * por un buzon volatil que el C++ sondea (nunca bloquea ni trae la app al
 * frente).
 *
 * Acciones: TOGGLE (play/pausa), NEXT, PREV, SHUFFLE, REPEAT, FAV.
 */
package com.lotustuneremote.app;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.widget.RemoteViews;

public class PlayerWidget extends AppWidgetProvider
{
    public static final String ACTION_TOGGLE =
        "com.lotustuneremote.app.WIDGET_TOGGLE";
    public static final String ACTION_NEXT =
        "com.lotustuneremote.app.WIDGET_NEXT";
    public static final String ACTION_PREV =
        "com.lotustuneremote.app.WIDGET_PREV";
    public static final String ACTION_SHUFFLE =
        "com.lotustuneremote.app.WIDGET_SHUFFLE";
    public static final String ACTION_REPEAT =
        "com.lotustuneremote.app.WIDGET_REPEAT";
    public static final String ACTION_FAV =
        "com.lotustuneremote.app.WIDGET_FAV";

    // Buzon para el C++: la ultima accion pedida y su numero de secuencia.
    public static volatile String sAction = "";
    public static volatile int sSeq = 0;

    // Estado que pinta la app.
    public static volatile String sTitle = "Lotus Tune";
    public static volatile String sArtist = "";
    // URL de la caratula: la descarga AudioService (misma clase, mismo
    // proceso) y el widget la recibe ya como bitmap al repintarse.
    public static volatile String sArt = "";
    public static volatile boolean sPlaying = false;
    public static volatile boolean sShuffle = false;
    public static volatile int sRepeat = 0;      // 0 off, 1 todo, 2 una
    public static volatile boolean sFav = false;
    public static volatile long sPosMs = 0;
    public static volatile long sDurMs = 0;

    private static Context sCtx = null;

    /** La app llama esto al arrancar (QNativeInterface::QAndroidApplication). */
    public static void attach(Context c)
    {
        if (c != null)
            sCtx = c.getApplicationContext();
    }

    /** Estado nuevo desde la app. */
    public static void update(String title, String artist, boolean playing,
                              boolean shuffle, int repeat, boolean fav,
                              String art, long posMs, long durMs)
    {
        sTitle = title == null ? "" : title;
        sArtist = artist == null ? "" : artist;
        sArt = art == null ? "" : art;
        sPosMs = Math.max(0, posMs);
        sDurMs = Math.max(0, durMs);
        sPlaying = playing;
        sShuffle = shuffle;
        sRepeat = repeat;
        sFav = fav;
        render(sCtx);
    }

    public static String pendingAction()
    {
        return sAction;
    }

    public static int pendingSeq()
    {
        return sSeq;
    }

    public static void clearAction()
    {
        sAction = "";
    }

    @Override
    public void onUpdate(Context context, AppWidgetManager manager, int[] ids)
    {
        sCtx = context.getApplicationContext();
        render(sCtx);
    }

    @Override
    public void onReceive(Context context, Intent intent)
    {
        sCtx = context.getApplicationContext();
        final String a = intent.getAction();
        if (a != null) {
            if (a.equals(ACTION_TOGGLE)) {
                sPlaying = !sPlaying;      // respuesta inmediata en el widget
                sAction = "TOGGLE";
                sSeq++;
                render(sCtx);
            } else if (a.equals(ACTION_NEXT)) {
                sAction = "NEXT";
                sSeq++;
            } else if (a.equals(ACTION_PREV)) {
                sAction = "PREV";
                sSeq++;
            } else if (a.equals(ACTION_SHUFFLE)) {
                sAction = "SHUFFLE";
                sSeq++;
            } else if (a.equals(ACTION_REPEAT)) {
                sAction = "REPEAT";
                sSeq++;
            } else if (a.equals(ACTION_FAV)) {
                sAction = "FAV";
                sSeq++;
            }
        }
        super.onReceive(context, intent);
    }

    private static PendingIntent pending(Context c, String action, int code)
    {
        Intent i = new Intent(c, PlayerWidget.class);
        i.setAction(action);
        return PendingIntent.getBroadcast(c, code, i,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    static void render(Context context)
    {
        if (context == null)
            return;
        AppWidgetManager m = AppWidgetManager.getInstance(context);
        int[] ids = m.getAppWidgetIds(
                new ComponentName(context, PlayerWidget.class));
        if (ids == null || ids.length == 0)
            return;
        for (int id : ids) {
            RemoteViews v = new RemoteViews(context.getPackageName(),
                                            R.layout.widget_player);
            Bitmap art = AudioService.artBitmap();
            if (art != null) {
                v.setImageViewBitmap(R.id.w_art, art);
                v.setViewVisibility(R.id.w_art, android.view.View.VISIBLE);
            } else {
                v.setViewVisibility(R.id.w_art, android.view.View.GONE);
            }
            v.setTextViewText(R.id.w_title,
                              sTitle.isEmpty() ? "Lotus Tune" : sTitle);
            v.setTextViewText(R.id.w_artist, sArtist);
            // Iconos vectoriales: los glifos de texto (corazon, flechas
            // del aleatorio) no existen en todas las fuentes y el widget
            // salia sin like ni aleatorio.
            v.setImageViewResource(R.id.w_play,
                    sPlaying ? R.drawable.ic_w_pause : R.drawable.ic_w_play);
            v.setImageViewResource(R.id.w_fav,
                    sFav ? R.drawable.ic_w_heart : R.drawable.ic_w_heart_outline);
            v.setImageViewResource(R.id.w_shuffle, R.drawable.ic_w_shuffle);
            v.setImageViewResource(R.id.w_repeat,
                    sRepeat == 2 ? R.drawable.ic_w_repeat_one : R.drawable.ic_w_repeat);
            v.setInt(R.id.w_repeat, "setColorFilter",
                     sRepeat == 0 ? 0xFF8A8A93 : 0xFFE0525F);
            v.setInt(R.id.w_shuffle, "setColorFilter",
                     sShuffle ? 0xFFE0525F : 0xFF8A8A93);
            v.setInt(R.id.w_fav, "setColorFilter",
                     sFav ? 0xFFE0525F : 0xFFFFFFFF);
            v.setInt(R.id.w_play, "setColorFilter", 0xFFFFFFFF);
            v.setInt(R.id.w_prev, "setColorFilter", 0xFFFFFFFF);
            v.setInt(R.id.w_next, "setColorFilter", 0xFFFFFFFF);
            v.setOnClickPendingIntent(R.id.w_play,
                    pending(context, ACTION_TOGGLE, 1));
            v.setOnClickPendingIntent(R.id.w_next, pending(context, ACTION_NEXT, 2));
            v.setOnClickPendingIntent(R.id.w_prev, pending(context, ACTION_PREV, 3));
            v.setOnClickPendingIntent(R.id.w_shuffle,
                    pending(context, ACTION_SHUFFLE, 4));
            v.setOnClickPendingIntent(R.id.w_repeat,
                    pending(context, ACTION_REPEAT, 5));
            v.setOnClickPendingIntent(R.id.w_fav, pending(context, ACTION_FAV, 6));
            m.updateAppWidget(id, v);
        }
    }
}
