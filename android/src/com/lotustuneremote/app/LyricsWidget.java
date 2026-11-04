/**
 * Segundo widget de pantalla de inicio: la LETRA de la cancion que suena.
 *
 * No tiene estado propio de reproduccion: titulo, artista, caratula, play,
 * aleatorio y "me gusta" los lee de PlayerWidget (los dos widgets son el
 * mismo reproductor visto de otra forma), y las acciones vuelven por el
 * mismo buzon que sondea el C++. Aqui solo vive el par de lineas que el
 * QML calcula con el tiempo real de la pista.
 *
 * Acciones: las mismas que el widget de reproduccion (TOGGLE, NEXT, PREV,
 * SHUFFLE, REPEAT, FAV).
 */
package com.lotustuneremote.app;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.view.View;
import android.widget.RemoteViews;

public class LyricsWidget extends AppWidgetProvider
{
    // Linea que se canta ahora y la siguiente (atenuada). El QML las empuja
    // solo cuando cambia el indice, no en cada frame.
    public static volatile String sLine = "";
    public static volatile String sNext = "";

    private static Context sCtx = null;

    /** La app llama esto al arrancar (QNativeInterface::QAndroidApplication). */
    public static void attach(Context c)
    {
        if (c != null)
            sCtx = c.getApplicationContext();
    }

    /** Par de lineas nuevo desde la app. */
    public static void update(String line, String next)
    {
        sLine = line == null ? "" : line;
        sNext = next == null ? "" : next;
        render(sCtx);
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
        // Mismo camino que el otro widget: deja la accion en el buzon y
        // repinta los dos.
        PlayerWidget.dispatch(sCtx, intent.getAction());
        super.onReceive(context, intent);
    }

    static void render(Context context)
    {
        if (context == null)
            return;
        AppWidgetManager m = AppWidgetManager.getInstance(context);
        int[] ids = m.getAppWidgetIds(
                new ComponentName(context, LyricsWidget.class));
        if (ids == null || ids.length == 0)
            return;
        for (int id : ids) {
            RemoteViews v = new RemoteViews(context.getPackageName(),
                                            R.layout.widget_lyrics);
            Bitmap art = AudioService.artBitmap();
            if (art != null) {
                v.setImageViewBitmap(R.id.l_art, art);
                v.setViewVisibility(R.id.l_art, View.VISIBLE);
            } else {
                v.setViewVisibility(R.id.l_art, View.GONE);
            }
            v.setTextViewText(R.id.l_title,
                    PlayerWidget.sTitle.isEmpty()
                            ? "Lotus Tune" : PlayerWidget.sTitle);
            v.setTextViewText(R.id.l_artist, PlayerWidget.sArtist);

            String line = sLine == null ? "" : sLine.trim();
            String next = sNext == null ? "" : sNext.trim();
            if (line.isEmpty())
                line = PlayerWidget.sTitle.isEmpty()
                        ? "Sin letra" : "Sin letra para esta cancion";
            if (next.isEmpty())
                next = " ";
            v.setTextViewText(R.id.l_line, line);
            v.setTextViewText(R.id.l_next, next);

            // Barra fina de progreso, como en el widget de reproduccion.
            final long dur = Math.max(1L, PlayerWidget.sDurMs);
            int prog = (int) Math.min(1000L,
                    Math.max(0L, PlayerWidget.sPosMs * 1000L / dur));
            v.setProgressBar(R.id.l_progress, 1000, prog, false);

            v.setImageViewResource(R.id.l_play,
                    PlayerWidget.sPlaying
                            ? R.drawable.ic_w_pause : R.drawable.ic_w_play);
            v.setImageViewResource(R.id.l_fav,
                    PlayerWidget.sFav
                            ? R.drawable.ic_w_heart
                            : R.drawable.ic_w_heart_outline);
            v.setImageViewResource(R.id.l_repeat,
                    PlayerWidget.sRepeat == 2
                            ? R.drawable.ic_w_repeat_one
                            : R.drawable.ic_w_repeat);
            v.setInt(R.id.l_repeat, "setColorFilter",
                    PlayerWidget.sRepeat == 0 ? 0xFF8A8A93 : 0xFFE0525F);
            v.setInt(R.id.l_shuffle, "setColorFilter",
                    PlayerWidget.sShuffle ? 0xFFE0525F : 0xFF8A8A93);
            v.setInt(R.id.l_fav, "setColorFilter",
                    PlayerWidget.sFav ? 0xFFE0525F : 0xFFFFFFFF);
            v.setInt(R.id.l_play, "setColorFilter", 0xFFFFFFFF);
            v.setInt(R.id.l_prev, "setColorFilter", 0xFFFFFFFF);
            v.setInt(R.id.l_next_btn, "setColorFilter", 0xFFFFFFFF);

            v.setOnClickPendingIntent(R.id.l_play,
                    PlayerWidget.intentFor(context,
                            PlayerWidget.ACTION_TOGGLE, 1));
            v.setOnClickPendingIntent(R.id.l_next_btn,
                    PlayerWidget.intentFor(context,
                            PlayerWidget.ACTION_NEXT, 2));
            v.setOnClickPendingIntent(R.id.l_prev,
                    PlayerWidget.intentFor(context,
                            PlayerWidget.ACTION_PREV, 3));
            v.setOnClickPendingIntent(R.id.l_shuffle,
                    PlayerWidget.intentFor(context,
                            PlayerWidget.ACTION_SHUFFLE, 4));
            v.setOnClickPendingIntent(R.id.l_repeat,
                    PlayerWidget.intentFor(context,
                            PlayerWidget.ACTION_REPEAT, 5));
            v.setOnClickPendingIntent(R.id.l_fav,
                    PlayerWidget.intentFor(context,
                            PlayerWidget.ACTION_FAV, 6));
            // Tocar la cabecera abre la app (como el widget de musica de
            // cualquier reproductor).
            v.setOnClickPendingIntent(R.id.l_head,
                    openApp(context));
            m.updateAppWidget(id, v);
        }
    }

    private static PendingIntent openApp(Context c)
    {
        Intent i = c.getPackageManager()
                .getLaunchIntentForPackage(c.getPackageName());
        if (i == null)
            return null;
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        return PendingIntent.getActivity(c, 0, i,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }
}
