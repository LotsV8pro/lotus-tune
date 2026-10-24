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
 */
package io.github.lotsv8pro.lotustune;

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

public class WebViewSolver
{
    private static WebView sWeb;
    private static volatile boolean sBusy = false;
    private static volatile boolean sLoaded = false;
    private static final Object sLock = new Object();
    private static final Object sLoadLock = new Object();
    private static final Handler sMain = new Handler(Looper.getMainLooper());

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

    // Called from any thread; enqueues the work and returns immediately.
    // The input JSON is the complete `jsc()` input (the C++ side composes
    // it: type player/preprocessed + requests). The result is polled
    // through sStatus/sResult.
    public static void solve(final String inputJson)
    {
        synchronized (sLock) {
            if (sBusy) {
                sStatus = "error:solver busy";
                return;
            }
            sBusy = true;
        }
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    final Context ctx = MainActivity.sCtx;
                    if (ctx == null)
                        throw new RuntimeException("no context");
                    sStatus = "working";
                    final String lib = loadAsset(ctx, "solver/lib.min.js");
                    final String core = loadAsset(ctx, "solver/core.min.js");
                    final String scripts = lib + "\nObject.assign(globalThis, lib);\n" + core + "\n";

                    final Runnable evaluateStep = new Runnable() {
                        @Override
                        public void run() {
                            try {
                                final StringBuilder js = new StringBuilder();
                                js.append("(function(){\n");
                                js.append("if (!globalThis.__ltmLibLoaded) {\n");
                                js.append(scripts);
                                js.append("\nglobalThis.__ltmLibLoaded = true;\n");
                                js.append("}\ntry { var IN = JSON.parse(");
                                js.append(JSONObject.quote(inputJson));
                                js.append("); return JSON.stringify(jsc(IN)); }");
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

                    // Prepare the WebView on the UI thread, wait until the
                    // page has loaded, then run the evaluation there.
                    sMain.post(new Runnable() {
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
                                }
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
                                sWeb.loadUrl("about:blank");
                            } catch (Exception ex) {
                                setStatus("error:" + ex.getMessage());
                            }
                        }
                    });
                    synchronized (sLoadLock) {
                        final long deadline = System.currentTimeMillis() + 20000;
                        while (!sLoaded && System.currentTimeMillis() < deadline)
                            sLoadLock.wait(1000);
                        if (!sLoaded)
                            throw new RuntimeException("WebView load timeout");
                    }
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
