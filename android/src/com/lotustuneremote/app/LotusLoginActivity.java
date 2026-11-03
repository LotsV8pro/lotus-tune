package com.lotustuneremote.app;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.os.Bundle;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.File;
import java.io.FileWriter;
import java.util.LinkedHashMap;
import java.util.Map;

// In-app Google sign-in (the phone cannot run the desktop WebKitGTK
// helper): a native WebView opens the Google login tab, and when the
// browser lands on YouTube Music the session cookies are written to the
// same Netscape cookies.txt the desktop flow uses. The Qt side keeps
// checking that file until a SAPISID appears and marks the session ok.
//
// Google refuses the sign-in ("Es posible que el navegador o la app no
// sea seguro") when it recognises the embedded browser. Two things give
// a WebView away: the "; wv" token that Android puts in the default user
// agent, and a *desktop* Chrome UA in a window that is clearly a phone.
// The identity below is a plain mobile Chrome (no "wv", no "Version/4.0"),
// which is what the open-source YouTube Music clients use to get through.
public class LotusLoginActivity extends Activity
{
    // Mobile Chrome, exactly as a phone browser reports itself. No "wv".
    private static final String CHROME_MOBILE_UA =
        "Mozilla/5.0 (Linux; Android 13; Pixel 7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/124.0.0.0 Mobile Safari/537.36";

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
        setContentView(web, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        // Google's flow opens helper windows in some steps; keeping a
        // single window means those links load here instead of vanishing
        // (a popup without a WebChromeClient is silently dropped).
        s.setSupportMultipleWindows(false);
        s.setJavaScriptCanOpenWindowsAutomatically(true);
        s.setUserAgentString(CHROME_MOBILE_UA);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setDatabaseEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);

        CookieManager cm = CookieManager.getInstance();
        cm.setAcceptCookie(true);
        cm.setAcceptThirdPartyCookies(web, true);

        web.setWebChromeClient(new WebChromeClient());

        web.setWebViewClient(new WebViewClient()
        {
            @Override
            public void onPageFinished(WebView view, String url)
            {
                // The session exists the moment the YouTube web shows
                // up signed in (SAPISID cookie, the same check the C++
                // side does with the file).
                String pairs = collectCookies();
                if (pairs.contains("SAPISID=")) {
                    if (writeCookies(pairs)) {
                        setResult(RESULT_OK);
                        finish();
                    }
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

    // Cookies of the two hosts the session needs. Domain cookies repeat
    // in both lists, hence the map.
    private String collectCookies()
    {
        Map<String, String> all = new LinkedHashMap<>();
        CookieManager cm = CookieManager.getInstance();
        for (String host : new String[] {
                "https://music.youtube.com/",
                "https://www.youtube.com/",
                "https://accounts.google.com/" }) {
            String pairs = cm.getCookie(host);
            if (pairs == null)
                continue;
            for (String pair : pairs.split(";")) {
                int eq = pair.indexOf('=');
                if (eq <= 0)
                    continue;
                String name = pair.substring(0, eq).trim();
                String value = pair.substring(eq + 1).trim();
                if (!name.isEmpty() && !all.containsKey(name))
                    all.put(name, value);
            }
        }
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, String> e : all.entrySet()) {
            if (sb.length() > 0)
                sb.append("; ");
            sb.append(e.getKey()).append('=').append(e.getValue());
        }
        return sb.toString();
    }

    // Netscape cookies.txt like the desktop helper and importSession
    // produce: only the flag shape matters, values are the real ones.
    private boolean writeCookies(String pairs)
    {
        try {
            File out = new File(targetPath);
            File dir = out.getParentFile();
            if (dir != null && !dir.exists())
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
            CookieManager.getInstance().flush();
            return true;
        } catch (Exception e) {
            return false;
        }
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
