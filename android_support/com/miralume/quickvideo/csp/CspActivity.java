package com.miralume.quickvideo.csp;

import android.app.Activity;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class CspActivity extends FlutterActivity {
    private static final int PICK_PLUGIN = 8742;
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private CspRuntime runtime;
    private MethodChannel.Result picker;

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine engine) {
        super.configureFlutterEngine(engine);
        runtime = new CspRuntime(getApplicationContext());
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "quickvideo/csp")
                .setMethodCallHandler((call, reply) -> {
                    if (call.method.equals("pick")) {
                        if (picker != null) {
                            reply.error("busy", "已有插件选择窗口打开", null);
                            return;
                        }
                        picker = reply;
                        Intent open = new Intent(Intent.ACTION_OPEN_DOCUMENT)
                                .addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
                        try {
                            startActivityForResult(open, PICK_PLUGIN);
                        } catch (RuntimeException error) {
                            picker = null;
                            reply.error("picker", "无法打开文件选择器", null);
                        }
                        return;
                    }
                    run(reply, () -> runtime.call(call));
                });
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != PICK_PLUGIN || picker == null) return;
        MethodChannel.Result reply = picker;
        picker = null;
        if (result != Activity.RESULT_OK || data == null || data.getData() == null) {
            reply.success(null);
            return;
        }
        run(reply, () -> runtime.importPlugin(data.getData()));
    }

    private void run(MethodChannel.Result reply, Action action) {
        executor.execute(() -> {
            try {
                Object value = action.run();
                main.post(() -> reply.success(value));
            } catch (Exception | LinkageError error) {
                Throwable cause = error.getCause() != null ? error.getCause() : error;
                String message = cause.getMessage();
                main.post(() -> reply.error("csp", cause.getClass().getSimpleName()
                        + (message == null ? "" : "： " + message), null));
            }
        });
    }

    @Override
    protected void onDestroy() {
        executor.shutdown();
        super.onDestroy();
    }

    private interface Action {
        Object run() throws Exception;
    }
}
