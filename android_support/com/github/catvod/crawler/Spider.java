package com.github.catvod.crawler;

import android.content.Context;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Base class for the common CatVod spider ABI. */
public abstract class Spider {
    public void init(Context context) throws Exception {}

    public void init(Context context, String extend) throws Exception {
        init(context);
    }

    public String homeContent(boolean filter) throws Exception { return ""; }
    public String homeVideoContent() throws Exception { return ""; }
    public String categoryContent(String category, String page, boolean filter,
                                  HashMap<String, String> extend) throws Exception { return ""; }
    public String detailContent(List<String> ids) throws Exception { return ""; }
    public String searchContent(String query, boolean quick) throws Exception { return ""; }
    public String searchContent(String query, boolean quick, String page) throws Exception {
        return searchContent(query, quick);
    }
    public String playerContent(String flag, String id, List<String> vipFlags) throws Exception { return ""; }
    public boolean manualVideoCheck() throws Exception { return false; }
    public boolean isVideoFormat(String url) throws Exception { return false; }
    public Object[] proxyLocal(Map<String, String> params) throws Exception { return null; }
    public void cancelByTag() {}
    public void destroy() {}
}
