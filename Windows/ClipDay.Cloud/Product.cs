using ClipDay.Sync;
namespace ClipDay.Cloud;
static class Product
{
    public const string Title = "轻贴";
    public const string StorageName = "ClipDay.Cloud";
    public static SyncMode Mode { get; } = ModePreferences.Read();
    public static bool IsDrive => Mode == SyncMode.CloudFolder;
    public static bool IsLocal => Mode == SyncMode.LocalOnly;
    public static string Disconnected => IsLocal ? "仅本机历史 · 未连接同步" : IsDrive ? "尚未连接 网盘 文件夹" : "尚未连接 NAS";
    public static string FolderPlaceholder => IsDrive ? "选择本机已登录 网盘 内的现有文件夹" : @"例如 \\NAS\共享\轻贴 或 Z:\轻贴";
    public static string DeliveryHint => IsDrive ? "只确认写入本机 网盘 文件夹；云端上传、另一台接收均未知。" : "记录保存在本机；NAS 上传与对端接收是不同状态。";
    public static string FolderName => IsDrive ? "本机 网盘 文件夹路径" : "NAS 文件夹路径";
    public static string Badge => IsLocal ? "仅本机历史" : IsDrive ? "网盘 电脑间文字与图片同步" : "NAS 文字与图片同步";
    public static string Onboarding => IsDrive ? "第 1 步：先自行登录 网盘，两台电脑选择同一云端文件夹的本机路径。\n第 2 步：确认已启用双向同步，且文件始终完整保留在本机（不是虚拟盘或仅备份）。\n第 3 步：首台创建空间，另一台输入完整配对密钥；请勿将密钥存入同步文件夹。" : "第 1 步：两台电脑填写各自访问同一共享文件夹的路径。\n第 2 步：仅首台创建空间；另一台输入首台显示的 6 位配对码。";
    public static string JoinLabel => IsDrive ? "另一台：输入配对密钥" : "另一台：输入配对码";
    public static string ClearWarning => IsDrive ? "清空本机历史？其他设备、网盘 同步文件与系统当前剪贴板保持不变。" : "清空本机历史？其他设备、NAS 同步文件与系统当前剪贴板保持不变。";
    public static string BrowseHint => IsDrive ? "选择本机已登录 网盘 内的现有文件夹（先设为始终保留在此设备上）" : "选择两台电脑都可访问的同一个 NAS 文件夹";
    public static string MissingFolder => IsDrive ? "请先选择本机已存在的 网盘 文件夹。" : "请先填写 NAS 文件夹路径，或点击浏览选择。";
    public static string InvalidFolder => IsDrive ? "请填写本机完整文件夹路径，不是网盘网址。" : @"请填写完整共享路径，例如 \\NAS\共享\轻贴，或映射盘路径 Z:\轻贴。";
    public static string Checking => IsDrive ? "正在检测本机文件夹读写权限；不会验证 网盘 登录或云端上传…" : "正在检测本机 NAS 路径的可访问性与读写权限…";
    public static string CheckFailed => IsDrive ? "本机路径检测未完成，请检查文件夹和本机权限。" : "路径检测未完成，请检查 NAS 连接后重试。";
    public static string Connecting => IsDrive ? "正在连接本机 网盘 文件夹…" : "正在连接 NAS…";
    public static string Connected => IsDrive ? "本机连接已保存 · 网盘 云端上传与对端接收未知" : "本机连接已保存 · 正在检查 NAS；对端接收未确认";
    public static string ConnectFailed => IsDrive ? "连接失败：请检查本机文件夹、完整配对密钥，并等待首台空间同步到本机后重试。" : "连接失败，请检查 NAS 路径、读写权限和配对码。";
    public static string Queued => IsDrive ? "本机已保存 · 已排队 · 尚未写入 网盘 本机文件夹" : "本机已保存 · 已加入待发送队列 · 尚未确认 NAS 上传";
    public static string PollSuccess => IsDrive ? "本机文件夹可用 · 自动同步已开启 · 云端上传与对端接收未知" : "NAS 已连接 · 文字与图片自动同步 · 对端接收状态未知";
    public static string Unavailable => IsDrive ? "本机同步文件夹暂不可用；历史与待发送队列保留，稍后重试。" : "NAS 暂不可用；本机历史与待发送队列保留，稍后重试。";
    public static string Rejected(int value) => IsDrive ? $"本机文件夹可用；{value} 个不完整或无效记录等待重试" : $"NAS 已连接；{value} 个不完整或无效记录等待重试";
    public static string Written(int value) => IsDrive ? $"已写入本机 网盘 文件夹：{value} 条 · 云端上传、对端接收未知" : $"已上传 NAS：{value} 条 · 不代表另一台设备已接收或粘贴";
    public static string Diagnostic(FolderDiagnostic result) => IsDrive ? (result.Success ? "本机路径可读写；不代表 网盘 已登录、上传成功或对端可见。" : "本机路径不可读写；检查路径、磁盘空间、权限和文件是否已保留在本机。") : result.Message;
}
