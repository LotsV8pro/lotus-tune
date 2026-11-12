/**
 * Segundo widget de pantalla de inicio: la LETRA de la cancion que suena.
 *
 * No tiene estado propio de reproduccion: titulo, artista, caratula, play,
 * aleatorio y "me gusta" los lee de PlayerWidget (los dos widgets son el
 * mismo reproductor visto de otra forma), y las acciones vuelven por el
 * mismo buzon que sondea el C++.
 *
 * La letra sale del MISMO sitio que en la app: los ficheros que el motor
 * publica en files/ (lyrics.json con las lineas y el ajuste, y
 * lyrics-runtime.json con la posicion y su marca de tiempo). Asi el widget
 * no depende de que el QML este vivo empujandole el par de lineas, y el
 * reloj, el offset, los "♪" del instrumental y el "Cargando letra…" son los
 * mismos que se ven dentro de la app. El trio que empuja el QML se queda
 * como respaldo (letra solo de texto de versiones antiguas, o mientras el
 * motor aun no ha escrito nada).
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

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;

public class LyricsWidget extends AppWidgetProvider
{
    // Fallback trio: the QML pushes it when the index changes.
    public static volatile String sPrev = "";
    public static volatile String sLine = "";
    public static volatile String sNext = "";

    // Last line painted. The animation only starts when it CHANGES; the
    // refreshes of the bar (every second) do not animate.
    private static String sShownLine = null;
    private static String sShownPrev = "";
    private static String sShownNext = "";

    private static Context sCtx = null;

    // ---- state published by the engine (the same as in the app) ----------

    /** Copia cacheada de files/lyrics.json (se reparsea si cambia). */
    private static final class Published
    {
        long mtime = -1;
        long length = -1;
        String trackKey = "";
        String status = "";
        String plain = "";
        double offset = 0;
        double[] t = new double[0];
        String[] text = new String[0];
    }

    /** Copia cacheada de files/lyrics-runtime.json. */
    private static final class Runtime
    {
        long mtime = -1;
        long length = -1;
        String trackKey = "";
        double pos = 0;
        double offset = 0;
        double ts = 0;
        boolean playing = false;
    }

    private static Published sPublished = null;
    private static Runtime sRuntime = null;

    /** La app llama esto al arrancar (QNativeInterface::QAndroidApplication). */
    public static void attach(Context c)
    {
        if (c != null)
            sCtx = c.getApplicationContext();
    }

    /** Trio de lineas nuevo desde la app (respaldo). */
    public static void update(String prev, String line, String next)
    {
        sPrev = prev == null ? "" : prev;
        sLine = line == null ? "" : line;
        sNext = next == null ? "" : next;
        render(sCtx);
    }

    /**
     * Latido del servicio (1 Hz, solo mientras suena): busca la linea con el
     * reloj publicado y repinta SOLO si ha cambiado. Sirve para que el
     * widget siga la cancion aunque el QML no este empujando nada.
     */
    static void tick(Context c)
    {
        if (c == null)
            return;
        sCtx = c.getApplicationContext();
        String[] trio = publishedTrio(sCtx);
        if (trio == null)
            return;                       // no hay estado: manda el QML
        String prev = trio[0] == null ? "" : trio[0].trim();
        String line = trio[1] == null ? "" : trio[1].trim();
        String next = trio[2] == null ? "" : trio[2].trim();
        if (line.isEmpty())
            line = PlayerWidget.sTitle.isEmpty()
                    ? "Sin letra" : "Sin letra para esta cancion";
        if (sShownLine != null && sShownLine.equals(line)
                && sShownPrev.equals(prev) && sShownNext.equals(next))
            return;                       // misma linea: nada que animar
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
        // Same path as the other widget: it leaves the action in the mailbox and
        // repaints both.
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

        // The published state first (the same one the app paints); when there is
        // nothing of the current track, the trio the QML pushes.
        String prev;
        String line;
        String next;
        String[] published = publishedTrio(context);
        if (published != null) {
            prev = published[0];
            line = published[1];
            next = published[2];
        } else {
            prev = sPrev == null ? "" : sPrev;
            line = sLine == null ? "" : sLine;
            next = sNext == null ? "" : sNext;
        }
        prev = prev.trim();
        line = line.trim();
        next = next.trim();
        if (line.isEmpty())
            line = PlayerWidget.sTitle.isEmpty()
                    ? "Sin letra" : "Sin letra para esta cancion";
        // It is decided once for all the widgets placed on the screen.
        final boolean lineChanged = sShownLine != null && !sShownLine.equals(line);
        sShownPrev = prev;
        sShownLine = line;
        sShownNext = next;

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

            // Two copies of the block, both filled (so the text is right whichever
            // is painted). On a line change it moves to the other copy with
            // showNext(), which always alternates: whether the host reuses the tree
            // (it is at 1) or reinflates it (it is at 0), the 0->1 or 1->0 jump
            // animates.
            fill(v, R.id.l_prev_line, R.id.l_line, R.id.l_next,
                 prev, line, next);
            fill(v, R.id.l_prev_line2, R.id.l_line2, R.id.l_next2,
                 prev, line, next);
            if (lineChanged)
                v.showNext(R.id.l_flip);

            // Thin progress bar, as in the playback widget.
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
            // Touching the header opens the app (like the music widget of any
            // player).
            v.setOnClickPendingIntent(R.id.l_head,
                    openApp(context));
            m.updateAppWidget(id, v);
        }
    }

    // ---- lectura del estado publicado ---------------------------------

    /**
     * Anterior/actual/siguiente calculadas con el mismo reloj que la app.
     * Devuelve null si el estado publicado no es de la pista que suena
     * (entonces manda el trio del QML).
     */
    private static String[] publishedTrio(Context c)
    {
        Published p = loadPublished(c);
        if (p == null || p.trackKey.isEmpty())
            return null;
        final String key = PlayerWidget.sArtist.trim()
                + " - " + PlayerWidget.sTitle.trim();
        if (!key.equals(p.trackKey))
            return null;

        // "ok" = lyrics with timings; "none" = no lyrics or plain text only;
        // "loading" = the search is still going (or nothing has arrived yet).
        if ("loading".equals(p.status))
            return new String[] { "", "Cargando letra…", "" };

        if ("ok".equals(p.status) && p.t.length > 0) {
            final double pos = positionNow(c, p);
            int idx = lineIndexAt(p.t, pos);
            if (idx < 0) {
                // Before the first line (instrumental intro): a symbol and, as the
                // "next" one, the first thing that will be sung.
                return new String[] { "", "♪", p.text[0] };
            }
            String prev = idx > 0 ? p.text[idx - 1] : "";
            String line = p.text[idx];
            String next = idx + 1 < p.text.length ? p.text[idx + 1] : "";
            return new String[] { prev, line, next };
        }

        if (!p.plain.isEmpty()) {
            // Lyrics with no timings: the first two lines, as in the app.
            String[] rows = p.plain.split("\n");
            String line = "";
            String next = "";
            for (String row : rows) {
                String t = row.trim();
                if (t.isEmpty())
                    continue;
                if (line.isEmpty())
                    line = t;
                else {
                    next = t;
                    break;
                }
            }
            if (!line.isEmpty())
                return new String[] { "", line, next };
        }

        // The track has its lyrics resolved but there is nothing to show.
        return new String[] { "", "", "" };
    }

    /** Posicion de la pista ahora, extrapolando desde la marca publicada. */
    private static double positionNow(Context c, Published p)
    {
        Runtime rt = loadRuntime(c);
        if (rt != null && !rt.trackKey.isEmpty()
                && rt.trackKey.equals(p.trackKey)) {
            final double offset = Double.isNaN(rt.offset) ? p.offset : rt.offset;
            if (!rt.playing) {
                // While paused the position pushed by the player rules: the runtime may
                // be from the previous session (the app starts stopped and does not
                // rewrite it until something plays) and the widget showed a line from
                // minutes ago.
                return PlayerWidget.sPosMs / 1000.0 + offset;
            }
            double pos = rt.pos;
            if (rt.ts > 0) {
                double elapsed = (System.currentTimeMillis() - rt.ts) / 1000.0;
                if (elapsed > 0)
                    pos += Math.min(elapsed, 2.0);   // sin fe ciega al fichero
            }
            return pos + offset;
        }
        // With no published beat (app closed or paused): the position the player
        // pushes to the widget.
        return PlayerWidget.sPosMs / 1000.0 + p.offset;
    }

    /** Ultima linea cuyo tiempo es <= pos (busqueda binaria). */
    private static int lineIndexAt(double[] times, double pos)
    {
        int lo = 0;
        int hi = times.length - 1;
        int found = -1;
        while (lo <= hi) {
            int mid = (lo + hi) >>> 1;
            if (times[mid] <= pos) {
                found = mid;
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }
        return found;
    }

    private static Published loadPublished(Context c)
    {
        File f = new File(c.getFilesDir(), "lyrics.json");
        long mtime = f.lastModified();
        long length = f.length();
        Published p = sPublished;
        if (p != null && p.mtime == mtime && p.length == length)
            return p;
        if (!f.isFile())
            return null;
        try {
            JSONObject o = new JSONObject(readAll(f));
            Published n = new Published();
            n.trackKey = o.optString("trackKey", "");
            n.status = o.optString("status", "");
            n.plain = o.optString("plain", "");
            n.offset = o.optDouble("offset", 0);
            JSONArray arr = o.optJSONArray("lines");
            int count = arr == null ? 0 : arr.length();
            n.t = new double[count];
            n.text = new String[count];
            int kept = 0;
            for (int i = 0; i < count; ++i) {
                JSONObject lo = arr.optJSONObject(i);
                if (lo == null || !lo.has("t"))
                    continue;
                n.t[kept] = lo.optDouble("t", 0);
                n.text[kept] = lo.optString("text", "♪");
                kept++;
            }
            if (kept != count) {
                double[] t = new double[kept];
                String[] text = new String[kept];
                System.arraycopy(n.t, 0, t, 0, kept);
                System.arraycopy(n.text, 0, text, 0, kept);
                n.t = t;
                n.text = text;
            }
            n.mtime = mtime;
            n.length = length;
            sPublished = n;
            return n;
        } catch (Throwable ignore) {
            // JSON caught mid write (the engine writes with an atomic rename): the
            // last good one stays.
            return p;
        }
    }

    private static Runtime loadRuntime(Context c)
    {
        File f = new File(c.getFilesDir(), "lyrics-runtime.json");
        long mtime = f.lastModified();
        long length = f.length();
        Runtime r = sRuntime;
        if (r != null && r.mtime == mtime && r.length == length)
            return r;
        if (!f.isFile())
            return null;
        try {
            JSONObject o = new JSONObject(readAll(f));
            Runtime n = new Runtime();
            n.trackKey = o.optString("trackKey", "");
            n.pos = o.optDouble("pos", 0);
            n.offset = o.optDouble("offset", 0);
            n.ts = o.optDouble("ts", 0);
            n.playing = o.optBoolean("playing", false);
            if (Double.isNaN(n.pos))
                n.pos = 0;
            if (Double.isNaN(n.offset))
                n.offset = 0;
            n.mtime = mtime;
            n.length = length;
            sRuntime = n;
            return n;
        } catch (Throwable ignore) {
            return r;
        }
    }

    private static String readAll(File f) throws Exception
    {
        FileInputStream in = new FileInputStream(f);
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream(
                    (int) Math.max(64, f.length()));
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) > 0)
                out.write(buf, 0, n);
            return out.toString("UTF-8");
        } finally {
            in.close();
        }
    }

    /** Pinta el trio de lineas en una de las dos copias del bloque. */
    private static void fill(RemoteViews v, int prevId, int lineId, int nextId,
                             String prev, String line, String next)
    {
        v.setTextViewText(lineId, line);
        v.setTextViewText(nextId, next);
        // The previous one always keeps its slot (INVISIBLE, not GONE): if it
        // disappeared, the whole block would shift on a line change and the
        // widget would jump.
        if (prev.isEmpty()) {
            v.setTextViewText(prevId, "");
            v.setViewVisibility(prevId, View.INVISIBLE);
        } else {
            v.setViewVisibility(prevId, View.VISIBLE);
            v.setTextViewText(prevId, prev);
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
