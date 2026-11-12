/**
 * Segundo widget de pantalla de inicio: la LETRA de la cancion que suena.
 *
 * No tiene estado propio de reproduccion: si suena, el titulo y la posicion
 * los lee de PlayerWidget (los dos widgets son el mismo reproductor visto de
 * otra forma).
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
 * Cuando la letra trae los tiempos de cada palabra (lyrics.json con `w`), la
 * linea activa se pinta como en la app: lo ya cantado en blanco y lo que
 * falta apagado. La frontera avanza letra a letra y solo se repinta cuando
 * cae en otra letra, con la pantalla encendida y mientras suena.
 *
 * Es solo la letra: sin cabecera, sin barra y sin botones. Tocar el widget
 * abre la app, y los controles se quedan en el widget de reproduccion.
 */
package com.lotustuneremote.app;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.style.ForegroundColorSpan;
import android.view.View;
import android.widget.RemoteViews;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.util.Arrays;

public class LyricsWidget extends AppWidgetProvider
{
    // El karaoke de la app, con sus dos tintas: lo cantado se enciende y el
    // resto de la frase espera apagado. Un widget no puede mover una frontera,
    // asi que el color avanza letra a letra: cada repintado son dos textos
    // pequenos, no un bitmap.
    private static final int INK_SUNG = 0xFFFFFFFF;
    private static final int INK_DIM = 0x7AFFFFFF;

    // Repintador de la frontera del canto: duerme hasta que cambia la
    // siguiente letra y solo corre con la pantalla encendida.
    private static Handler sFrontHandler = null;
    private static Runnable sFrontRunnable = null;

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
        boolean karaoke = false;
        double[] t = new double[0];
        String[] text = new String[0];
        // Word timings of every line, already mapped to character ranges of
        // its own text. Empty arrays on lines without them.
        double[][] wT = new double[0][];
        double[][] wE = new double[0][];
        int[][] wA = new int[0][];
        int[][] wB = new int[0][];
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
        Shot s = shotAt(sCtx);
        if (s.p == null) {
            stopFront();
            return;                       // no hay estado: manda el QML
        }
        String prev = s.prev.trim();
        String line = s.line.trim();
        String next = s.next.trim();
        if (line.isEmpty())
            line = PlayerWidget.sTitle.isEmpty()
                    ? "Sin letra" : "Sin letra para esta cancion";
        if (sShownLine != null && sShownLine.equals(line)
                && sShownPrev.equals(prev) && sShownNext.equals(next)) {
            // Same line: the only thing that can move is the singing front.
            armFront(sCtx);
            return;
        }
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
        Shot s = shotAt(context);
        String prev;
        String line;
        String next;
        if (s.p != null) {
            prev = s.prev;
            line = s.line;
            next = s.next;
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
        // Se decide una vez para todos los widgets de la pantalla.
        final boolean lineChanged = sShownLine != null && !sShownLine.equals(line);
        sShownPrev = prev;
        sShownLine = line;
        sShownNext = next;
        final CharSequence lineSeq = (s.p != null && line.equals(s.line))
                ? lineText(s) : line;

        for (int id : ids) {
            RemoteViews v = new RemoteViews(context.getPackageName(),
                                            R.layout.widget_lyrics);
            // Las dos copias del bloque, rellenas (el texto tiene que estar
            // bien en la que se pinte). Al cambiar de linea se pasa a la otra
            // con showNext(), que siempre alterna: tanto si el host reusa el
            // arbol (esta en 1) como si lo reinfla (esta en 0), el salto 0->1
            // o 1->0 anima.
            fill(v, R.id.l_prev_line, R.id.l_line, R.id.l_next,
                 prev, lineSeq, next);
            fill(v, R.id.l_prev_line2, R.id.l_line2, R.id.l_next2,
                 prev, lineSeq, next);
            if (lineChanged)
                v.showNext(R.id.l_flip);
            // El widget es solo la letra: tocar cualquier parte abre la app.
            final PendingIntent open = openApp(context);
            if (open != null)
                v.setOnClickPendingIntent(R.id.l_root, open);
            m.updateAppWidget(id, v);
        }
        // Con la linea en pantalla, el karaoke toma el relevo hasta la siguiente.
        armFront(context);
    }

