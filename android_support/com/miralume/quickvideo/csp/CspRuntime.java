package com.miralume.quickvideo.csp;

import android.content.Context;
import android.net.Uri;

import com.github.catvod.crawler.Spider;

import dalvik.system.DexClassLoader;
import io.flutter.plugin.common.MethodCall;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Method;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.zip.ZipFile;

final class CspRuntime {
    private static final long MAX_SIZE = 20L * 1024 * 1024;
    private final Context context;
    private final Map<String, DexClassLoader> loaders = new HashMap<>();
    private final Map<String, Spider> spiders = new HashMap<>();

    CspRuntime(Context context) {
        this.context = context;
    }

    Map<String, String> importPlugin(Uri uri) throws Exception {
        File dir = directory();
        File pending = File.createTempFile("csp-", ".jar", dir);
        try {
            MessageDigest sha = MessageDigest.getInstance("SHA-256");
            MessageDigest md5 = MessageDigest.getInstance("MD5");
            byte[] bytes = new byte[32 * 1024];
            long size = 0;
            try (InputStream in = context.getContentResolver().openInputStream(uri);
                 FileOutputStream out = new FileOutputStream(pending)) {
                if (in == null || !pending.setReadOnly()) {
                    throw new IOException("无法安全读取插件文件");
                }
                int count;
                while ((count = in.read(bytes)) != -1) {
                    size += count;
                    if (size > MAX_SIZE) throw new IOException("插件文件超过 20 MB");
                    sha.update(bytes, 0, count);
                    md5.update(bytes, 0, count);
                    out.write(bytes, 0, count);
                }
            }
            try (ZipFile jar = new ZipFile(pending)) {
                if (jar.getEntry("classes.dex") == null) {
                    throw new IOException("文件未包含 Android classes.dex");
                }
            }
            String digest = hex(sha.digest());
            File finalFile = new File(dir, digest + ".jar");
            if (!finalFile.exists() && !pending.renameTo(finalFile)) {
                throw new IOException("保存插件文件失败");
            }
            Map<String, String> info = new HashMap<>();
            info.put("sha256", digest);
            info.put("md5", hex(md5.digest()));
            return info;
        } finally {
            pending.delete();
        }
    }

    Object call(MethodCall call) throws Exception {
        String hash = call.argument("sha256");
        if (hash == null || !hash.matches("[0-9a-f]{64}")) {
            throw new IOException("请先导入并信任本地 CSP 插件");
        }
        File plugin = new File(directory(), hash + ".jar");
        if (!plugin.isFile()) throw new IOException("本地插件文件已不存在，请重新导入");
        if ("check".equals(call.method)) {
            checkDigest(plugin, hash);
            return true;
        }
        String name = call.argument("api");
        if (name == null || !name.matches("csp_[A-Za-z_$][A-Za-z0-9_$]{0,127}")) {
            throw new IllegalArgumentException("CSP 类名格式无效");
        }
        String ext = call.argument("ext");
        Spider spider = spider(plugin, hash, name.substring(4), ext == null ? "" : ext);
        String value;
        switch (call.method) {
            case "search":
                value = spider.searchContent(call.argument("query"), false);
                if (value == null || value.isEmpty()) {
                    value = spider.searchContent(call.argument("query"), false, "1");
                }
                break;
            case "detail":
                value = spider.detailContent(Collections.singletonList(call.argument("id")));
                break;
            case "play":
                ArrayList<String> flags = call.argument("flags");
                value = spider.playerContent(call.argument("flag"), call.argument("id"),
                        flags != null ? flags : new ArrayList<>());
                break;
            default:
                throw new IllegalArgumentException("未知 CSP 操作");
        }
        if (value == null || value.trim().isEmpty()) throw new IOException("CSP 插件返回了空内容");
        if (value.length() > 3 * 1024 * 1024) throw new IOException("CSP 插件响应超过限制");
        return value;
    }

    private Spider spider(File plugin, String hash, String name, String ext) throws Exception {
        DexClassLoader loader = loaders.get(hash);
        if (loader == null) {
            checkDigest(plugin, hash);
            loader = new DexClassLoader(plugin.getPath(), context.getCodeCacheDir().getPath(),
                    null, context.getClassLoader());
            try {
                Class<?> init = loader.loadClass("com.github.catvod.spider.Init");
                Method method = init.getMethod("init", Context.class);
                method.invoke(null, context);
            } catch (ClassNotFoundException ignored) {
                // Some plugins initialize through Spider.init only.
            }
            loaders.put(hash, loader);
        }
        String key = hash + "\n" + name + "\n" + ext;
        Spider spider = spiders.get(key);
        if (spider == null) {
            spider = loader.loadClass("com.github.catvod.spider." + name)
                    .asSubclass(Spider.class).getDeclaredConstructor().newInstance();
            spider.init(context, ext);
            spiders.put(key, spider);
        }
        return spider;
    }

    private File directory() throws IOException {
        File dir = new File(context.getFilesDir(), "csp");
        if (!dir.isDirectory() && !dir.mkdirs()) throw new IOException("无法创建插件目录");
        return dir;
    }

    private static void checkDigest(File plugin, String expected) throws Exception {
        MessageDigest sha = MessageDigest.getInstance("SHA-256");
        byte[] bytes = new byte[32 * 1024];
        try (InputStream in = new FileInputStream(plugin)) {
            int count;
            while ((count = in.read(bytes)) != -1) sha.update(bytes, 0, count);
        }
        if (!hex(sha.digest()).equals(expected) || plugin.canWrite()) {
            throw new IOException("插件文件已改变或仍可写，请重新导入");
        }
    }

    private static String hex(byte[] bytes) {
        char[] digits = "0123456789abcdef".toCharArray();
        char[] result = new char[bytes.length * 2];
        for (int i = 0; i < bytes.length; i++) {
            result[i * 2] = digits[(bytes[i] & 255) >>> 4];
            result[i * 2 + 1] = digits[bytes[i] & 15];
        }
        return new String(result);
    }
}
