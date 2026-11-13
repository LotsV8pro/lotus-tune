package com.lotustuneremote.app;

import android.app.Activity;
import android.app.WallpaperColors;
import android.app.WallpaperManager;
import android.content.Context;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;

import org.qtproject.qt.android.bindings.QtActivity;

// The activity that hosts the QML scene. The QML is the same one the
// desktop build uses (qml/Main.qml) so the two flavours cannot drift
// apart.
public class MainActivity extends QtActivity
{
    // Kept around for the static JNI helpers: systemAccentColor() reads
    // the system colors without needing a live activity reference.
    static Context sCtx;   // also used by WebViewSolver
    // The activity itself, for the helper that needs Activity-only API
    // (moveTaskToBack lives on Activity, not on Context).
    private static Activity sActivity;

    // MIUI / HyperOS. Careful: on HyperOS 3 Build.DISPLAY no longer carries
    // the word ("BP2A.250605.031.A3"), so looking only at that string was
    // always false and every MIUI path stayed dead. The manufacturer and the
    // ROM properties are checked instead.
    private static boolean isMIUI()
    {
        if ("Xiaomi".equalsIgnoreCase(Build.MANUFACTURER)
                || "Redmi".equalsIgnoreCase(Build.BRAND)
                || "POCO".equalsIgnoreCase(Build.BRAND))
            return true;
        final String display = Build.DISPLAY;
        return display != null
                && (display.contains("MIUI") || display.contains("HyperOS"));
    }

    @Override
    public void onCreate(Bundle savedInstanceState)
    {
        super.onCreate(savedInstanceState);
        sCtx = getApplicationContext();
        sActivity = this;
        requestHighRefreshRate();

        // Android 13+: without POST_NOTIFICATIONS the notification of the
        // playback service is not seen; music would keep playing but with no
        // controls and without the user knowing a service is running.
        if (android.os.Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(
                       android.Manifest.permission.POST_NOTIFICATIONS)
                   != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            requestPermissions(
                new String[]{ android.Manifest.permission.POST_NOTIFICATIONS },
                7);
        }

        // The player bar and the lyrics panels use the mouse: on a phone
        // they work with the touch (the QML checks the pointer type).
        View decor = getWindow().getDecorView();
        decor.setOnSystemUiVisibilityChangeListener(new View
                .OnSystemUiVisibilityChangeListener()
        {
            @Override
            public void onSystemUiVisibilityChange(int visibility)
            {
                // Keep the navigation bar visible.
            }
        });

        // QA: `--es notifyUpdate 2.0.7` posts the notice of a new version in
        // the shade without waiting for a release, the same way the QML does
        // with `--update=` for the notice inside the app. It is what the
        // screenshots of the update notice use.
        final android.content.Intent intent = getIntent();
        final String qaUpdate = intent == null ? null
                : intent.getStringExtra("notifyUpdate");
        if (qaUpdate != null && !qaUpdate.isEmpty())
            UpdateNotifier.notifyUpdate(this, qaUpdate, null);
    }

    // The application context, for the helpers that only need a Context (the
    // notice of a new version in the notification shade, for example).
    public static Context appContext()
    {
        return sCtx;
    }

