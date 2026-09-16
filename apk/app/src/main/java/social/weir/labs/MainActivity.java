package social.weir.labs;

import android.app.Activity;
import android.app.PendingIntent;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.graphics.Insets;
import android.os.Build;
import android.os.Bundle;
import android.view.WindowInsets;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * A remote control for the labs citizen that lives inside Termux on this phone.
 *
 * The citizen itself — the labs binary, Node, its key, its brief and its beat loop — stays where
 * go.sh installed it. This app never holds or reads the key. It asks Termux to run one of five
 * fixed commands and shows what came back.
 */
public class MainActivity extends Activity {

    private static final String TERMUX = "com.termux";
    private static final String RUN_COMMAND_PERMISSION = "com.termux.permission.RUN_COMMAND";
    private static final String BASH = "/data/data/com.termux/files/usr/bin/bash";
    private static final String TERMUX_HOME = "/data/data/com.termux/files/home";

    private static final String SETUP =
            "mkdir -p ~/.termux && echo \"allow-external-apps = true\" >> ~/.termux/termux.properties && termux-reload-settings";

    private static final String PID = "PIDF=\"$HOME/.labs/run/labs-beat-loop.pid\"; ";

    private static final String[][] COMMANDS = {
        {"Status", "labs-status"},
        {"Wake now",
            "cd \"$HOME/.labs\" && setsid nohup labs-beat >> \"$HOME/.labs/labs-beat.log\" 2>&1 < /dev/null & "
                + "echo 'waking started. It takes a few minutes; tap Log to follow it.'"},
        {"Start loop",
            PID + "if [ -f \"$PIDF\" ] && kill -0 \"$(cat \"$PIDF\")\" 2>/dev/null; then "
                + "echo \"already running, pid $(cat \"$PIDF\")\"; "
                + "else cd \"$HOME/.labs\" && LABS_HOME=\"$HOME/.labs\" LABS_OPT=\"$PREFIX/opt/labs\" "
                + "setsid nohup labs-beat-loop < /dev/null > /dev/null 2>&1 & sleep 1; "
                + "echo \"started, pid $(cat \"$PIDF\" 2>/dev/null)\"; fi"},
        {"Stop loop",
            PID + "if [ -f \"$PIDF\" ] && kill -0 \"$(cat \"$PIDF\")\" 2>/dev/null; then "
                + "kill \"$(cat \"$PIDF\")\" && echo stopped; else echo 'not running'; fi"},
        {"Log", "tail -40 \"$HOME/.labs/labs-beat.log\" 2>/dev/null || echo 'no log yet'"},
    };

    private TextView output;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);

        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        column.setPadding(pad, pad, pad, pad);

        for (int i = 0; i < COMMANDS.length; i++) {
            final int index = i;
            column.addView(button(COMMANDS[i][0], v -> run(index)));
        }
        column.addView(button("Open Termux", v -> openTermux()));
        column.addView(button("Copy first-time setup", v -> copySetup()));

        output = new TextView(this);
        output.setTypeface(Typeface.MONOSPACE);
        output.setTextIsSelectable(true);
        output.setPadding(0, pad, 0, 0);
        output.setText("Tap Status.");
        column.addView(output);

        TextView title = new TextView(this);
        title.setText("labs");
        title.setTextSize(28);
        title.setPadding(0, 0, 0, pad);
        column.addView(title, 0);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(column);
        // Android 15 draws every app edge to edge: without this the first buttons sit under the
        // status bar and cannot be tapped.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            scroll.setOnApplyWindowInsetsListener((view, insets) -> {
                Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
                return insets;
            });
        }
        setContentView(scroll);

        if (checkSelfPermission(RUN_COMMAND_PERMISSION) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {RUN_COMMAND_PERMISSION}, 1);
        }
        onNewIntent(getIntent());
    }

    private void run(int index) {
        if (!termuxInstalled()) {
            output.setText("Termux is not installed. Install it from F-Droid, then run go.sh in it.");
            return;
        }
        if (checkSelfPermission(RUN_COMMAND_PERMISSION) != PackageManager.PERMISSION_GRANTED) {
            output.setText("This app needs permission to run commands in Termux. Grant it, then tap again.");
            requestPermissions(new String[] {RUN_COMMAND_PERMISSION}, 1);
            return;
        }

        // Termux fills this PendingIntent with the command's stdout, stderr and exit code and sends it
        // back here. It must be mutable for Termux to add those extras; it names this activity
        // explicitly, so nothing else can receive it.
        Intent back = new Intent(this, MainActivity.class).putExtra("label", COMMANDS[index][0]);
        PendingIntent reply = PendingIntent.getActivity(
                this, index, back, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);

        Intent command = new Intent("com.termux.RUN_COMMAND");
        command.setClassName(TERMUX, "com.termux.app.RunCommandService");
        command.putExtra("com.termux.RUN_COMMAND_PATH", BASH);
        command.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", new String[] {"-c", COMMANDS[index][1]});
        command.putExtra("com.termux.RUN_COMMAND_WORKDIR", TERMUX_HOME);
        command.putExtra("com.termux.RUN_COMMAND_BACKGROUND", true);
        command.putExtra("com.termux.RUN_COMMAND_COMMAND_LABEL", "labs: " + COMMANDS[index][0]);
        command.putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", reply);

        output.setText(COMMANDS[index][0] + "…");
        try {
            startService(command);
        } catch (RuntimeException e) {
            output.setText("Termux did not accept the command: " + e.getMessage());
        }
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (intent == null) return;
        Bundle result = intent.getBundleExtra("result");
        if (result == null) return;

        StringBuilder text = new StringBuilder();
        text.append(intent.getStringExtra("label")).append("\n\n");

        // err is Termux's own verdict on the request; a non-zero value means the command never ran,
        // most often because allow-external-apps is not set.
        int err = result.getInt("err", 0);
        String errmsg = result.getString("errmsg", "");
        if (err != -1 && err != 0 && !errmsg.isEmpty()) {
            text.append("Termux refused: ").append(errmsg).append("\n\n")
                .append("If this is the first run, tap \"Copy first-time setup\", paste it into Termux, then try again.");
            output.setText(text);
            return;
        }

        String stdout = result.getString("stdout", "");
        String stderr = result.getString("stderr", "");
        if (!stdout.isEmpty()) text.append(stdout);
        if (!stderr.isEmpty()) text.append("\n").append(stderr);
        if (stdout.isEmpty() && stderr.isEmpty()) {
            text.append("finished, exit ").append(result.getInt("exitCode", -1));
        }
        output.setText(text);
    }

    private void openTermux() {
        Intent launch = getPackageManager().getLaunchIntentForPackage(TERMUX);
        if (launch == null) {
            output.setText("Termux is not installed.");
            return;
        }
        startActivity(launch);
    }

    private void copySetup() {
        ClipboardManager clipboard = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
        clipboard.setPrimaryClip(ClipData.newPlainText("labs setup", SETUP));
        output.setText("Copied. Open Termux, long-press, Paste, Enter. Then come back and tap Status.\n\n" + SETUP);
    }

    private boolean termuxInstalled() {
        try {
            getPackageManager().getPackageInfo(TERMUX, 0);
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    private Button button(String label, android.view.View.OnClickListener onClick) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setOnClickListener(onClick);
        b.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return b;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
