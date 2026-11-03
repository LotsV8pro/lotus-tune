package com.lotustuneremote.app;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;

public class LibraryTestActivity extends Activity {
    private static final String TAG = "LibraryTest";
    
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        
        try {
            // Try to load the library directly (not through System.loadLibrary)
            System.load("/data/data/com.lotustuneremote.app/lib/liblotus-tune.so");
            Log.d(TAG, "Library loaded successfully");
        } catch (Exception e) {
            Log.e(TAG, "Failed to load library: " + e.getMessage());
        }
        
        finish();
    }
}
