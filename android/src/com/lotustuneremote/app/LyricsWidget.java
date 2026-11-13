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
 * La linea activa se pinta entera, en tinta fuerte, y entra con un fundido
 * corto cuando cambia: dos pasos de opacidad y un desplazamiento de pocos dp,
 * cada paso con dos setFloat (que no obligan al launcher a medir el texto otra
 * vez). Antes se barria palabra a palabra, pero un RemoteViews se aplica
 * midiendo y trazando la linea entera cada vez, y MIUI no pasa de 16 o 20
 * avisos por segundo: a esa cadencia el barrido se ve a saltos y gasta
 * bateria. La app, que dibuja en su propia ventana, si puede ir a 60.
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
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.util.DisplayMetrics;
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
    // Geometria del widget. Todo se calcula y se envia en pixeles: el ancho
    // que reporta el host y el tamano de letra se miden en el mismo espacio
    // fisico, asi la linea se parte en dos filas igual sea cual sea la
    // densidad con la que el launcher infle el widget.
    private static final int PAD_H_DP = 16;
    private static final int[] SIZES_SP = { 24, 21, 18, 15 };

    // Fundido de entrada de la linea. Son dos avisos: el primero ya deja la
    // letra legible y el segundo la termina. Con tres pasos desde el 35 % la
    // linea tardaba 140 ms en poder leerse y se notaba como retraso respecto
    // a la voz; asi el salto se ve inmediato y queda un movimiento corto.
    private static final long STEP_MS = 40L;
    private static final float[] FADE = { 0.65f, 1f };
    private static final float[] LIFT_DP = { 4f, 0f };

    // Cada cuantos repintados se manda el bloque entero aunque la linea no
    // haya cambiado. Es una red de seguridad: si el host reinflo el arbol por
    // su cuenta (cambio de tamano, launcher reiniciado), este aviso lo deja
    // como estaba sin esperar al siguiente cambio de linea.
    private static final int FULL_EVERY = 8;

    // Reloj del cambio de linea. En vez de preguntar cada 120 o 400 ms si la
    // cancion ha pasado de linea (que es lo que hacia que el salto se viera
    // tarde: medido, 109 ms de mediana), se calcula cuanto falta para la
    // siguiente y se pide un aviso para ese instante. Sale un repintado por
    // linea y el salto llega con lo que tarde el launcher en aplicarlo.
    private static final long MIN_WAIT_MS = 40L;
    private static final long MAX_WAIT_MS = 5000L;
    private static Handler sClock = null;
    private static Runnable sClockRun = null;
    private static Context sClockCtx = null;

    private static final int PREV_ID = R.id.l_prev_line;
    private static final int NEXT_ID = R.id.l_next;
    private static final int[] ROWS = { R.id.l_rowA0, R.id.l_rowA1 };

    // El fundido en curso.
    private static Handler sFadeHandler = null;
    private static Runnable sFadeRunnable = null;
    private static int sFadeStep = 0;

    // Fallback trio: the QML pushes it when the index changes.
    public static volatile String sPrev = "";
    public static volatile String sLine = "";
    public static volatile String sNext = "";

    // Lo que hay pintado ahora. El latido y los empujes del QML comparan con
    // esto para no repintar la misma linea ni repetir el fundido.
    private static String sShownLine = null;
    private static String sShownPrev = "";
    private static String sShownNext = "";
    private static int sShownWidth = -1;
    private static long sRenders = 0;

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

    /**
     * La linea repartida en las dos filas del widget y el tamano de letra que
     * le toca. Se calcula una vez por linea y por tamano de widget.
     */
    private static final class Geom
    {
        int innerPx = 0;                 // ancho util del widget, sin margenes
        float textPx = 0;                // tamano de letra de la linea
        float density = 1;               // densidad con la que infla el host
        String[] row = { "", "" };       // texto de cada fila
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
     * Latido del servicio, solo mientras suena: busca la linea con el reloj
     * publicado y repinta si ha cambiado. Sirve para que el widget siga la
     * cancion aunque el QML no este empujando nada.
     *
     * Con la pantalla apagada no se repinta: nadie mira el widget y el
     * servicio ya lo despierta cada 400 ms cuando vuelve a estar encendida.
     */
    static void tick(Context c)
    {
        if (c == null)
            return;
        sCtx = c.getApplicationContext();
        PowerManager pm = (PowerManager)
                sCtx.getSystemService(Context.POWER_SERVICE);
        if (pm != null && !pm.isInteractive())
            return;
        if (shotAt(sCtx).p == null)
            return;                       // no hay estado: manda el QML
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

    /**
     * Pinta el trio de lineas. Si la linea activa no ha cambiado no se manda
     * nada (salvo el repintado de seguridad cada FULL_EVERY): el launcher
     * aplica cada aviso midiendo y trazando el texto, y no hay nada que
     * ganar repitiendo lo mismo.
     */
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
            line = context.getString(PlayerWidget.sTitle.isEmpty()
                    ? R.string.lyrics_none : R.string.lyrics_none_track);

        final int width = widgetWidth(context, ids[0]);
        // El siguiente aviso se programa con lo que acaba de ver este repintado,
        // haya cambio o no: asi cada latido o empuje reajusta la hora del
        // proximo salto.
        scheduleNextLine(context, s);
        final boolean same = sShownLine != null && sShownLine.equals(line)
                && sShownPrev.equals(prev) && sShownNext.equals(next)
                && sShownWidth == width;
        if (same && (sRenders % FULL_EVERY) != 0)
            return;

        sShownPrev = prev;
        sShownLine = line;
        sShownNext = next;
        sShownWidth = width;
        sRenders++;

        for (int id : ids) {
            Geom g = geometry(context, line, widgetWidth(context, id));
            m.updateAppWidget(id, build(context, prev, next, g,
                                        same ? -1 : 0));
        }
        if (!same)
            startFade(context);
    }

    // ---- reloj del cambio de linea --------------------------------------

    /**
     * Deja pedido un aviso para el instante en que empieza la linea siguiente,
     * calculado con la posicion que acaba de leer este repintado. Es un solo
     * aviso por linea: mientras la cancion no cambie de linea no se pregunta
     * nada, y el salto no espera a que le toque el turno a un sondeo.
     */
    private static void scheduleNextLine(Context context, Shot s)
    {
        if (sClock == null)
            sClock = new Handler(Looper.getMainLooper());
        if (sClockRun == null) {
            sClockRun = new Runnable() {
                @Override public void run() { tick(sClockCtx); }
            };
        }
        sClock.removeCallbacks(sClockRun);
        sClockCtx = context;
        if (s.p == null || !s.playing)
            return;                     // sin estado o en pausa: manda el latido
        long wait;
        if (!"ok".equals(s.p.status) || s.p.t.length == 0) {
            // Cargando la letra o letra sin tiempos: se mira de vez en cuando.
            wait = 1000L;
        } else {
            final int next = s.idx + 1;
            if (next >= s.p.t.length)
                return;                 // no queda nada por cantar
            final double ms = (s.p.t[next] - s.pos) * 1000.0;
            if (Double.isNaN(ms) || Double.isInfinite(ms))
                return;
            wait = Math.round(ms) + 15L;
            if (wait < MIN_WAIT_MS)
                wait = MIN_WAIT_MS;
            if (wait > MAX_WAIT_MS)
                wait = MAX_WAIT_MS;
        }
        sClock.postDelayed(sClockRun, wait);
    }

    // ---- fundido de entrada --------------------------------------------

    /**
     * Arranca el fundido: el bloque ya esta pintado en el paso 0 (lo acaba de
     * mandar render()), aqui solo se programan los pasos que faltan.
     */
    private static void startFade(final Context context)
    {
        stopFade();
        sFadeStep = 0;
        if (sFadeHandler == null)
            sFadeHandler = new Handler(Looper.getMainLooper());
        if (sFadeRunnable == null) {
            sFadeRunnable = new Runnable() {
                @Override public void run() { fadeTick(context); }
            };
        }
        sFadeHandler.postDelayed(sFadeRunnable, STEP_MS);
    }

    private static void stopFade()
    {
        if (sFadeHandler != null && sFadeRunnable != null)
            sFadeHandler.removeCallbacks(sFadeRunnable);
    }

    /**
     * Un paso mas del fundido. Solo viajan dos setFloat por fila: el texto, el
     * tamano y la visibilidad siguen siendo los del ultimo bloque entero, asi
     * que el host no mide ni traza nada.
     */
    private static void fadeTick(Context context)
    {
        if (context == null)
            return;
        final int step = ++sFadeStep;
        if (step >= FADE.length)
            return;
        AppWidgetManager m = AppWidgetManager.getInstance(context);
        int[] ids = m.getAppWidgetIds(
                new ComponentName(context, LyricsWidget.class));
        if (ids == null || ids.length == 0)
            return;
        final float density = hostDensity(context);
        for (int id : ids) {
            RemoteViews v = new RemoteViews(context.getPackageName(),
                                            R.layout.widget_lyrics);
            stepInto(v, density, step);
            m.updateAppWidget(id, v);
        }
        if (step + 1 < FADE.length)
            sFadeHandler.postDelayed(sFadeRunnable, STEP_MS);
    }

    /** Deja las filas de la linea activa en el paso `step` del fundido. */
    private static void stepInto(RemoteViews v, float density, int step)
    {
        final int at = Math.max(0, Math.min(step, FADE.length - 1));
        for (int id : ROWS) {
            v.setFloat(id, "setAlpha", FADE[at]);
            v.setFloat(id, "setTranslationY", LIFT_DP[at] * density);
        }
    }

    // ---- medidas de la linea -------------------------------------------

    /**
     * Reparte `line` en las dos filas del widget con el mayor tamano de letra
     * que quepa.
     */
    private static Geom geometry(Context c, String line, int widthDp)
    {
        Geom g = new Geom();
        final DisplayMetrics dm = c.getResources().getDisplayMetrics();
        final float fontScale = dm.scaledDensity / dm.density;
        final float d = hostDensity(c);
        g.density = d;
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
        final String r0 = rtrim(line.substring(0, cut));
        final String r1 = line.substring(cut).trim();
        if (!r1.isEmpty() && p.measureText(r1) > g.innerPx)
            return false;
        g.row[0] = r0;
        g.row[1] = r1;
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

    private static String rtrim(String s)
    {
        int e = s.length();
        while (e > 0 && s.charAt(e - 1) == ' ')
            --e;
        return s.substring(0, e);
    }

    /**
     * RemoteViews completo del widget. `fade` es el paso del fundido con el que
     * se pinta la linea (-1 = ya parada, opacidad entera).
     */
    private static RemoteViews build(Context context, String prev,
                                     String next, Geom g, int fade)
    {
        RemoteViews v = new RemoteViews(context.getPackageName(),
                                        R.layout.widget_lyrics);
        fill(v, prev, next, g);
        // Se pone siempre, tambien cuando la linea ya esta quieta: si un
        // fundido se quedo a medias (pantalla apagada, host ocupado), el
        // siguiente bloque entero la deja entera y en su sitio.
        stepInto(v, g.density, fade >= 0 ? fade : FADE.length - 1);
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
            JSONArray arr = o.optJSONArray("lines");
            final int count = arr == null ? 0 : arr.length();
            double[] t = new double[count];
            String[] text = new String[count];
            int kept = 0;
            for (int i = 0; i < count; ++i) {
                JSONObject lo = arr.optJSONObject(i);
                if (lo == null || !lo.has("t"))
                    continue;
                t[kept] = lo.optDouble("t", 0);
                text[kept] = lo.optString("text", "♪").trim();
                kept++;
            }
            n.t = Arrays.copyOf(t, kept);
            n.text = Arrays.copyOf(text, kept);
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

    /** Rellena el bloque: la anterior, las dos filas de la activa, y la siguiente. */
    private static void fill(RemoteViews v, String prev, String next, Geom g)
    {
        // Un texto vacio deja la vista sin alto y todo el bloque salta; el
        // espacio (que es lo que trae el layout) mantiene el hueco.
        v.setTextViewText(NEXT_ID, next.isEmpty() ? " " : next);
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
            final String text = g.row[r];
            v.setTextViewText(rowId, text);
            v.setTextViewTextSize(rowId, TypedValue.COMPLEX_UNIT_PX, g.textPx);
            if (text.isEmpty()) {
                v.setViewVisibility(rowId, View.GONE);
                continue;
            }
            v.setViewVisibility(rowId, View.VISIBLE);
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
        double pos = 0;          // posicion de la pista con la que se calculo
        int idx = -1;            // linea que se esta pintando (-1: antes de la primera)
        boolean playing = false;
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
            out.line = c.getString(R.string.lyrics_loading);
            return out;
        }

        if ("ok".equals(p.status) && p.t.length > 0) {
            final double pos = positionNow(c, p);
            out.pos = pos;
            out.playing = PlayerWidget.sPlaying;
            int idx = lineIndexAt(p.t, pos);
            out.idx = idx;
            if (idx < 0) {
                // Before the first line (instrumental intro): a symbol and, as the
                // "next" one, the first thing that will be sung.
                out.line = "♪";
                out.next = p.text[0];
                return out;
            }
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
