package io.jlmac.clipday.core;

import org.json.JSONObject;

public final class NasConfig {
    public final String host, share, folder, username, password, domain;
    public final int port;
    public NasConfig(JSONObject json) throws Exception {
        host = json.getString("host").trim(); share = json.getString("share").trim();
        folder = json.optString("folder").trim().replace('\\', '/').replaceAll("^/+|/+$", "");
        username = json.optString("username").trim(); password = json.optString("password"); domain = json.optString("domain").trim();
        port = json.optInt("port", 445);
        if (host.isEmpty() || host.contains("/") || host.contains("\\") || host.contains(" ") || port < 1 || port > 65535)
            throw new Wire.UserError("NAS 地址请填写 IP 或可直连 SMB 的域名，例如 192.168.1.10；不要填写 https:// 网页链接。");
        if (host.toLowerCase(java.util.Locale.ROOT).contains("quickconnect."))
            throw new Wire.UserError("QuickConnect 地址不支持 SMB。请使用 NAS 局域网 IP，外网需先连接 VPN。");
        if (share.isEmpty() || share.contains("/") || share.contains("\\") || share.equals(".") || share.equals(".."))
            throw new Wire.UserError("请填写共享名称，例如 share；不要填写 Windows 的 Z: 盘符。");
        safePath(folder);
    }
    static void safePath(String path) throws Exception {
        for (String p : path.split("/")) if (p.equals(".") || p.equals("..") || p.contains(":") || p.contains("\u0000") || p.contains("\\"))
            throw new Wire.UserError("文件夹路径格式不正确，请填写共享内的子文件夹。");
    }
}