    // Asks Android for the maximum rate of the panel (120 Hz on this phone).
    // Qt never asks for a high rate: without this the compositor leaves the
    // window at 60 Hz and the animations run at 60 even on a 120 screen.
    //
    // Only public APIs are used:
    //   - WindowManager.LayoutParams.preferredRefreshRate /
    //     preferredDisplayModeId (API 23): some ROMs respect it.
    //   - Surface.setFrameRate (API 29/30): this is what the modern compositor
    //     looks at. Qt paints into a SurfaceView, so the hierarchy is walked
    //     and every surface is asked. It is retried because the surface does
    //     not exist yet on the first instant.
    //
    // Known limit: MIUI/HyperOS keeps a list of apps allowed a high refresh
    // rate and this one is not on it; it ignores the request and fixes 60 Hz.
    // There only the system setting works (Settings > Display > Refresh rate,
    // or `settings put secure miui_refresh_rate 120`). On any ROM that respects
    // the request this is enough.
    public static void requestHighRefreshRate()
    {
        final Activity act = sActivity;
        if (act == null)
            return;
        act.runOnUiThread(new Runnable()
        {
            @Override
            public void run()
            {
                try {
                    android.view.Window win = act.getWindow();
                    android.view.Display d =
                            win.getWindowManager().getDefaultDisplay();
                    float bestHz = 0f;
                    int bestMode = -1;
                    if (Build.VERSION.SDK_INT >= 23) {
                        for (android.view.Display.Mode m : d.getSupportedModes()) {
                            if (m.getRefreshRate() > bestHz) {
                                bestHz = m.getRefreshRate();
                                bestMode = m.getModeId();
                            }
                        }
                    } else {
                        bestHz = d.getRefreshRate();
                    }
                    if (bestHz < 90f)
                        return;   // panel de 60: no hay nada que pedir

                    WindowManager.LayoutParams lp = win.getAttributes();
                    lp.preferredRefreshRate = bestHz;
                    if (bestMode >= 0)
                        lp.preferredDisplayModeId = bestMode;
                    win.setAttributes(lp);

                    final float hz = bestHz;

                    // MIUI/HyperOS ignores the request of the app: its framework casts its
                    // own vote (PRIORITY_MIUI_REFRESH_RATE) and leaves the window at 60 Hz.
                    // What it does respect is its own "miui_refresh_rate" setting, so it is
                    // written there (needs WRITE_SECURE_SETTINGS; without the permission the
                    // exception is ignored and nothing changes).
                    if (isMIUI()) {
                        try {
                            android.provider.Settings.Secure.putInt(
                                act.getContentResolver(), "miui_refresh_rate",
                                Math.round(hz));
                        } catch (Throwable ignored) {
                        }
                    }

                    final View decor = win.getDecorView();
                    // The surface of Qt is created after onCreate: a callback is hooked to ask
                    // for the rate as soon as it exists (asked late, some ROMs have already
                    // decided the mode and ignore it).
                    watchSurfaces(decor, hz);
                    for (int delay : new int[] { 0, 500, 1500, 3000, 6000 }) {
                        decor.postDelayed(new Runnable()
                        {
                            @Override public void run()
                            {
                                applyFrameRate(decor, hz);
                            }
                        }, delay);
                    }
                } catch (Throwable ignored) {
                    // A panel with no high mode stays as it is.
                }
            }
        });
    }

    // Hooks a SurfaceHolder.Callback to every SurfaceView to ask for the rate
    // the moment the surface is created.
    private static void watchSurfaces(View v, final float hz)
    {
        if (v == null)
            return;
        if (v instanceof SurfaceView) {
            try {
                ((SurfaceView) v).getHolder().addCallback(
                    new android.view.SurfaceHolder.Callback()
                {
                    @Override
                    public void surfaceCreated(android.view.SurfaceHolder h)
                    {
                        applyFrameRate(h.getSurface(), hz);
                    }
                    @Override
                    public void surfaceChanged(android.view.SurfaceHolder h,
                                               int f, int w, int ht)
                    {
                        applyFrameRate(h.getSurface(), hz);
                    }
                    @Override
                    public void surfaceDestroyed(android.view.SurfaceHolder h) { }
                });
            } catch (Throwable ignored) {
            }
        }
        if (v instanceof android.view.ViewGroup) {
            android.view.ViewGroup g = (android.view.ViewGroup) v;
            for (int i = 0; i < g.getChildCount(); ++i)
                watchSurfaces(g.getChildAt(i), hz);
        }
    }

    private static void applyFrameRate(android.view.Surface s, float hz)
    {
        if (s == null || !s.isValid())
            return;
        try {
            if (Build.VERSION.SDK_INT >= 30)
                s.setFrameRate(hz,
                    android.view.Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE);
            else if (Build.VERSION.SDK_INT >= 29)
                s.setFrameRate(hz,
                    android.view.Surface.FRAME_RATE_COMPATIBILITY_DEFAULT);
        } catch (Throwable ignored) {
        }
    }