    // ---- lectura del estado publicado ---------------------------------

    /** Lo que se pinta ahora: tres lineas y de donde salen. */
    private static final class Shot
    {
        String prev = "";
        String line = "";
        String next = "";
        Published p = null;      // null: manda el trio que empuja el QML
        int idx = -1;            // linea activa dentro de Published
        double pos = 0;          // segundo que suena, con el offset ya sumado
    }

    /**
     * Anterior/actual/siguiente calculadas con el mismo reloj que la app.
     * Devuelve el estado publicado vacio si no es de la pista que suena
     * (entonces manda el trio del QML).
     */
    private static Shot shotAt(Context c)
    {
        Shot out = new Shot();
        Published p = loadPublished(c);
        if (p == null || p.trackKey.isEmpty())
            return out;
        final String key = PlayerWidget.sArtist.trim()
                + " - " + PlayerWidget.sTitle.trim();
        if (!key.equals(p.trackKey))
            return out;

        out.p = p;
        // "ok" = lyrics with timings; "none" = no lyrics or plain text only;
        // "loading" = the search is still going (or nothing has arrived yet).
        if ("loading".equals(p.status)) {
            out.line = "Cargando letra…";
            return out;
        }

        if ("ok".equals(p.status) && p.t.length > 0) {
            final double pos = positionNow(c, p);
            out.pos = pos;
            int idx = lineIndexAt(p.t, pos);
            if (idx < 0) {
                // Before the first line (instrumental intro): a symbol and, as the
                // "next" one, the first thing that will be sung.
                out.line = "♪";
                out.next = p.text[0];
                return out;
            }
            out.idx = idx;
            out.prev = idx > 0 ? p.text[idx - 1] : "";
            out.line = p.text[idx];
            out.next = idx + 1 < p.text.length ? p.text[idx + 1] : "";
            return out;
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
            out.line = line;
            out.next = next;
            return out;
        }

        // The track has its lyrics resolved but there is nothing to show.
        return out;
    }

    // ---- karaoke -------------------------------------------------------
    // La misma idea que en la app: las palabras de la linea llevan sus
    // tiempos y lo ya cantado se enciende mientras el resto espera apagado.
    // Aqui la frontera salta letra a letra (un widget no tiene fotogramas) y
    // solo se repinta cuando cae en otra letra, asi que cuesta un par de
    // textos pequenos por segundo y no un temporizador a 60 Hz.

    /**
     * Palabras de la linea como {t, e, primera letra, ultima letra}. Se busca
     * el texto de cada palabra dentro de la linea, como en el QML, porque las
     * palabras pueden venir con el espacio incluido.
     */
    private static double[][] wordSpans(String text, JSONArray words)
    {
        if (text == null || text.isEmpty() || words == null || words.length() == 0)
            return null;
        final String s = text;
        double[][] out = new double[words.length()][];
        int from = 0;
        int n = 0;
        for (int i = 0; i < words.length(); ++i) {
            JSONObject w = words.optJSONObject(i);
            if (w == null)
                continue;
            String core = w.optString("text", "").trim();
            if (core.isEmpty())
                continue;
            int at = s.indexOf(core, from);
            if (at < 0)
                at = s.indexOf(core);
            if (at < 0)
                at = Math.min(from, s.length());
            int len = Math.min(core.length(), s.length() - at);
            if (len <= 0)
                continue;
            double t = w.optDouble("t", 0);
            double e = w.optDouble("e", 0);
            if (!(e > t))
                e = t + 0.2;
            out[n++] = new double[] { t, e, at, at + len };
            from = at + Math.max(1, core.length());
        }
        if (n == 0)
            return null;
        return Arrays.copyOf(out, n);
    }

