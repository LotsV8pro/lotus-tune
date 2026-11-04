/**
 * Descarga de audio para el panel de descargas (listas y pistas sueltas).
 *
 * Es el mismo stack HTTP que MediaFetch (HttpsURLConnection: el de
 * OkHttp/Media3/Chrome, el unico que los nodos de medios del operador no
 * rechazan con 403), pero con su PROPIO estado: la reproduccion usa
 * MediaFetch y si compartiesen estado una descarga en segundo plano
 * cancelaria la pista que esta sonando (y al reves).
 *
 * El C++ arranca la descarga y sondea status()/bytes()/total(): nunca
 * bloquea el hilo de la UI.
 *
 * Estados: "idle" | "working" | "done" | "error:<motivo>"
 */
package com.lotustuneremote.app;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;

import android.util.Log;

public class MediaDownload
{
    public static volatile String sStatus = "idle";
    public static volatile String sId = "";
    public static volatile long sBytes = 0;
    public static volatile long sTotal = 0;

    private static volatile boolean sCancel = false;

    // El UA de un navegador Android: los proxies del operador rechazan
    // perfiles "raros" (TV, vacios) con 403 sobre el mismo nodo.
    private static final String UA =
        "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36"
        + " (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36";

    public static void start(final String id, final String url, final String path)
    {
        sCancel = true;             // cancela la anterior (si hubiera)
        sId = id;
        sBytes = 0;
        sTotal = 0;
        sStatus = "working";
        sCancel = false;
        Log.i("LotusTune", "[download] start " + id);
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() { fetch(id, url, path); }
        }, "lt-media-download");
        t.setDaemon(true);
        t.start();
    }

    public static void cancel()
    {
        sCancel = true;
    }

    public static String status()
    {
        return sStatus;
    }

    public static String id()
    {
        return sId;
    }

    public static long bytes()
    {
        return sBytes;
    }

    public static long total()
    {
        return sTotal;
    }

    private static void setStatus(String id, String status)
    {
        if (id.equals(sId))
            sStatus = status;
    }

    private static void fetch(String id, String url, String path)
    {
        File part = new File(path + ".part");
        File dst = new File(path);
        try {
            HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
            c.setInstanceFollowRedirects(true);
            c.setUseCaches(false);
            c.setConnectTimeout(8000);
            c.setReadTimeout(15000);
            c.setRequestProperty("User-Agent", UA);
            c.setRequestProperty("Accept", "*/*");
            c.setRequestProperty("Accept-Encoding", "identity");
            c.setRequestProperty("Accept-Language", "es-ES,es;q=0.9,en;q=0.8");
            c.setRequestProperty("Range", "bytes=0-");
            Log.i("LotusTune", "[download] conectando " + new URL(url).getHost());
            int code = c.getResponseCode();
            Log.i("LotusTune", "[download] http " + code);
            if (code != 200 && code != 206) {
                setStatus(id, "error:http" + code);
                return;
            }
            long total = c.getContentLengthLong();
            if (id.equals(sId))
                sTotal = total;
            Log.i("LotusTune", "[download] total " + total);
            FileOutputStream out = new FileOutputStream(part, false);
            try {
                InputStream in = c.getInputStream();
                byte[] buf = new byte[64 * 1024];
                int n;
                long got = 0;
                while ((n = in.read(buf)) > 0) {
                    if (sCancel || !id.equals(sId))
                        throw new java.io.IOException("cancelado");
                    out.write(buf, 0, n);
                    got += n;
                    if (id.equals(sId))
                        sBytes = got;
                }
                out.flush();
                out.getFD().sync();
                if (total > 0 && got != total)
                    throw new java.io.IOException("incompleto " + got + "/" + total);
            } finally {
                out.close();
            }
            if (dst.exists() && !dst.delete())
                throw new java.io.IOException("no se pudo reemplazar " + dst);
            if (!part.renameTo(dst))
                throw new java.io.IOException("no se pudo renombrar " + part);
            Log.i("LotusTune", "[download] done " + dst.getName() + " " + dst.length());
            setStatus(id, "done");
        } catch (Throwable t) {
            Log.w("LotusTune", "[download] fallo " + t.getClass().getSimpleName()
                  + ": " + t.getMessage());
            try { part.delete(); } catch (Throwable ignored) { }
            setStatus(id, "error:" + t.getClass().getSimpleName() + ":"
                      + String.valueOf(t.getMessage()));
        }
    }
}