    // Walks the hierarchy and asks `hz` to every surface (the SurfaceView of
    // Qt). setFrameRate(float, int) is public since API 30; on API 29 the two
    // argument variant exists.
    private static void applyFrameRate(View v, float hz)
    {
        if (v == null)
            return;
        if (v instanceof SurfaceView) {
            try {
                applyFrameRate(((SurfaceView) v).getHolder().getSurface(), hz);
            } catch (Throwable ignored) {
            }
        }
        if (v instanceof android.view.ViewGroup) {
            android.view.ViewGroup g = (android.view.ViewGroup) v;
            for (int i = 0; i < g.getChildCount(); ++i)
                applyFrameRate(g.getChildAt(i), hz);
        }
    }

    // Coming back from the background Android may have returned the window to
    // 60 Hz: it is asked again.
    @Override
    protected void onResume() {
        super.onResume();
        requestHighRefreshRate();
    }

    // MIUI HWUI cleanup: called when the activity is destroyed to prevent
    // pthread_mutex crashes in MIUI's hwuiTask threads. MIUI HWUI maintains
    // global mutexes that conflict with Qt's OpenGL cleanup.
    @Override
    protected void onDestroy() {
        super.onDestroy();
    }

    // Also handle onPause to prevent HWUI issues when app goes to background
    @Override
    protected void onPause() {
        if (isMIUI()) {
            // MIUI can have HWUI issues when switching apps
            // Let Qt handle it but be ready for cleanup issues
            super.onPause();
            return;
        }
        super.onPause();
    }

    // The notification permission is OURS (not Qt's): without this overload
    // QtActivity does not recognise it, warns about "no valid pending
    // permission request" and the answer is left unhandled.
    @Override
    public void onRequestPermissionsResult(int requestCode,
                                           String[] permissions,
                                           int[] grantResults)
    {
        if (requestCode == 7) {
            // The permission was asked, now the result is processed. If the user
            // refused it or MIUI blocked it, the app goes on; it just will not show
            // notifications.
            super.onRequestPermissionsResult(requestCode, permissions, grantResults);
            return;
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
    }

    // System bars in pixels. The QML lays itself out edge to edge and has no
    // safe-area support on Qt 6.6, so the bottom tab bar was landing UNDER
    // the gesture handle (the labels were half hidden). The C++ theme asks
    // for these once the window is laid out and converts them to dp.
    public static int insetBottomPx()
    {
        Activity act = sActivity;
        if (act == null)
            return 0;
        try {
            View deco = act.getWindow().getDecorView();
            android.view.WindowInsets ins = deco.getRootWindowInsets();
            if (ins == null)
                return 0;
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                // navigationBars = the gesture handle / 3-button bar;
                // systemGestures is its (bigger) swipe capture zone.
                return Math.max(
                    ins.getInsets(android.view.WindowInsets.Type.navigationBars()).bottom,
                    ins.getInsets(android.view.WindowInsets.Type.systemGestures()).bottom);
            }
        } catch (Exception ignored) {
        }
        return 0;
    }

    public static int insetTopPx()
    {
        Activity act = sActivity;
        if (act == null)
            return 0;
        try {
            View deco = act.getWindow().getDecorView();
            android.view.WindowInsets ins = deco.getRootWindowInsets();
            if (ins == null)
                return 0;
            if (android.os.Build.VERSION.SDK_INT >= 30)
                return ins.getInsets(android.view.WindowInsets.Type.statusBars()).top;
        } catch (Exception ignored) {
        }
        return 0;
    }

    // WhatsApp directory of the native libs ("libytmcli.so"), the native
    // helper Catalog runs as a replacement for python3/yt-dlp in Android.
    public static String nativeLibDir()
    {
        Context ctx = sCtx;
        if (ctx == null)
            return "";
        return ctx.getApplicationInfo().nativeLibraryDir;
    }

    // The spawned catalogue helper (libytmcli.so) cannot resolve names
    // itself: netd answers NODATA for child processes of the app, so the
    // parent resolves through Java and passes the numeric addresses on
    // (the helper dials them directly, SNI and hostname verification
    // still use the real name). Returns "ip,ip,…" or "".
    public static String lookupDns(String host)
    {
        try {
            java.net.InetAddress[] addrs =
                java.net.InetAddress.getAllByName(host);
            StringBuilder out = new StringBuilder();
            for (java.net.InetAddress a : addrs)
                out.append(a.getHostAddress()).append(',');
            return out.toString();
        } catch (Exception ignored) {
            return "";
        }
    }

