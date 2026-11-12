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
 * La linea activa se pinta en dos capas: debajo la frase entera en tinta
 * apagada y encima la misma frase en tinta fuerte, recortada por su ancho
 * maximo (TextView.setMaxWidth). Moviendo ese ancho, lo ya cantado avanza
 * pixel a pixel, igual que el barrido de la app: entre fotograma y fotograma
 * solo viaja un entero por fila, nunca un texto nuevo.
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
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.util.DisplayMetrics;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.util.TypedValue;
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
    // Las dos tintas del karaoke viven en el layout (l_dimA* apagada,
    // l_sunA* encendida). La frontera es el ancho maximo de la copia
    // encendida (TextView.setMaxWidth): crece por la derecha y deja al
    // descubierto lo apagado.

    // Geometria del widget. Todo se calcula y se envia en pixeles: el ancho
    // que reporta el host, el tamano de letra y el ancho maximo de la capa
    // encendida se miden en el mismo espacio fisico, asi que la cuenta sale
    // igual sea cual sea la densidad con la que el launcher infle el widget.
    private static final int PAD_H_DP = 16;
    private static final int PAD_V_DP = 14;
    private static final int[] SIZES_SP = { 24, 21, 18, 15 };
    private static final long FRAME_MS = 70L;

    // Cada cuantos fotogramas se manda el bloque entero en vez de solo la
    // frontera (red de seguridad si el host reinfla el widget).
    private static final int REDRAW_EVERY = 10;
    private static long sFrames = 0;

    private static final int PREV_ID = R.id.l_prev_line;
    private static final int NEXT_ID = R.id.l_next;
    private static final int[] ROWS = { R.id.l_rowA0, R.id.l_rowA1 };
    private static final int[] DIMS = { R.id.l_dimA0, R.id.l_dimA1 };
    private static final int[] SUNS = { R.id.l_sunA0, R.id.l_sunA1 };

    // Repintador de la frontera del canto: un fotograma cada FRAME_MS mientras
    // la linea tenga tiempos de palabra y no se haya terminado. Solo corre con
    // la pantalla encendida y con la cancion sonando.
    private static Handler sFrontHandler = null;
    private static Runnable sFrontRunnable = null;

    // Fallback trio: the QML pushes it when the index changes.
    public static volatile String sPrev = "";
    public static volatile String sLine = "";
    public static volatile String sNext = "";

    // Lo que hay pintado ahora. El latido de 1 Hz compara con esto para no
    // repintar la misma linea; los fotogramas del barrido leen el texto de
    // aqui sin volver a medirlo.
    private static String sShownLine = null;
    private static String sShownPrev = "";
    private static String sShownNext = "";

    // Geometria con la que se pinto la linea que hay ahora: los fotogramas la
    // reutilizan y solo recalculan el ancho maximo.
    private static Geom sGeom = null;

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

    /**
     * La linea repartida en dos filas, con el ancho de cada prefijo ya medido.
     * Se calcula una vez por linea y por tamano de widget; los fotogramas solo
     * leen de aqui.
     */
    private static final class Geom
    {
        int innerPx = 0;                 // ancho util del widget, sin margenes
        float textPx = 0;                // tamano de letra de la linea
        String[] row = { "", "" };       // texto de cada fila
        float[][] pre = { { 0 }, { 0 } }; // ancho acumulado letra a letra, en px
        int end0 = 0;                    // ultima letra de la fila 1 en la linea
        int start1 = 0;                  // primera letra de la fila 2 en la linea
    }

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
        sShownPrev = prev;
        sShownLine = line;
        sShownNext = next;
        // Cuando la linea trae tiempos de palabra, la frontera sale de la
        // posicion; sin ellos no hay karaoke y la frase se queda entera.
        final double front = (s.p != null && s.idx >= 0
                              && hasWords(s.p, s.idx))
                ? frontFor(s.p, s.idx, s.pos) : -1;

        for (int id : ids) {
            Geom g = geometry(context, line, widgetWidth(context, id));
            sGeom = g;
            m.updateAppWidget(id, build(context, prev, next, g, front));
        }
        // Con la linea en pantalla, el karaoke toma el relevo hasta la siguiente.
        armFront(context);
    }

    // ---- medidas de la linea -------------------------------------------

    /**
     * Reparte `line` en las dos filas del widget con el mayor tamano de letra
     * que quepa. El ancho de cada prefijo se mide en pixeles con la misma
     * tipografia que pinta la vista, asi la frontera cae donde cae la letra.
     */
    private static Geom geometry(Context c, String line, int widthDp)
    {
        Geom g = new Geom();
        final DisplayMetrics dm = c.getResources().getDisplayMetrics();
        final float fontScale = dm.scaledDensity / dm.density;
        final float d = hostDensity(c);
        g.innerPx = Math.max(40,
                Math.round((Math.max(90, widthDp) - 2 * PAD_H_DP) * d));
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setTypeface(Typeface.DEFAULT_BOLD);
        for (int size : SIZES_SP) {
            g.textPx = size * fontScale * d;
            p.setTextSize(g.textPx);
            if (split(line, p, g))
                return g;
        }
        return g;
    }

    /**
     * Densidad con la que el host infla el widget. No siempre es la del
     * sistema: MIUI encoge el contenido de los widgets al 78 % (su
     * LauncherWidgetLayoutFactory infla a 0.78 de la densidad de pantalla),
     * asi que los dp de la vista no son los dp de las acciones. El resto de
     * launchers usan la densidad normal.
     */
    private static float hostDensity(Context c)
    {
        final float density = c.getResources().getDisplayMetrics().density;
        return density * (scaledWidgets(c) ? 0.78f : 1f);
    }

    private static Boolean sScaled = null;

    private static boolean scaledWidgets(Context c)
    {
        if (sScaled != null)
            return sScaled;
        boolean scaled = false;
        try {
            PackageManager pm = c.getPackageManager();
            Intent home = new Intent(Intent.ACTION_MAIN)
                    .addCategory(Intent.CATEGORY_HOME);
            ResolveInfo ri = pm.resolveActivity(home,
                    PackageManager.MATCH_DEFAULT_ONLY);
            if (ri != null && ri.activityInfo != null)
                scaled = "com.miui.home".equals(ri.activityInfo.packageName);
        } catch (Throwable ignore) {
        }
        sScaled = scaled;
        return scaled;
    }

    /** Dos filas como mucho, cortando por palabra. */
    private static boolean split(String line, Paint p, Geom g)
    {
        final int len = line.length();
        int cut = len;
        if (p.measureText(line) > g.innerPx)
            cut = fitEnd(line, p, g.innerPx);
        if (cut < len) {
            final int sp = line.lastIndexOf(' ', cut);
            if (sp > 0)
                cut = sp;
        }
        final String rest = line.substring(cut);
        final String r0 = rtrim(line.substring(0, cut));
        final String r1 = rest.trim();
        if (!r1.isEmpty() && p.measureText(r1) > g.innerPx)
            return false;
        g.row[0] = r0;
        g.row[1] = r1;
        g.end0 = r0.length();
        g.start1 = cut + (rest.length() - r1.length());
        g.pre[0] = cumulative(r0, p);
        g.pre[1] = cumulative(r1, p);
        return true;
    }

    /** Longitud del trozo mas largo que cabe en `maxPx`. */
    private static int fitEnd(String s, Paint p, float maxPx)
    {
        int lo = 0;
        int hi = s.length();
        while (lo < hi) {
            final int mid = (lo + hi + 1) >>> 1;
            if (p.measureText(s, 0, mid) <= maxPx)
                lo = mid;
            else
                hi = mid - 1;
        }
        return lo;
    }

    private static float[] cumulative(String s, Paint p)
    {
        float[] out = new float[s.length() + 1];
        for (int i = 1; i <= s.length(); ++i)
            out[i] = p.measureText(s, 0, i);
        return out;
    }

    private static String rtrim(String s)
    {
        int e = s.length();
        while (e > 0 && s.charAt(e - 1) == ' ')
            --e;
        return s.substring(0, e);
    }

    // ---- karaoke -------------------------------------------------------

    /**
     * Ancho maximo de la capa encendida de la fila `row`: lo que hay desde el
     * principio de la frase hasta la letra que se esta cantando.
     */
    private static float clipPx(Geom g, int row, double front)
    {
        final int len = g.row[row].length();
        final float full = g.pre[row][len];
        final double at;
        if (row == 0)
            at = Math.min(front, g.end0);
        else
            at = Math.max(0, front - g.start1);
        float w = (g.innerPx - full) / 2f + prefixWidth(g, row, at);
        if (w < 0)
            w = 0;
        if (w > g.innerPx)
            w = g.innerPx;
        return w;
    }

    /** Ancho del prefijo de `at` letras (at puede ser fraccionario). */
    private static float prefixWidth(Geom g, int row, double at)
    {
        final float[] pre = g.pre[row];
        final int len = pre.length - 1;
        if (at <= 0)
            return 0;
        if (at >= len)
            return pre[len];
        final int k = (int) at;
        final float f = (float) (at - k);
        return pre[k] + (pre[k + 1] - pre[k]) * f;
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

    private static boolean hasWords(Published p, int idx)
    {
        return idx >= 0 && idx < p.wT.length
                && p.wT[idx] != null && p.wT[idx].length > 0;
    }

    /** Si la ultima palabra de la linea ya se canto: la siguiente la trae el latido. */
    private static boolean pastEnd(Published p, int idx, double pos)
    {
        if (!hasWords(p, idx))
            return true;
        final int n = p.wT[idx].length;
        return pos >= p.wE[idx][n - 1];
    }

    /** Programa el siguiente fotograma; sin karaoke, apaga el reloj. */
    static void armFront(final Context context)
    {
        if (context == null)
            return;
        final Context app = context.getApplicationContext();
        Shot s = shotAt(app);
        if (!PlayerWidget.sPlaying || s.p == null || s.idx < 0
                || !hasWords(s.p, s.idx) || pastEnd(s.p, s.idx, s.pos)) {
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
                    if (pm != null && !pm.isInteractive())
                        return;
                    Shot now = shotAt(app);
                    if (now.p == null) {
                        stopFront();
                        return;
                    }
                    if (sShownLine != null
                            && !sShownLine.equals(now.line.trim())) {
                        // La linea cambio entre dos latidos: el fotograma no
                        // puede seguir moviendo la vieja.
                        render(app);
                        return;
                    }
                    renderFront(app);
                    armFront(app);
                }
            };
        }
        sFrontHandler.removeCallbacks(sFrontRunnable);
        sFrontHandler.postDelayed(sFrontRunnable, FRAME_MS);
    }

    static void stopFront()
    {
        if (sFrontHandler != null && sFrontRunnable != null)
            sFrontHandler.removeCallbacks(sFrontRunnable);
    }

    /**
     * Fotograma barato: solo el ancho maximo de las dos filas. El texto y los
     * tamanos ya estan puestos por el ultimo render completo.
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
        final Geom g = sGeom;
        if (g == null || sShownLine == null)
            return;
        final Shot s = shotAt(context);
        if (s.p == null || s.idx < 0)
            return;
        final double front = frontFor(s.p, s.idx, s.pos);
        // Casi todos los fotogramas llevan solo la frontera: con cuatro
        // acciones bastan, y el host de MIUI tarda bastante menos en
        // aplicarlos (medido: 15 Hz con el bloque entero, 12 Hz asi, pero
        // con un tercio del coste y el mismo barrido a la vista). Cada
        // REDRAW_EVERY fotogramas va el bloque completo, por si el host
        // reinflo el arbol por su cuenta y se quedo sin texto ni colores.
        final boolean full = (sFrames++ % REDRAW_EVERY) == 0;
        for (int id : ids) {
            if (full) {
                m.updateAppWidget(id, build(context, sShownPrev, sShownNext,
                                            g, front));
                continue;
            }
            RemoteViews v = new RemoteViews(context.getPackageName(),
                                            R.layout.widget_lyrics);
            for (int r = 0; r < 2; ++r) {
                v.setInt(SUNS[r], "setMaxWidth",
                         Math.max(0, Math.round(clipPx(g, r, front))));
            }
            m.updateAppWidget(id, v);
        }
    }

    /**
     * RemoteViews completo del widget. Cada fotograma lleva todo lo que pinta
     * la vista y no solo el ancho de la frontera: el host de MIUI reinfla el
     * arbol en algunos avisos, y con un aviso a medias el widget se quedaba en
     * blanco un fotograma.
     */
    private static RemoteViews build(Context context, String prev,
                                     String next, Geom g, double front)
    {
        RemoteViews v = new RemoteViews(context.getPackageName(),
                                        R.layout.widget_lyrics);
        fill(v, prev, next, g, front);
        // El widget es solo la letra: tocar cualquier parte abre la app.
        final PendingIntent open = openApp(context);
        if (open != null)
            v.setOnClickPendingIntent(R.id.l_root, open);
        return v;
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

    // ---- pintado -------------------------------------------------------

    /**
     * Rellena el bloque: la anterior, las dos filas de la activa en sus dos
     * capas, y la siguiente.
     */
    private static void fill(RemoteViews v, String prev, String next,
                             Geom g, double front)
    {
        v.setTextViewText(NEXT_ID, next);
        v.setTextViewTextSize(NEXT_ID, TypedValue.COMPLEX_UNIT_PX,
                              g.textPx * 14f / 24f);
        // The previous one always keeps its slot (INVISIBLE, not GONE): if it
        // disappeared, the whole block would shift on a line change and the
        // widget would jump.
        if (prev.isEmpty()) {
            v.setTextViewText(PREV_ID, "");
            v.setViewVisibility(PREV_ID, View.INVISIBLE);
        } else {
            v.setViewVisibility(PREV_ID, View.VISIBLE);
            v.setTextViewText(PREV_ID, prev);
        }
        v.setTextViewTextSize(PREV_ID, TypedValue.COMPLEX_UNIT_PX,
                              g.textPx * 13f / 24f);
        for (int r = 0; r < 2; ++r) {
            final int rowId = ROWS[r];
            final int dimId = DIMS[r];
            final int sunId = SUNS[r];
            final String text = g.row[r];
            v.setTextViewText(dimId, text);
            v.setTextViewText(sunId, text);
            v.setTextViewTextSize(dimId, TypedValue.COMPLEX_UNIT_PX, g.textPx);
            v.setTextViewTextSize(sunId, TypedValue.COMPLEX_UNIT_PX, g.textPx);
            if (text.isEmpty()) {
                v.setViewVisibility(rowId, View.GONE);
                continue;
            }
            v.setViewVisibility(rowId, View.VISIBLE);
            // El ancho maximo es la frontera: la copia encendida se recorta
            // por la derecha y deja ver la apagada que tiene debajo.
            v.setInt(sunId, "setMaxWidth",
                     Math.max(0, Math.round(clipPx(g, r, front))));
        }
    }

    /** Ancho del widget en dp, tal y como lo reporta el host. */
    private static int widgetWidth(Context c, int id)
    {
        try {
            android.os.Bundle o = AppWidgetManager.getInstance(c)
                    .getAppWidgetOptions(id);
            if (o != null) {
                final int min = o.getInt(
                        AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0);
                final int max = o.getInt(
                        AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 0);
                if (min > 0)
                    return min;
                if (max > 0)
                    return max;
            }
        } catch (Throwable ignore) {
        }
        return 300;
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
