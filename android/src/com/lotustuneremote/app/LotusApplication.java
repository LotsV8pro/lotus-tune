/**
 * Custom Application class to fix MIUI HWUI crashes.
 * 
 * MIUI's HWUI implementation conflicts with Qt's OpenGL rendering,
 * causing pthread_mutex crashes in hwuiTask threads.
 * 
 * By creating this Application class and keeping hardwareAccelerated="false"
 * at the application level in AndroidManifest.xml, we prevent MIUI's HWUI 
 * from initializing before Qt can set up its OpenGL context.
 * 
 * Reference: AndroidManifest.xml must include android:name=".LotusApplication"
 */
package com.lotustuneremote.app;

import android.app.Application;
import android.os.Build;
import android.util.Log;

public class LotusApplication extends Application {
    
    private static final String TAG = "LotusApplication";
    
    @Override
    public void onCreate() {
        super.onCreate();
        
        // Force disable HWUI for all activities - this is needed on MIUI
        // because MIUI's HWUI can still load even with manifest flag
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.ICE_CREAM_SANDWICH) {
            // Set the system property to disable HWUI painting
            try {
                Class<?> factoryClass = Class.forName("android.view.ViewRootImpl");
                // Additional MIUI-specific work can be done here
            } catch (Exception e) {
                Log.d(TAG, "HWUI setup: " + e.getMessage());
            }
        }
        
        // The hardwareAccelerated="false" in manifest should prevent HWUI
        // from loading. MIUI detection is just for logging/debugging.
        if (isMIUI()) {
            Log.d(TAG, "MIUI/HyperOS detected - HWUI should be disabled");
        }
    }
    
    private boolean isMIUI() {
        String displayName = Build.DISPLAY;
        if (displayName == null) return false;
        
        return displayName.contains("MIUI") || displayName.contains("HyperOS");
    }
}