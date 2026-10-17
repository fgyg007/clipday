package io.jlmac.clipday.core;

/** Sanitized, offline help template: deliberately accepts no settings, credentials, paths or clipboard data. */
public final class SetupHelp {
    private SetupHelp() { }
    public static String androidNas(int sdk) {
        if (sdk < 1 || sdk > 100) sdk = 0;
        return "请帮我设置轻贴。设备系统：Android（API " + sdk + "）；模式：NAS。手机端目前不支持网盘文件夹模式。状态：需要配置指导，未附真实诊断信息。\n"
                + "先询问我是否有可用 NAS，以及电脑是否已选择 NAS 模式并创建空间；先做只读检查，解释共享目录、读写权限、同一网络和前台同步的要求。不要假定已连接或已送达。\n"
                + "不要索要或让我粘贴密码、令牌、配对密钥、剪贴板内容；本提示未包含用户名、路径、共享名、服务器地址。若确需位置资料，先说明用途并让我单独脱敏提供。\n"
                + "任何安装、账号授权、权限、网络或安全设置改变前都先问我，不关闭防火墙、加密或其他安全保护，不承诺绕过 Android 后台剪贴板限制。请用无敏感内容的小样例指导测试，区分本机保存、NAS 写入和对端接收。";
    }
}
