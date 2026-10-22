package io.github.lotsv8pro.lotustune;

import android.os.Bundle;
import android.view.View;

import org.qtproject.qt.android.bindings.QtActivity;

// The activity that hosts the QML scene. The QML is the same one the
// desktop build uses (qml/Main.qml) so the two flavours cannot drift
// apart.
public class MainActivity extends QtActivity
{
    @Override
    protected void onCreate(Bundle savedInstanceState)
    {
        super.onCreate(savedInstanceState);

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
}
