package io.github.lotsv8pro.lotustune;

import android.app.Activity;
import android.app.WallpaperColors;
import android.app.WallpaperManager;
import android.content.Context;
import android.graphics.Color;
import android.os.Bundle;
import android.view.View;

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
    @Override
    public void onCreate(Bundle savedInstanceState)
    {
        super.onCreate(savedInstanceState);
        sCtx = getApplicationContext();
        sActivity = this;

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
    // still use the real name). Returns "ip,ip,â€¦" or "".
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