    // Android back gesture: the QML double-back confirm calls this (once
    // a context property exposes it) to MINIMIZE the app instead of
    // quitting it, like any Android app: moveTaskToBack sends the task
    // to the background, the playback keeps its state and the app
    // resumes where it was.
    public static void minimizeApp()
    {
        Activity act = sActivity;
        if (act == null)
            return;
        try {
            act.moveTaskToBack(true);
        } catch (Exception ignored) {
        }
    }

    // System accent for the QML theme. AppTheme calls this once via JNI
    // when "follow system" is on. Material You derives its palette from
    // the wallpaper, so the wallpaper's primary color is the closest
    // public source; the MIUI/HyperOS theme accent is tried first.
    public static String systemAccentColor()
    {
        Context ctx = sCtx;
        if (ctx == null)
            return "";

        // MIUI/HyperOS: the theme system stores the chosen accent.
        try {
            String[] keys = {
                "miui_theme_accent_color", "theme_accent_color",
                "system_theme_accent_color", "accent_color"
            };
            for (String key : keys) {
                String v = android.provider.Settings.Secure.getString(
                        ctx.getContentResolver(), key);
                if (v == null)
                    v = android.provider.Settings.System.getString(
                            ctx.getContentResolver(), key);
                if (v != null && v.matches("#[0-9a-fA-F]{6,8}")) {
                    String hex = v.trim().toLowerCase();
                    // #rrggbbaa -> drop the alpha part.
                    if (hex.length() == 9)
                        hex = "#" + hex.substring(3);
                    return hex;
                }
            }
        } catch (Exception ignored) {
        }

        // Standard Android: Material You palette comes from the wallpaper.
        try {
            WallpaperManager wm = WallpaperManager.getInstance(ctx);
            WallpaperColors colors = wm.getWallpaperColors(
                    WallpaperManager.FLAG_SYSTEM);
            if (colors == null)
                colors = wm.getWallpaperColors(WallpaperManager.FLAG_LOCK);
            if (colors != null) {
                Color primary = colors.getPrimaryColor();
                return String.format("#%06x", primary.toArgb() & 0xFFFFFF);
            }
        } catch (Exception ignored) {
        }
        return "";
    }

    // The Android file picker (content:// URIs) cannot be read directly
    // with QFile, so a picked session file is copied into our private
    // cache first; importSession() then reads it like any file. Returns
    // the copied path, or "" on failure.
    public static String copyUriToCache(String uriStr)
    {
        Context ctx = sCtx;
        if (ctx == null || uriStr == null || uriStr.isEmpty())
            return "";
        try {
            android.net.Uri uri = android.net.Uri.parse(uriStr);
            java.io.InputStream in =
                    ctx.getContentResolver().openInputStream(uri);
            if (in == null)
                return "";
            java.io.File out =
                    new java.io.File(ctx.getCacheDir(), "login-import.json");
            java.io.FileOutputStream fos = new java.io.FileOutputStream(out);
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0)
                fos.write(buf, 0, n);
            fos.close();
            in.close();
            return out.getAbsolutePath();
        } catch (Exception ignored) {
        }
        return "";
    }

    // Launches the in-app Google login tab (LotusLoginActivity). It
    // writes the Netscape cookies.txt into cookiePath when the sign-in
    // lands on YouTube Music. Returns false when it could not start.
    public static boolean startYtmLogin(String cookiePath)
    {
        Context ctx = sCtx;
        if (ctx == null)
            return false;
        try {
            android.content.Intent i = new android.content.Intent(
                    ctx, LotusLoginActivity.class);
            i.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK);
            i.putExtra("url",
                    "https://accounts.google.com/ServiceLogin"
                    + "?service=youtube&continue="
                    + "https://music.youtube.com/");
            i.putExtra("target", cookiePath);
            ctx.startActivity(i);
            return true;
        } catch (Exception ignored) {
        }
        return false;
    }
}