    /** Sangrado de `s.line`, con las palabras ya cantadas en blanco. */
    private static CharSequence lineText(Shot s)
    {
        if (s.p == null || s.idx < 0 || !s.p.karaoke
                || s.idx >= s.p.wT.length || s.p.wT[s.idx] == null
                || s.p.wT[s.idx].length == 0)
            return s.line;
        final String text = s.line;
        if (text.isEmpty())
            return text;
        int front = (int) Math.floor(frontFor(s.p, s.idx, s.pos));
        front = Math.max(0, Math.min(text.length(), front));
        // Antes de la primera palabra la frase entera espera apagada, como en
        // la app; la tinta clara solo cubre lo ya cantado.
        SpannableString span = new SpannableString(text);
        if (front > 0)
            span.setSpan(new ForegroundColorSpan(INK_SUNG), 0, front,
                         Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        if (front < text.length())
            span.setSpan(new ForegroundColorSpan(INK_DIM), front, text.length(),
                         Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        return span;
    }

    /** Frontera del canto (caracter fraccionario) de la linea `idx`. */
    private static double frontFor(Published p, int idx, double pos)
    {
        double[] ts = (idx >= 0 && idx < p.wT.length) ? p.wT[idx] : null;
        if (ts == null || ts.length == 0)
            return 0;
        double at = 0;
        for (int k = 0; k < ts.length; ++k) {
            if (pos < ts[k])
                break;
            final int a = p.wA[idx][k];
            final int b = p.wB[idx][k];
            final double e = p.wE[idx][k];
            if (!(e > ts[k]) || b <= a) {
                at = b;                   // palabra sin duracion o sin letras
                continue;
            }
            final double f = Math.min(1.0, (pos - ts[k]) / (e - ts[k]));
            at = a + (b - a) * f;
        }
        return at;
    }

    /**
     * Milisegundos hasta que la frontera caiga en otra letra. Devuelve -1
     * cuando la linea ya se ha cantado entera (la siguiente la trae el latido
     * de 1 Hz).
     */
    private static long nextFrontDelay(Published p, int idx, double pos)
    {
        double[] ts = (idx >= 0 && idx < p.wT.length) ? p.wT[idx] : null;
        if (ts == null || ts.length == 0)
            return -1;
        for (int k = 0; k < ts.length; ++k) {
            final double t0 = ts[k];
            final double t1 = p.wE[idx][k];
            final int a = p.wA[idx][k];
            final int b = p.wB[idx][k];
            if (pos < t0)
                return msUntil(t0 - pos);
            if (!(t1 > t0) || b <= a)
                continue;
            if (pos < t1) {
                final double at = a + (b - a) * (pos - t0) / (t1 - t0);
                final double next = Math.floor(at) + 1.0;
                if (next > b)
                    return msUntil(t1 - pos);
                return msUntil(t0 + (t1 - t0) * (next - a) / (b - a) - pos);
            }
        }
        return -1;
    }

    private static long msUntil(double secs)
    {
        long ms = (long) Math.ceil(secs * 1000.0);
        if (ms < 60L)
            ms = 60L;                     // nunca mas de ~16 repintados/s
        if (ms > 1000L)
            ms = 1000L;                   // el resto lo cubre el latido del servicio
        return ms;
    }

    /** Programa la siguiente letra cantada; sin karaoke, apaga el reloj. */
    static void armFront(final Context context)
    {
        if (context == null)
            return;
        final Context app = context.getApplicationContext();
        Shot s = shotAt(app);
        if (!PlayerWidget.sPlaying || s.p == null || s.idx < 0) {
            stopFront();
            return;
        }
        // Pantalla apagada: nadie mira el widget. El latido de 1 Hz vuelve a
        // armarlo en cuanto se enciende.
        PowerManager pm = (PowerManager)
                app.getSystemService(Context.POWER_SERVICE);
        if (pm != null && !pm.isInteractive()) {
            stopFront();
            return;
        }
        final long delay = nextFrontDelay(s.p, s.idx, s.pos);
        if (delay < 0) {
            stopFront();
            return;
        }
        if (sFrontHandler == null)
            sFrontHandler = new Handler(Looper.getMainLooper());
        if (sFrontRunnable == null) {
            sFrontRunnable = new Runnable() {
                @Override public void run()
                {
                    if (!PlayerWidget.sPlaying) {
                        stopFront();
                        return;
                    }
                    PowerManager pm = (PowerManager)
                            app.getSystemService(Context.POWER_SERVICE);
                    if (pm != null && !pm.isInteractive()) {
                        // Pantalla apagada: nadie mira el widget y despertar
                        // cada 200 ms es bateria pura. El latido de 1 Hz lo
                        // vuelve a armar al encenderse.
                        return;
                    }
                    renderFront(app);
                    armFront(app);
                }
            };
        }
        sFrontHandler.removeCallbacks(sFrontRunnable);
        sFrontHandler.postDelayed(sFrontRunnable, delay);
    }

    static void stopFront()
    {
        if (sFrontHandler != null && sFrontRunnable != null)
            sFrontHandler.removeCallbacks(sFrontRunnable);
    }

    /**
     * Repintado barato: solo las dos copias de la linea activa, con las
     * palabras ya cantadas encendidas. Sin caratula, sin barra, sin botones.
     */
    static void renderFront(Context context)
    {
        if (context == null)
            return;
        AppWidgetManager m = AppWidgetManager.getInstance(context);
        int[] ids = m.getAppWidgetIds(
                new ComponentName(context, LyricsWidget.class));
        if (ids == null || ids.length == 0)
            return;
        Shot s = shotAt(context);
        if (s.p == null || s.idx < 0)
            return;
        final CharSequence seq = lineText(s);
        for (int id : ids) {
            RemoteViews v = new RemoteViews(context.getPackageName(),
                                            R.layout.widget_lyrics);
            v.setTextViewText(R.id.l_line, seq);
            v.setTextViewText(R.id.l_line2, seq);
            m.updateAppWidget(id, v);
        }
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
            n.karaoke = o.optBoolean("karaoke", false);
            JSONArray arr = o.optJSONArray("lines");
            final int count = arr == null ? 0 : arr.length();
            double[] t = new double[count];
            String[] text = new String[count];
            double[][] wT = new double[count][];
            double[][] wE = new double[count][];
            int[][] wA = new int[count][];
            int[][] wB = new int[count][];
            int kept = 0;
            for (int i = 0; i < count; ++i) {
                JSONObject lo = arr.optJSONObject(i);
                if (lo == null || !lo.has("t"))
                    continue;
                t[kept] = lo.optDouble("t", 0);
                text[kept] = lo.optString("text", "♪").trim();
                double[][] spans = wordSpans(text[kept], lo.optJSONArray("w"));
                if (spans != null) {
                    wT[kept] = new double[spans.length];
                    wE[kept] = new double[spans.length];
                    wA[kept] = new int[spans.length];
                    wB[kept] = new int[spans.length];
                    for (int k = 0; k < spans.length; ++k) {
                        wT[kept][k] = spans[k][0];
                        wE[kept][k] = spans[k][1];
                        wA[kept][k] = (int) spans[k][2];
                        wB[kept][k] = (int) spans[k][3];
                    }
                }
                kept++;
            }
            n.t = Arrays.copyOf(t, kept);
            n.text = Arrays.copyOf(text, kept);
            n.wT = Arrays.copyOf(wT, kept);
            n.wE = Arrays.copyOf(wE, kept);
            n.wA = Arrays.copyOf(wA, kept);
            n.wB = Arrays.copyOf(wB, kept);
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
                             String prev, CharSequence line, String next)
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
