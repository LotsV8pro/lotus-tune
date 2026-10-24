package io.github.lotsv8pro.lotustune;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.os.Bundle;
import android.webkit.CookieManager;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.File;
import java.io.FileWriter;

// In-app Google sign-in (the phone cannot run the desktop WebKitGTK
// helper): a native WebView opens the Google login tab, and when the
// browser lands on YouTube Music the session cookies are written to the
// same Netscape cookies.txt the desktop flow uses. The Qt side keeps
// checking that file until a SAPISID appears and marks the session ok.
public class LotusLoginActivity extends Activity
{
    private WebView web;
    private String targetPath;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState)
    {
        super.onCreate(savedInstanceState);
        targetPath = getIntent().getStringExtra("target");
        String url = getIntent().getStringExtra("url");

        setTitle("Sesión de YouTube Music");
        web = new WebView(this);
        setContentView(web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setSupportMultipleWindows(true);
        s.setJavaScriptCanOpenWindowsAutomatically(true);
        // Google blocks the sign-in in WebViews it detects ("this browser
        // or app is not secure"): pose as desktop Chrome, which does go
        // through. The old WebKitGTK helper used a Safari identity.
        s.setUserAgentString(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/120.0.0.0 Safari/537.36");
        CookieManager cm = CookieManager.getInstance();
        cm.setAcceptCookie(true);
        cm.setAcceptThirdPartyCookies(web, true);

        web.setWebViewClient(new WebViewClient()
        {
            @Override
            public void onPageFinished(WebView view, String url)
            {
                // The session exists the moment the YouTube web shows
                // up signed in (SAPISID cookie, the same check the C++
                // side does with the file).
                String pairs = CookieManager.getInstance()
                        .getCookie("https://music.youtube.com/");
                if (pairs != null && pairs.contains("SAPISID=")) {
                    boolean ok = false;
                    try {
                        writeCookies(pairs);
                        ok = true;
                    } catch (Exception ignored) {
                    }
                    setResult(ok ? RESULT_OK : RESULT_CANCELED);
                    finish();
                }
            }
        });

        if (url != null && !url.isEmpty())
            web.loadUrl(url);
        else
            web.loadUrl("https://accounts.google.com/ServiceLogin"
                        + "?service=youtube&continue="
                        + "https://music.youtube.com/");
    }

    // Netscape cookies.txt like the desktop helper and importSession
    // produce: only the flag shape matters, values are the real ones.
    private void writeCookies(String pairs) throws Exception
    {
        File out = new File(targetPath);
        File dir = out.getParentFile();
        if (dir != null)
            dir.mkdirs();
        StringBuilder sb = new StringBuilder();
        sb.append("# Netscape HTTP Cookie File\n");
        sb.append("# Saved by LotusTune (Android login)\n\n");
        for (String pair : pairs.split("; ")) {
            int eq = pair.indexOf('=');
            if (eq <= 0)
                continue;
            String name = pair.substring(0, eq).trim();
            String value = pair.substring(eq + 1).trim();
            if (name.isEmpty())
                continue;
            sb.append(".youtube.com\tTRUE\t/\tTRUE\t2147483647\t")
              .append(name).append('\t').append(value).append('\n');
        }
        FileWriter fw = new FileWriter(out, false);
        fw.write(sb.toString());
        fw.close();
    }

    @Override
    public void onBackPressed()
    {
        if (web != null && web.canGoBack())
            web.goBack();
        else {
            setResult(RESULT_CANCELED);
            finish();
        }
    }
}
