/**
 * Solver JS for the YouTube signature/n-parameter challenges.
 *
 * Runs the same challenge-solver scripts that yt-dlp uses (bundled as
 * assets/solver/{lib.min.js, core.min.js}) inside the system WebView
 * (V8 engine). The C++ side feeds the player JS text plus the challenge
 * values and polls for the result: the caller (the Qt main thread)
 * is the Android UI thread, so it must never block on WebView work.
 *
 * License of the bundled scripts: see assets/solver/LICENSES.md
 *
 * Robustez (esto era "solo suena la primera cancion"):
 *  - El WebView se crea UNA vez y NO se recarga en cada solve. Antes se
 *    hacia loadUrl("about:blank") por peticion y eso borraba el flag de
 *    scripts inyectados (se reinyectaba ~1 MB cada vez) y podia tirar la
 *    evaluacion que estaba en vuelo.
 *  - Hay un vigilante: si la respuesta de evaluateJavascript no llega en
 *    15 s, se marca error, se suelta sBusy y se destruye el WebView para
 *    que la siguiente peticion empiece limpia. Sin esto sBusy se quedaba
 *    en true para siempre y TODAS las canciones siguientes daban
 *    "error:solver busy" en silencio.
 */
package com.lotustuneremote.app;

import android.content.Context;
import android.webkit.WebView;
import android.webkit.ValueCallback;
import android.webkit.WebViewClient;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONObject;
import org.json.JSONTokener;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public class WebViewSolver
{
    private static WebView sWeb;
    private static volatile boolean sBusy = false;
    private static volatile boolean sLoaded = false;
    private static volatile long sEpoch = 0;   // solve en curso
    private static final Object sLock = new Object();
    private static final Object sLoadLock = new Object();
    private static final Handler sMain = new Handler(Looper.getMainLooper());

    // Watchdog: when the WebView does not answer within this time, it is
    // rearmed.
    private static final long kSolveTimeoutMs = 15000;

    // Poll-safe status for the C++ side: "idle" | "working" | "done" | "error:<msg>"
    public static volatile String sStatus = "idle";
    // Result of the last solve (JSON in the jsc output format).
    public static volatile String sResult = null;

    private static String loadAsset(Context ctx, String path) throws Exception
    {
        InputStream in = ctx.getAssets().open(path);
        BufferedReader r = new BufferedReader(new InputStreamReader(in, "UTF-8"));
        StringBuilder sb = new StringBuilder();
        char[] buf = new char[65536];
        int n;
        while ((n = r.read(buf)) > 0)
            sb.append(buf, 0, n);
        r.close();
        return sb.toString();
    }

    // Runs something on the UI thread and waits for it to finish: that way
    // the solver thread can create/check the WebView without races.
    private static void runOnUiAndWait(final Runnable r)
    {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            r.run();
            return;
        }
        final CountDownLatch latch = new CountDownLatch(1);
        sMain.post(new Runnable() {
            @Override
            public void run() {
                try { r.run(); } finally { latch.countDown(); }
            }
        });
        try { latch.await(10, TimeUnit.SECONDS); } catch (InterruptedException ignored) { }
    }

    // Destroys the WebView (on the UI thread) so the next request creates a
    // new one. It is used when an evaluation does not answer.
    private static void resetWeb()
    {
        sMain.post(new Runnable() {
            @Override
            public void run() {
                try {
                    if (sWeb != null) {
                        sWeb.stopLoading();
                        sWeb.destroy();
                    }
                } catch (Throwable ignored) { }
                sWeb = null;
                sLoaded = false;
            }
        });
    }

    // Called from any thread; enqueues the work and returns immediately.
    // The input JSON is the complete `jsc()` input (the C++ side composes
    // it: type player/preprocessed + requests). The result is polled
    // through sStatus/sResult.
    public static void solve(final String inputJson)
    {
        final long token;
        synchronized (sLock) {
            if (sBusy) {
                sStatus = "error:solver busy";
                return;
            }
            sBusy = true;
            token = ++sEpoch;
            // Before releasing the thread: the C++ poll must not read "done" and
            // the result of the PREVIOUS request.
            sResult = null;
            sStatus = "working";
        }
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    // The solver has no Activity of its own: MainActivity
                    // keeps the application context (set in onCreate) for
                    // exactly this kind of background helper.
                    final Context ctx = MainActivity.sCtx;
                    if (ctx == null)
                        throw new RuntimeException("no context");
                    sStatus = "working";

                    final String lib = loadAsset(ctx, "solver/lib.min.js");
                    final String core = loadAsset(ctx, "solver/core.min.js");
                    final String scripts = lib + "\nObject.assign(globalThis, lib);\n" + core + "\n";

                    // A single WebView for the whole session: it is only created (and
                    // about:blank loaded) the first time or after a rearm on timeout.
                    final boolean[] needLoad = { false };
                    runOnUiAndWait(new Runnable() {
                        @Override
                        public void run() {
                            try {
                                if (sWeb == null) {
                                    sWeb = new WebView(ctx.getApplicationContext());
                                    sWeb.getSettings().setJavaScriptEnabled(true);
                                    sWeb.getSettings().setDisplayZoomControls(false);
                                    sWeb.getSettings().setAllowContentAccess(false);
                                    sWeb.getSettings().setAllowFileAccess(false);
                                    sWeb.getSettings().setAllowFileAccessFromFileURLs(false);
                                    sWeb.getSettings().setAllowUniversalAccessFromFileURLs(false);
                                    sWeb.getSettings().setMediaPlaybackRequiresUserGesture(false);
                                    sWeb.setWebViewClient(new WebViewClient() {
                                        @Override
                                        public void onPageFinished(WebView v, String url) {
                                            sLoaded = true;
                                            synchronized (sLoadLock) { sLoadLock.notifyAll(); }
                                        }
                                        @Override
                                        public boolean shouldOverrideUrlLoading(WebView v, String url) {
                                            return true;
                                        }
                                    });
                                    sLoaded = false;
                                    needLoad[0] = true;
                                    sWeb.loadUrl("about:blank");
                                }
                            } catch (Exception ex) {
                                sStatus = "error:" + ex.getMessage();
                            }
                        }
                    });

                    if (needLoad[0]) {
                        synchronized (sLoadLock) {
                            final long deadline = System.currentTimeMillis() + 20000;
                            while (!sLoaded && System.currentTimeMillis() < deadline)
                                sLoadLock.wait(1000);
                            if (!sLoaded && sEpoch == token)
                                throw new RuntimeException("WebView load timeout");
                        }
                    }

                    if (sEpoch != token) {
                        // Another request took over this one (timeout): the WebView is left
                        // alone.
                        return;
                    }

                    // Watchdog of the solve: when the callback does not arrive, the lock
                    // is released and the WebView is rearmed.
                    sMain.postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            boolean expired = false;
                            synchronized (sLock) {
                                if (sEpoch == token && sBusy) {
                                    sBusy = false;
                                    expired = true;
                                }
                            }
                            if (expired) {
                                sStatus = "error:solver timeout";
                                sResult = null;
                                resetWeb();
                            }
                        }
                    }, kSolveTimeoutMs);

                    final Runnable evaluateStep = new Runnable() {
                        @Override
                        public void run() {
                            try {
                                final StringBuilder js = new StringBuilder();
                                // The scripts are evaluated ONCE per WebView and the function is kept in
                                // globalThis: that way "jsc" still exists in the following solves (it
                                // used to reload the page on every one just to have it in scope).
                                js.append("(function(){\n");
                                js.append("if (!globalThis.__ltmJsc) {\n");
                                js.append(scripts);
                                js.append("\nglobalThis.__ltmJsc = (typeof jsc === 'function') ? jsc : globalThis.jsc;\n");
                                js.append("}\ntry { var IN = JSON.parse(");
                                js.append(JSONObject.quote(inputJson));
                                js.append("); return JSON.stringify(globalThis.__ltmJsc(IN)); }");
                                js.append(" catch (e) { return JSON.stringify({type:\"error\", error:String(e)}); }\n");
                                js.append("})();");
                                sWeb.evaluateJavascript(js.toString(), new ValueCallback<String>() {
                                    @Override
                                    public void onReceiveValue(String value) {
                                        try {
                                            // The callback passes the return value
                                            // JSON-encoded: unquote it.
                                            final String out = (value == null || value.equals("null"))
                                                ? null
                                                : String.valueOf(new JSONTokener(value).nextValue());
                                            sResult = out;
                                            sStatus = (out != null && out.contains("\"type\":\"result\""))
                                                ? "done" : ("error:" + String.valueOf(out));
                                        } catch (Exception ex) {
                                            sStatus = "error:" + ex.getMessage();
                                        } finally {
                                            synchronized (sLock) { sBusy = false; }
                                        }
                                    }
                                });
                            } catch (Exception ex) {
                                setStatus("error:" + ex.getMessage());
                            }
                        }
                    };
                    sMain.post(evaluateStep);
                } catch (Exception ex) {
                    setStatus("error:" + ex.getMessage());
                }
            }
        }).start();
    }

    private static void setStatus(String s)
    {
        sStatus = s;
        synchronized (sLock) { sBusy = false; }
    }
}
