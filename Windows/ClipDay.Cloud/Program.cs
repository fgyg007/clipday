using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ClipDay.Sync;
using SyncRecord = ClipDay.Sync.Record;

namespace ClipDay.Cloud;

record Config(string Folder, string ProtectedPair, bool Enabled, [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingDefault)] bool AwaitingSpace = false);
record HistoryItem(string Id, string Text, string Source, long Created, long Expires, ImageRecord? Image = null)
{
    public bool IsImage => Image != null;
    public string Summary => Image is { } image ? $"图片 · {image.Width} × {image.Height} · {image.ByteCount / 1024.0:F0} KB" : Text;
    public override string ToString() => $"{DateTimeOffset.FromUnixTimeMilliseconds(Created).ToLocalTime():HH:mm} · {Source} · {Text.Replace("\r", " ").Replace("\n", " ")[..Math.Min(Text.Replace("\r", " ").Replace("\n", " ").Length, 100)]}";
}
static class Storage
{
    public static readonly string Root = Product.IsDrive ? Path.Combine(ModePreferences.BaseRoot, "cloud-folder") : Product.IsLocal ? Path.Combine(ModePreferences.BaseRoot, "local-only") : ModePreferences.BaseRoot;
    public static string Protect(byte[] data) => Convert.ToBase64String(ProtectedData.Protect(data, null, DataProtectionScope.CurrentUser));
    public static byte[] Unprotect(string data) => ProtectedData.Unprotect(Convert.FromBase64String(data), null, DataProtectionScope.CurrentUser);
    public static void SavePrivacy(bool paused) => PrivacyPreferences.Save(Root, paused);
    public static void SaveConfig(Config config) => Wire.Atomic(Path.Combine(Root, "config.json"), JsonSerializer.SerializeToUtf8Bytes(config));
    public static void SaveHistory(List<HistoryItem> items) => Wire.Atomic(Path.Combine(Root, "history.protected"), Encoding.UTF8.GetBytes(Protect(JsonSerializer.SerializeToUtf8Bytes(items.Where(x => !x.IsImage).ToList()))));
    public static ImageVault OpenImageVault()
    {
        var path = Path.Combine(Root, "image-key.protected"); ImageWire.SafePath(path);
        byte[] key;
        if (File.Exists(path)) key = Unprotect(File.ReadAllText(path));
        else
        {
            var images = Path.Combine(Root, "images");
            if (Directory.Exists(images) && Directory.EnumerateFiles(images).Any()) throw new InvalidDataException("本机图片密钥缺失。");
            key = RandomNumberGenerator.GetBytes(32); ImageWire.Atomic(path, Encoding.UTF8.GetBytes(Protect(key)));
        }
        return new ImageVault(Path.Combine(Root, "images"), key, ClipboardImages.Validate);
    }
}
static class Program
{
    [STAThread]
    static void Main()
    {
        using var mutex = new Mutex(true, "Local\\" + Product.StorageName + "." + Environment.UserName, out bool first);
        if (!first) { MessageBox.Show(Product.Title + "已经在系统托盘运行。", Product.Title); return; }
        ApplicationConfiguration.Initialize();
        Directory.CreateDirectory(Storage.Root);
        Application.Run(new MainForm());
    }
}
sealed class MainForm : Form
{
    [DllImport("user32.dll")] static extern bool AddClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    const int WM_CLIPBOARDUPDATE = 0x031D;
    readonly Label status = new() { Text = Product.Disconnected, AutoSize = true, Dock = DockStyle.Fill, ForeColor = Ui.Teal, BackColor = Ui.Soft, Padding = new Padding(10, 8, 10, 8), Margin = new Padding(0, 4, 0, 8) };
    readonly TextBox folderInput = new() { PlaceholderText = Product.FolderPlaceholder, Dock = DockStyle.Fill };
    readonly PairCodePanel pairPanel = new() { Dock = DockStyle.Fill, Height = 110, Visible = false };
    CancellationTokenSource? pairingCancel;
    Task? pairingTask;
    readonly PairingViewState pairingView = new();
    readonly Button connectionToggle = Ui.Button("连接设置");
    readonly List<Control> connectionDetails = [];
    bool connectionExpanded = true;
    readonly Label folderLabel = new() { AutoSize = true, Dock = DockStyle.Fill, ForeColor = Ui.Muted, Visible = false, Margin = new Padding(0, 2, 0, 6) };
    readonly Button pause = Ui.Button("暂停同步");
    readonly Button privacy = Ui.Button("隐私暂停");
    readonly ToolStripMenuItem privacyTray = new("隐私暂停");
    readonly Label delivery = Ui.Label(Product.DeliveryHint);
    readonly Button pairButton = Ui.Button("配对另一台电脑");
    readonly TextBox search = new() { PlaceholderText = "搜索文字 / 图片历史…", Dock = DockStyle.Fill };
    readonly HistoryList list = new();
    readonly Label historyCount = Ui.Label("24 小时内 · 0 条");
    readonly Label emptyHistory = new() { Text = "还没有记录\n复制文字或图片，它会自动出现在这里。", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, ForeColor = Ui.Muted };
    readonly NotifyIcon tray;
    readonly System.Windows.Forms.Timer timer = new() { Interval = 500 };
    readonly SemaphoreSlim gate = new(1, 1);
    readonly List<HistoryItem> history = [];
    ComboBox? provider;
    bool modeSwitching;
    Config? config;
    long nextJoinAttempt;
    int joinBackoffSeconds = 5;
    FolderSync? engine;
    FolderImageSync? imageEngine;
    ImageVault? imageVault;
    readonly string localImageIdentity = Guid.NewGuid().ToString();
    Pair? pair;
    bool closing, busy = true, polling, captureBusy, writingClipboard, privacyTransition, stateLoaded;
    readonly ClipboardCaptureState capture = new();
    CancellationTokenSource privacyCancel = new();
    CancellationTokenSource transferCancel = new();
    long epoch, holdUntil, lastPoll, clipboardActivityCreated;
    Guid session = Guid.NewGuid();
    public MainForm()
    {
        SuspendLayout(); AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi;
        Text = Product.Title; ClientSize = new Size(860, 880); MinimumSize = new Size(740, 740);
        Font = new Font("Microsoft YaHei UI", 9.5f); ForeColor = Ui.Ink; BackColor = Ui.Canvas;
        Icon = Ui.AppIcon; StartPosition = FormStartPosition.CenterScreen;
        folderInput.AccessibleName = Product.FolderName; search.AccessibleName = "搜索文字 / 图片历史";
        pause.Enabled = pairButton.Enabled = false;
        var layout = Ui.Stack(4); layout.AutoSize = false; layout.Padding = new Padding(20);
        layout.RowStyles[2] = new RowStyle(SizeType.Percent, 100);
        var header = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 3, Margin = new Padding(0, 0, 0, 20) };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var logo = new PictureBox { Image = Ui.AppIcon.ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Size = new Size(48, 48), Margin = new Padding(0, 4, 14, 0), TabStop = false };
        var heading = Ui.Stack(2);
        heading.Controls.Add(new Label { Text = Product.Title, Font = new Font(Font.FontFamily, 22, FontStyle.Bold), AutoSize = true, Margin = Padding.Empty }, 0, 0);
        heading.Controls.Add(Ui.Label("复制在这台，粘贴到另一台。"), 0, 1);
        header.Controls.Add(logo, 0, 0); header.Controls.Add(heading, 1, 0);
        header.Controls.Add(new Label { Text = Product.Badge, AutoSize = true, ForeColor = Ui.Teal, BackColor = Ui.Soft, Padding = new Padding(12, 8, 12, 8), Margin = new Padding(0, 10, 0, 0) }, 2, 0);
        layout.Controls.Add(header, 0, 0);
        var connection = Ui.Stack(8, true);
        connection.Padding = new Padding(16);
        var connectionHeading = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 2, Margin = new Padding(0, 0, 0, 8) };
        connectionHeading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); connectionHeading.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var modeActions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
        var modePicker = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 240, AccessibleName = "同步方式" };
        modePicker.Items.AddRange(["需要 Android / NAS 同步", "仅电脑 / 已登录网盘同步目录", "仅本机历史（不连接）"]);
        modePicker.SelectedIndex = Product.Mode == SyncMode.Nas ? 0 : Product.IsDrive ? 1 : 2;
        var switchMode = Ui.Button("切换方式（重启生效）");
        switchMode.Click += async (_, _) => await SwitchMode(modePicker.SelectedIndex == 0 ? SyncMode.Nas : modePicker.SelectedIndex == 1 ? SyncMode.CloudFolder : SyncMode.LocalOnly);
        var aiHelp = Ui.Button("复制 AI 排查提示"); aiHelp.Click += (_, _) => CopyAiHelp();
        modeActions.Controls.AddRange([modePicker, switchMode, aiHelp]);
        connectionHeading.Controls.Add(modeActions, 0, 0);
        connectionToggle.MinimumSize = new Size(0, 30); connectionToggle.Padding = new Padding(8, 3, 8, 3); connectionToggle.Margin = Padding.Empty; connectionToggle.Visible = false;
        connectionToggle.Click += (_, _) => SetConnectionExpanded(!connectionExpanded);
        connectionHeading.Controls.Add(connectionToggle, 1, 0); connection.Controls.Add(connectionHeading, 0, 0);
        var folderHint = Ui.Label(Product.Onboarding);
        if (Product.IsDrive)
        {
            var guidance = Ui.Stack(3);
            provider = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill, AccessibleName = "网盘类型（仅说明，不会登录）" };
            provider.Items.AddRange(["OneDrive · 未经真机验证", "百度网盘 · 未经真机验证", "iCloud · 未经真机验证", "其他同步文件夹 · 未经真机验证"]);
            provider.SelectedIndex = 0;
            guidance.Controls.Add(provider, 0, 0);
            guidance.Controls.Add(Ui.Label("网盘类型仅作说明，不自动配置客户端。必须支持双向同步与完整本地文件。"), 0, 1);
            guidance.Controls.Add(folderHint, 0, 2);
            connection.Controls.Add(guidance, 0, 1);
            connectionDetails.Add(guidance);
        }
        else
        {
        connection.Controls.Add(folderHint, 0, 1);
}
        var pathRow = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 3, Margin = Padding.Empty };
        pathRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); pathRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); pathRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var browse = Ui.Button("浏览…"); browse.Anchor = AnchorStyles.Top | AnchorStyles.Right; browse.Margin = Padding.Empty;
        pathRow.Controls.Add(Ui.Field(folderInput), 0, 0); pathRow.Controls.Add(browse, 1, 0);
        var diagnose = Ui.Button("检测路径"); diagnose.Margin = Padding.Empty; pathRow.Controls.Add(diagnose, 2, 0);
        diagnose.Click += async (_, _) => await CheckFolder();
        connection.Controls.Add(pathRow, 0, 2); browse.Click += (_, _) => BrowseFolder();
        var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 4, 0, 0) };
        var create = Ui.Button("首台：创建空间"); var join = Ui.Button(Product.JoinLabel, true);
        actions.Controls.AddRange([create, join, pairButton, pause]); connection.Controls.Add(actions, 0, 3);
        connection.Controls.Add(folderLabel, 0, 4); connection.Controls.Add(status, 0, 5);
        connection.Controls.Add(delivery, 0, 6);
        pairPanel.Margin = new Padding(0, 4, 0, 0); connection.Controls.Add(pairPanel, 0, 7);
        connectionDetails.AddRange([folderHint, pathRow, actions, folderLabel]);
        if (Product.IsLocal)
        {
            folderHint.Text = "仅本机历史：不会连接 NAS 或网盘，不会把已有历史排入发送队列。需要 Android 请选择 NAS；已有电脑端双向同步文件夹可选择网盘方式。";
            pathRow.Visible = actions.Visible = false;
            connectionDetails.Remove(pathRow); connectionDetails.Remove(actions);
            status.Text = "仅本机历史 · 同步未连接";
            delivery.Text = "只记录本机内容；隐私暂停可停止记录。";
        }
        layout.Controls.Add(connection, 0, 1);
        var historyCard = Ui.Stack(4, true); historyCard.AutoSize = false; historyCard.Margin = Padding.Empty; historyCard.MinimumSize = new Size(0, 330);
        historyCard.RowStyles[2] = new RowStyle(SizeType.Percent, 100);
        var historyHeading = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 2, Margin = Padding.Empty };
        historyHeading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); historyHeading.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        historyHeading.Controls.Add(Ui.Label("剪贴板历史", true), 0, 0); historyHeading.Controls.Add(historyCount, 1, 0);
        historyCard.Controls.Add(historyHeading, 0, 0); historyCard.Controls.Add(Ui.Field(search), 0, 1);
        var historyBody = new Panel { Dock = DockStyle.Fill, MinimumSize = new Size(0, 148), Margin = new Padding(0, 4, 0, 12) };
        historyBody.Controls.Add(list); historyBody.Controls.Add(emptyHistory); historyCard.Controls.Add(historyBody, 0, 2);
        var footer = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, Margin = Padding.Empty };
        var copy = Ui.Button("复制选中记录", true); copy.Enabled = false;
        var clear = Ui.Button("清空本机历史");
        var preview = Ui.Button("预览图片"); preview.Enabled = false;
        list.SelectedIndexChanged += (_, _) => { copy.Enabled = list.SelectedItem != null; preview.Enabled = list.SelectedItem is HistoryItem { IsImage: true }; };
        preview.Click += async (_, _) => await PreviewSelected();
        footer.Controls.AddRange([copy, preview, clear, privacy]); historyCard.Controls.Add(footer, 0, 3); layout.Controls.Add(historyCard, 0, 2);
        var trayHint = Ui.Label("关闭窗口后继续在右下角托盘运行 · 双击轻贴图标重新打开"); trayHint.Margin = new Padding(0, 14, 0, 0);
        layout.Controls.Add(trayHint, 0, 3); Controls.Add(layout);
        ResumeLayout(true);
        var menu = new ContextMenuStrip(); menu.Items.Add("打开" + Product.Title, null, (_, _) => ShowWindow());
        menu.Items.Add("暂停 / 恢复同步", null, async (_, _) => await Toggle());
        privacyTray.Click += async (_, _) => await TogglePrivacy(); menu.Items.Add(privacyTray);
        menu.Items.Add("退出", null, (_, _) => { closing = true; Close(); });
        tray = new NotifyIcon { Icon = Ui.TrayIcon, Text = Product.Title + " · 双击打开", Visible = true, ContextMenuStrip = menu };
        tray.DoubleClick += (_, _) => ShowWindow();
        create.Click += async (_, _) => await Configure(true); join.Click += async (_, _) => await Configure(false);
        pause.Click += async (_, _) => await Toggle(); privacy.Click += async (_, _) => await TogglePrivacy(); pairButton.Click += async (_, _) => await StartPairing();
        search.TextChanged += (_, _) => RefreshHistory(); copy.Click += async (_, _) => await CopySelected(); list.DoubleClick += async (_, _) => await CopySelected();
        clear.Click += async (_, _) => {
            if (MessageBox.Show(Product.ClearWarning, Text, MessageBoxButtons.OKCancel) != DialogResult.OK) return;
            await ClearHistory();
        };
        Shown += async (_, _) => {
            var area = Screen.FromControl(this).WorkingArea;
            MinimumSize = new Size(Math.Min(MinimumSize.Width, area.Width), Math.Min(MinimumSize.Height, area.Height));
            Size = new Size(Math.Min(Width, area.Width), Math.Min(Height, area.Height));
            Location = new Point(area.Left + (area.Width - Width) / 2, area.Top + (area.Height - Height) / 2);
            await LoadState();
        };
        FormClosing += (_, e) => { if (!closing) { e.Cancel = true; Hide(); } };
        FormClosed += (_, _) => { timer.Stop(); pairingCancel?.Cancel(); privacyCancel.Cancel(); transferCancel.Cancel(); RemoveClipboardFormatListener(Handle); tray.Dispose(); };
        capture.Ignore(GetClipboardSequenceNumber());
        if (!AddClipboardFormatListener(Handle)) status.Text = "剪贴板通知不可用，正在使用定时检查。";
        timer.Tick += async (_, _) => { pairPanel.Invalidate(); await CaptureClipboard(); if (Wire.Now - lastPoll >= 2000) { lastPoll = Wire.Now; await Poll(); } Prune(); };
        timer.Start();
    }
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_CLIPBOARDUPDATE && !writingClipboard && GetClipboardSequenceNumber() != capture.LastSequence) { epoch++; clipboardActivityCreated = Wire.Now; holdUntil = Wire.Now + 10000; }
        base.WndProc(ref m);
    }
    void ShowWindow() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    async Task SwitchMode(SyncMode selected)
    {
        if (!stateLoaded || busy || modeSwitching || privacyTransition || selected == Product.Mode) return;
        if (MessageBox.Show(this, "切换会停止当前收发并退出轻贴。请手动重新打开后使用所选方式。原方式的配置、历史和待发送队列会保留，彼此不复制。已有文件仍可能由独立网盘客户端上传。是否继续？", Product.Title, MessageBoxButtons.OKCancel) != DialogResult.OK) return;
        modeSwitching = busy = true; Enabled = false; timer.Stop(); epoch++; session = Guid.NewGuid();
        privacyCancel.Cancel(); transferCancel.Cancel(); pairingView.Begin();
        status.Text = "正在停止当前方式；等待已经发起的本机文件操作结束…";
        try
        {
            await CancelPairing();
            while (captureBusy || polling) await Task.Delay(50);
            await gate.WaitAsync();
            try
            {
                engine?.Suspend(); imageEngine?.Suspend();
                await Task.Run(() => ModePreferences.Save(selected));
            }
            finally { gate.Release(); }
            capture.Ignore(GetClipboardSequenceNumber());
            closing = true; Close(); // No automatic process launch; next user launch reads one selected mode.
        }
        catch
        {
            ApplyPrivacyState(true);
            status.Text = "切换未完成，当前已停止收发。请退出后重新打开再检查方式；原有数据保留。";
            busy = false; modeSwitching = false; Enabled = true;
        }
    }
    void CopyAiHelp()
    {
        if (modeSwitching) return;
        // Fixed allowlisted fields only. Never interpolate status.Text, paths, hostnames, keys, clipboard or account data.
        string mode = Product.IsLocal ? "仅本机历史" : Product.IsDrive ? "网盘同步文件夹" : "NAS";
        string selectedProvider = !Product.IsDrive ? "不适用" : provider?.SelectedIndex switch { 0 => "OneDrive", 1 => "百度网盘", 2 => "iCloud", _ => "其他同步文件夹" };
        string genericStatus = capture.PrivacyPaused ? "隐私暂停" : config?.Enabled == true ? "已启用；仅本机状态可知，对端接收未知" : "未连接或同步暂停";
        string prompt = $"请协助排查轻贴配置。系统：Windows；方式：{mode}；提供商：{selectedProvider}（兼容性未经真机验证）；状态：{genericStatus}。\n先进行只读诊断，并说明每一步要验证什么。需要 Android 时使用 NAS；桌面网盘方式要求双向同步、文件始终完整保留在本机，不能把虚拟盘或备份当作双向同步。\n安装软件、修改网络或安全设置前必须先询问我并解释风险。绝不关闭防火墙、杀毒、权限保护或其他安全机制。不要索取或展示密码、配对密钥、令牌、个人路径、服务器名、账号或剪贴板内容。只用无敏感内容的测试文字，让我亲自确认两端结果，不把本机写入称为云端上传成功。";
        try
        {
            writingClipboard = true; Clipboard.SetText(prompt, TextDataFormat.UnicodeText);
            capture.Ignore(GetClipboardSequenceNumber()); epoch++; clipboardActivityCreated = Wire.Now; holdUntil = Wire.Now + 10000;
            status.Text = "已复制不含个人信息的 AI 排查提示；由你自行决定是否粘贴给其他 AI。";
        }
        catch (ExternalException) { status.Text = "剪贴板正忙，提示未复制，请重试。"; }
        finally { writingClipboard = false; }
    }
    async Task LoadState()
    {
        busy = true;
        try
        {
            var result = await Task.Run(() => {
                List<HistoryItem> old = [];
                var h = Path.Combine(Storage.Root, "history.protected");
                if (File.Exists(h)) old = JsonSerializer.Deserialize<List<HistoryItem>>(Storage.Unprotect(File.ReadAllText(h))) ?? [];
                var c = Path.Combine(Storage.Root, "config.json");
                var cfg = File.Exists(c) ? JsonSerializer.Deserialize<Config>(File.ReadAllBytes(c)) : null;
                var paused = PrivacyPreferences.Read(Storage.Root);
                var vault = Storage.OpenImageVault();
                var images = vault.History(Wire.Now); // Isolate damaged records; verify all visible images before use.
                return (old, cfg, paused, vault, images, rejected: vault.Rejected);
            });
            ApplyPrivacyState(result.paused);
            imageVault = result.vault;
            history.AddRange(result.old.Where(x => x.Expires > Wire.Now
                && (x.IsImage || !IsDrivePairSecret(x.Text))
            ));
            foreach (var image in result.images) Add(ImageItem(image));
            RefreshHistory();
            if (result.rejected > 0) delivery.Text = $"{result.rejected} 条本机图片无法校验，已跳过；其余历史仍可使用。";
            if (!Product.IsLocal && result.cfg is { } saved)
            {
                var p = Pair.Parse(Encoding.UTF8.GetString(Storage.Unprotect(saved.ProtectedPair)));
                if (Product.IsDrive && saved.AwaitingSpace)
                {
                    config = saved; pair = p; folderInput.Text = saved.Folder;
                    pause.Enabled = pairButton.Enabled = true; pause.Text = saved.Enabled ? "暂停同步" : "恢复同步";
                    status.Text = "等待空间文件下载到本机；配对密钥已加密保存在本机。";
                }
                else await Activate(saved.Folder, p, null, saved.Enabled);
            }
        }
        catch { ApplyPrivacyState(true); status.Text = "读取本机数据失败，已启用隐私暂停；请检查用户目录权限后重试。"; }
        finally { busy = false; stateLoaded = true; }
    }
    bool ConfirmLocalFolder() => MessageBox.Show(this,
        "请确认已自行登录所选网盘并启用双向文件夹同步。两台电脑应指向同一云端文件夹。\n\n请先把文件设为始终完整保留在本机，并等待下载完成。虚拟挂载盘、仅备份、按需占位文件不满足要求。所有网盘兼容性均未经真机验证。轻贴不会替你登录或安装网盘，无法验证上传状态。\n\n已经完成以上准备？",
        Product.Title, MessageBoxButtons.OKCancel, MessageBoxIcon.Information) == DialogResult.OK;
    void BrowseFolder()
    {
        if (busy) return;
        using var browser = new FolderBrowserDialog { Description = Product.BrowseHint, UseDescriptionForTitle = true, ShowNewFolderButton = false };
        if (browser.ShowDialog(this) == DialogResult.OK) folderInput.Text = browser.SelectedPath;
    }
    string? ReadFolder()
    {
        var folder = folderInput.Text.Trim();
        if (string.IsNullOrEmpty(folder)) { status.Text = Product.MissingFolder; folderInput.Focus(); return null; }
        try
        {
            if (!Path.IsPathFullyQualified(folder) || folder.Contains("://")) throw new ArgumentException();
            return Path.GetFullPath(folder);
        }
        catch { status.Text = Product.InvalidFolder; return null; }
    }
    async Task<bool> CheckFolder(string? selected = null)
    {
        if (busy) return false;
        var folder = selected ?? ReadFolder();
        if (folder == null) return false;
        var requestToken = privacyCancel.Token;
        busy = true; status.Text = Product.Checking;
        try
        {
            var result = await Task.Run(() => FolderDiagnostics.Check(folder));
            if (!requestToken.IsCancellationRequested && !privacyTransition && !capture.PrivacyPaused) status.Text = Product.Diagnostic(result);
            return result.Success;
        }
        catch { if (!requestToken.IsCancellationRequested && !privacyTransition && !capture.PrivacyPaused) status.Text = Product.CheckFailed; return false; }
        finally { busy = false; }
    }
    async Task Configure(bool create)
    {
        if (Product.IsLocal || busy || privacyTransition) return;
        if (capture.PrivacyPaused) { status.Text = "隐私暂停中，请先恢复后再连接或配对。"; return; }
        var requestToken = privacyCancel.Token;
        var folder = ReadFolder();
        if (Product.IsDrive && (folder == null || !ConfirmLocalFolder())) return;
        if (folder == null || !await CheckFolder(folder)) return;
        if (requestToken.IsCancellationRequested || capture.PrivacyPaused || privacyTransition) return;
        if (Product.IsDrive)
        {
            Pair selectedPair;
            if (create) selectedPair = Pair.Create();
            else
        {
                busy = true;
                string? entered;
                try { entered = DrivePairDialog.Enter(this); }
                finally { capture.Ignore(GetClipboardSequenceNumber()); busy = false; }
                if (entered == null) return;
                try { selectedPair = Pair.ParseDrive(entered); }
                catch { status.Text = "配对密钥无效，请输入首台显示的完整 clipday-drive1: 密钥。"; return; }
            }
            if (requestToken.IsCancellationRequested || capture.PrivacyPaused || privacyTransition) return;
            if (!create)
        {
                busy = true;
                try
                {
                    await gate.WaitAsync(requestToken);
                    try
                    {
                        var pending = new Config(folder, Storage.Protect(Encoding.UTF8.GetBytes(selectedPair.Code)), true, AwaitingSpace: true);
                        await Task.Run(() => { requestToken.ThrowIfCancellationRequested(); Storage.SaveConfig(pending); });
                        engine = null; imageEngine = null; config = pending; pair = selectedPair;
                        epoch++; session = Guid.NewGuid(); nextJoinAttempt = 0; joinBackoffSeconds = 5;
                        pause.Text = "暂停同步";
                        pause.Enabled = pairButton.Enabled = true;
                        status.Text = "等待空间文件下载到本机；期间只记录本机历史，不补传。";
                    }
                    finally { gate.Release(); }
                }
                catch (OperationCanceledException) { }
                catch { status.Text = "配对信息无法保存到本机，请检查用户目录权限。"; }
                finally { busy = false; }
                return;
            }
            if (await Activate(folder, selectedPair, true, true)) await StartPairing();
        }
        else
        {
        if (create)
        {
            pairingView.Begin(); busy = true;
            try { await CancelPairing(); pairPanel.Visible = false; }
            finally { busy = false; }
            if (requestToken.IsCancellationRequested || capture.PrivacyPaused || privacyTransition) return;
            var p = Pair.Create(); await Activate(folder, p, true, true);
            if (pair == p) await StartPairing();
        }
        else
        {
            var entered = PromptCode();
            if (entered == null || requestToken.IsCancellationRequested || capture.PrivacyPaused || privacyTransition) return;
            string code;
            try { code = ShortPairing.NormalizeCode(entered); }
            catch { status.Text = "请输入另一台电脑显示的 6 位数字。"; return; }
            var active = pairingView.Begin(); // Invalidate queued host callbacks before awaiting cancellation.
            busy = true; status.Text = "正在配对…";
            ShowPairing(active, new("status", Message: "正在配对…"));
            try {
                await CancelPairing();
                // Cancellation may have waited on NAS I/O while privacy pause invalidated this request.
                if (requestToken.IsCancellationRequested || capture.PrivacyPaused || privacyTransition) return;
                pairingCancel = new CancellationTokenSource(); var token = pairingCancel.Token;
                var paired = await Task.Run(() => ShortPairing.JoinAsync(folder, code, token));
                if (requestToken.IsCancellationRequested || capture.PrivacyPaused || privacyTransition) return;
                if (await Activate(folder, paired, false, true)) ShowPairing(active, new("success", Message: "配对成功"));
                else ShowPairing(active, new("error", Message: "已验证数字，但未能连接同步空间，请检查 NAS 后重试。"));
            }
            catch (Exception e) { ShowPairing(active, new("error", Message: e is IOException or InvalidDataException ? e.Message : "配对失败，请检查 NAS 连接后重试。")); }
            finally { busy = false; }
        }
}
    }
    string? PromptCode()
    {
        using var dialog = new PairDialog();
        return dialog.ShowDialog(this) == DialogResult.OK ? dialog.Code : null;
    }
    async Task<bool> Activate(string folder, Pair p, bool? create, bool enabled)
    {
        busy = true; epoch++; session = Guid.NewGuid(); status.Text = Product.Connecting;
        var operationToken = create.HasValue ? privacyCancel.Token : CancellationToken.None;
        await gate.WaitAsync();
        try
        {
            var next = await Task.Run(() => {
                operationToken.ThrowIfCancellationRequested();
                if (create.HasValue)
                {
                    FolderSync.Setup(folder, p, create.Value, cloudDrive: Product.IsDrive);
                    operationToken.ThrowIfCancellationRequested();
                    var diagnostics = FolderDiagnostics.Check(Product.IsDrive ? Path.Combine(folder, "ClipDayDrive", "v1", p.Space, "records") : Path.Combine(folder, "ClipDaySync", p.Space, "records"));
                    if (!diagnostics.Success) throw new IOException(diagnostics.Message);
                }
                operationToken.ThrowIfCancellationRequested();
                var sync = new FolderSync(folder, Path.Combine(Storage.Root, "sync", p.Space), p, Environment.MachineName, cloudDrive: Product.IsDrive);
                var cfg = new Config(folder, Storage.Protect(Encoding.UTF8.GetBytes(p.Code)), enabled);
                operationToken.ThrowIfCancellationRequested();
                var images = new FolderImageSync(sync, imageVault ?? throw new InvalidDataException());
                Storage.SaveConfig(cfg); return (sync, cfg, images);
            });
            operationToken.ThrowIfCancellationRequested();
            engine = next.sync; imageEngine = next.images; config = next.cfg; pair = p;
            if (enabled && transferCancel.IsCancellationRequested) { transferCancel.Dispose(); transferCancel = new(); }
            folderInput.Text = folder; folderLabel.Text = "当前连接：" + folder; folderLabel.Visible = true; pause.Enabled = pairButton.Enabled = true;
            pause.Text = enabled ? "暂停同步" : "恢复同步";
            status.Text = capture.PrivacyPaused ? "隐私暂停中：不记录、不发送、不接收。" : enabled ? Product.Connected : "同步已暂停，本机历史继续记录";
            SetConnectionExpanded(false);
            return true;
        }
        catch (OperationCanceledException) when (operationToken.IsCancellationRequested) { return false; }
        catch (Exception e)
        {
            if (!capture.PrivacyPaused) status.Text = !Product.IsDrive && e is IOException ? e.Message : Product.ConnectFailed;
            return false;
        }
        finally { busy = false; gate.Release(); }
    }
    async Task CancelPairing()
    {
        pairingCancel?.Cancel();
        if (pairingTask != null) { try { await pairingTask; } catch (OperationCanceledException) { } }
        pairingCancel?.Dispose(); pairingCancel = null; pairingTask = null;
    }
    void ShowPairing(Guid active, PairEvent ev)
    {
        if (IsDisposed || !pairingView.TryApply(active, ev)) return;
        pairPanel.ShowEvent(ev); pairButton.Enabled = pair != null;
        pairButton.Text = ev.Type == "success" ? "配对另一台电脑" : "重新生成配对码";
        if (ev.Type == "success") SetConnectionExpanded(false);
        if (ev.Type == "error") status.Text = "本次配对未完成";
    }
    void PostPairing(Guid active, PairEvent ev)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(() => ShowPairing(active, ev)); }
        catch (InvalidOperationException) when (IsDisposed || Disposing) { }
    }
    void SetConnectionExpanded(bool expanded)
    {
        connectionExpanded = expanded;
        foreach (var control in connectionDetails) control.Visible = expanded && (control != folderLabel || config != null);
        connectionToggle.Visible = config != null;
        connectionToggle.Text = expanded ? "收起设置" : "连接设置";
    }
    async Task StartPairing()
    {
        if (pair == null || config == null || busy || capture.PrivacyPaused || privacyTransition) return;
        if (Product.IsDrive)
        {
            busy = true;
            try { DrivePairDialog.Reveal(this, pair.DriveCode); }
            finally { capture.Ignore(GetClipboardSequenceNumber()); busy = false; }
            await Task.CompletedTask;
        }
        else
        {
        var requestToken = privacyCancel.Token;
        var active = pairingView.Begin();
        busy = true; pairButton.Enabled = false;
        try {
            await CancelPairing();
            if (requestToken.IsCancellationRequested || capture.PrivacyPaused || privacyTransition) return;
            pairingCancel = new CancellationTokenSource();
            var token = pairingCancel.Token; var currentPair = pair; var currentFolder = config.Folder;
            ShowPairing(active, new("status", Message: "正在生成配对码…"));
            pairingTask = Task.Run(async () => {
                try { await ShortPairing.HostAsync(currentFolder, currentPair, ev => PostPairing(active, ev), token); }
                catch (OperationCanceledException) { }
                catch (Exception e) {
                    PostPairing(active, new("error", Message: e is IOException or InvalidDataException ? e.Message : "配对失败，请检查 NAS 连接后重试。"));
                }
            });
        }
        finally { busy = false; }
}
    }
    async Task Toggle()
    {
        if (config == null || busy || privacyTransition) return;
        config = config with { Enabled = !config.Enabled };
        if (!config.Enabled) transferCancel.Cancel();
        else if (transferCancel.IsCancellationRequested) { transferCancel.Dispose(); transferCancel = new(); }
        epoch++; holdUntil = Wire.Now + 10000;
        pause.Text = config.Enabled ? "暂停同步" : "恢复同步"; status.Text = capture.PrivacyPaused ? "隐私暂停中：不记录、不发送、不接收。" : config.Enabled ? "正在恢复同步…" : "同步已暂停，本机历史继续记录";
        var current = config;
        await gate.WaitAsync();
        try { await Task.Run(() => { engine?.Suspend(); imageEngine?.Suspend(); Storage.SaveConfig(current); }); }
        catch { status.Text = "同步状态保存失败，请检查磁盘权限。"; }
        finally { gate.Release(); }
    }
    void ApplyPrivacyState(bool paused)
    {
        capture.SetPrivacyPaused(paused, GetClipboardSequenceNumber());
        epoch++; holdUntil = Wire.Now + 10000;
        if (paused) privacyCancel.Cancel();
        else if (privacyCancel.IsCancellationRequested) { privacyCancel.Dispose(); privacyCancel = new(); }
        privacy.Text = privacyTray.Text = paused ? "恢复记录与同步" : "隐私暂停";
        tray.Text = paused ? Product.Title + " · 隐私暂停中" : Product.Title + " · 双击打开";
    }
    async Task TogglePrivacy()
    {
        if (modeSwitching || !stateLoaded || privacyTransition) return;
        privacyTransition = true; privacy.Enabled = privacyTray.Enabled = false;
        bool paused = !capture.PrivacyPaused;
        ApplyPrivacyState(paused);
        status.Text = paused ? "正在进入隐私暂停；已发起的磁盘写入可能完成，之后不再记录或收发。" : "正在恢复记录与同步…";
        try
        {
            if (paused) { pairingView.Begin(); await CancelPairing(); pairPanel.Visible = false; }
            await gate.WaitAsync();
            try { await Task.Run(() => { engine?.Suspend(); imageEngine?.Suspend(); Storage.SavePrivacy(paused); }); }
            finally { gate.Release(); }
            status.Text = paused ? "隐私暂停中：不记录、不发送、不接收；已有历史和队列保留。" : config?.Enabled == true ? "已恢复；暂停期间的剪贴板不会补录，对端接收未确认。" : "已恢复本机记录；同步仍未开启，暂停期间的剪贴板不会补录。";
        }
        catch { status.Text = paused ? "本次隐私暂停已生效，但设置保存失败；重启后请重新确认。" : "已恢复，但设置保存失败；重启后请重新确认。"; }
        finally
        {
            capture.Ignore(GetClipboardSequenceNumber());
            privacyTransition = false; privacy.Enabled = privacyTray.Enabled = true;
        }
    }
    async Task CaptureClipboard()
    {
        if (modeSwitching || captureBusy || busy || privacyTransition || capture.PrivacyPaused) return;
        var sequence = GetClipboardSequenceNumber();
        if (!capture.ShouldCapture(sequence)) return;
        captureBusy = true; epoch++; holdUntil = Wire.Now + 10000;
        CaptureAttempt? attempt = null;
        var operationToken = privacyCancel.Token;
        try
        {
            var data = Clipboard.GetDataObject();
            if (data == null) return;
            if (data.GetData(DataFormats.UnicodeText) is string secret && IsDrivePairSecret(secret))
            {
                capture.Ignore(sequence); status.Text = "配对密钥不记录、不自动同步。"; return;
            }
            if (new[] { "ExcludeClipboardContentFromMonitorProcessing", "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard", "org.nspasteboard.ConcealedType" }.Any(data.GetDataPresent) || data.GetDataPresent(DataFormats.FileDrop)) { capture.Ignore(sequence); return; }
            if (ClipboardImages.Contains(data))
            {
                byte[] png;
                try { png = capture.Pending is { Png: { } existing, Sequence: var pendingSequence } && pendingSequence == sequence ? existing : ClipboardImages.Normalize(data); }
                catch (Exception e) when (e is InvalidDataException or ArgumentException or OverflowException) { capture.Ignore(sequence); status.Text = e is InvalidDataException ? e.Message : "图片格式或尺寸不受支持，未记录或同步。"; return; }
                if (GetClipboardSequenceNumber() != sequence) return;
                var imageAttempt = capture.BeginImage(sequence, png, Wire.Now); attempt = imageAttempt; clipboardActivityCreated = Math.Max(clipboardActivityCreated, imageAttempt.Created);
                await CaptureImage(imageAttempt, operationToken); return;
            }
            if (!data.GetDataPresent(DataFormats.UnicodeText)) { capture.Ignore(sequence); return; }
            var text = data.GetData(DataFormats.UnicodeText) as string;
            if (string.IsNullOrEmpty(text) || GetClipboardSequenceNumber() != sequence) return;
            if (Encoding.UTF8.GetByteCount(text) > Wire.MaxText) { capture.Ignore(sequence); status.Text = "文字超过 1 MB，未记录或同步。"; return; }
            var currentAttempt = capture.Begin(sequence, text, Wire.Now); attempt = currentAttempt; clipboardActivityCreated = Math.Max(clipboardActivityCreated, currentAttempt.Created);
            Add(new(currentAttempt.Id, text, "本机", currentAttempt.Created, currentAttempt.Created + Wire.Lifetime)); RefreshHistory();
            await gate.WaitAsync(operationToken);
            try
            {
                operationToken.ThrowIfCancellationRequested();
                var snapshot = history.ToList(); var sync = engine;
                bool send = config?.Enabled == true && sync != null;
                bool committed = await capture.CommitAsync(currentAttempt,
                    () => Task.Run(() => { operationToken.ThrowIfCancellationRequested(); Storage.SaveHistory(snapshot); }),
                    send ? () => Task.Run(() => { operationToken.ThrowIfCancellationRequested(); sync!.Enqueue(text, currentAttempt.Created, currentAttempt.Id); }) : null);
                if (!committed) return;
                if (send) holdUntil = 0;
                delivery.Text = send ? Product.Queued : "本机已保存 · 未开启同步，不会上传此条记录";
            }
            finally { gate.Release(); }
        }
        catch (OperationCanceledException) when (operationToken.IsCancellationRequested) { }
        catch (ExternalException) { /* Clipboard lock: timer retries the same sequence. */ }
        catch (Exception e)
        {
            if (!capture.PrivacyPaused)
                delivery.Text = attempt?.Png != null && e is IOException or InvalidDataException ? e.Message + "（此条未完成保存，会重试。）" : attempt?.SavedLocally == true ? "本机已保存 · 待发送队列写入失败，自动重试；请检查磁盘空间" : "本机保存失败，自动重试；请检查磁盘空间和用户目录权限";
        }
        finally { captureBusy = false; }
    }
    static HistoryItem ImageItem(ImageRecord r) => new(r.Id, "", r.Name, r.Created, r.Expires, r);
    async Task CaptureImage(CaptureAttempt attempt, CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            token.ThrowIfCancellationRequested();
            var vault = imageVault ?? throw new IOException("图片存储尚未就绪。"); var sync = imageEngine;
            bool send = config?.Enabled == true && sync != null;
            ImageRecord? saved = null;
            bool committed = await capture.CommitAsync(attempt, () => Task.Run(() => {
                token.ThrowIfCancellationRequested();
                if (send) saved = sync!.Enqueue(attempt.Png!, attempt.Id, attempt.Created, token);
                else
                {
                    saved = FolderImageSync.Create(attempt.Png!, attempt.Id, localImageIdentity, localImageIdentity, "本机", 1, attempt.Created, []);
                    token.ThrowIfCancellationRequested(); vault.Put(saved, attempt.Png!, false, Wire.Now);
                }
            }), null);
            if (!committed || saved == null || token.IsCancellationRequested) return;
            Add(ImageItem(saved) with { Source = "本机" }); RefreshHistory();
            if (send) holdUntil = 0;
            delivery.Text = send ? "图片已加密保存在本机 · 已加入待发送队列" : "图片已加密保存在本机 · 同步关闭，不会补传此条";
        }
        finally { gate.Release(); }
    }
    async Task RetryPendingJoin()
    {
        if (busy || capture.PrivacyPaused || privacyTransition || config is not { AwaitingSpace: true, Enabled: true } pending || pair == null || Wire.Now < nextJoinAttempt) return;
        nextJoinAttempt = Wire.Now + joinBackoffSeconds * 1000L;
        joinBackoffSeconds = Math.Min(60, joinBackoffSeconds * 2);
        if (!await Activate(pending.Folder, pair, false, pending.Enabled) && !capture.PrivacyPaused)
            status.Text = "等待空间文件完整下载到本机，或密钥不匹配；将重试。可重新输入密钥或暂停同步。";
    }
    async Task Poll()
    {
        if (Product.IsDrive) await RetryPendingJoin();
        if (modeSwitching || polling || busy || privacyTransition || capture.PrivacyPaused || engine == null || config?.Enabled != true) return;
        polling = true; var sync = engine; var images = imageEngine; var token = epoch; var activeSession = session; var sequence = GetClipboardSequenceNumber();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(privacyCancel.Token, transferCancel.Token);
        var operationToken = cancellation.Token; bool acquired = false;
        bool Current() => activeSession == session && config?.Enabled == true && !capture.PrivacyPaused && !operationToken.IsCancellationRequested;
        bool CanApply(long created) => Current() && !captureBusy && token == epoch && Wire.Now >= holdUntil && sequence == GetClipboardSequenceNumber() && sequence == capture.LastSequence && created >= clipboardActivityCreated && created <= Wire.Now && Wire.Now - created <= sync.AutomaticWindow;
        try
        {
            await gate.WaitAsync(operationToken); acquired = true;
            if (!Current()) return;
            // Text is always serviced before the next image, including when an image backlog exists.
            var batch = await Task.Run(() => sync.Poll(cancellationToken: operationToken));
            if (!Current()) return;
            foreach (var r in batch.Records) Add(new(r.Id, r.Text, r.Name, r.Created, r.Expires));
            RefreshHistory();
            var snapshot = history.ToList(); await Task.Run(() => { operationToken.ThrowIfCancellationRequested(); Storage.SaveHistory(snapshot); operationToken.ThrowIfCancellationRequested(); sync.Acknowledge(batch.Records); });
            if (!Current()) return;
            ImageBatch? imageBatch = null; bool imageUnavailable = false;
            try { if (images != null) imageBatch = await Task.Run(() => images.Poll(cancellationToken: operationToken)); }
            catch (Exception ex) when (ex is IOException or InvalidDataException or CryptographicException or JsonException or ArgumentException) { imageUnavailable = true; }
            if (!Current()) return;
            if (imageBatch != null)
            {
                foreach (var r in imageBatch.Records) Add(ImageItem(r));
                // Reload verified local entries, including a transfer whose late callback was canceled.
                var visible = await Task.Run(() => imageVault!.List(Wire.Now).Where(x => x.Visible).Select(x => x.Record).ToList());
                if (!Current()) return;
                foreach (var r in visible) Add(ImageItem(r));
            }
            var choice = ClipboardDelivery.Newest(batch.Automatic, imageBatch?.Automatic);
            if (choice.Image is { } image && CanApply(image.Created))
            {
                var png = await Task.Run(() => imageVault!.Read(image));
                if (CanApply(image.Created))
                {
                    using var bitmap = ClipboardImages.Decode(png);
                    try { writingClipboard = true; Clipboard.SetImage(bitmap); capture.Ignore(GetClipboardSequenceNumber()); clipboardActivityCreated = image.Created; epoch++; }
                    catch (ExternalException) { status.Text = "图片已进入历史，系统剪贴板正忙。"; }
                    finally { writingClipboard = false; }
                }
            }
            else if (choice.Text is { } remote && CanApply(remote.Created)
                && !IsDrivePairSecret(remote.Text)
            )
            {
                try { writingClipboard = true; Clipboard.SetText(remote.Text, TextDataFormat.UnicodeText); capture.Ignore(GetClipboardSequenceNumber()); clipboardActivityCreated = remote.Created; epoch++; }
                catch (ExternalException) { status.Text = "文字已进入历史，系统剪贴板正忙。"; }
                finally { writingClipboard = false; }
            }
            RefreshHistory();
            int rejected = batch.Rejected + (imageBatch?.Rejected ?? 0), uploaded = batch.Uploaded + (imageBatch?.Uploaded ?? 0);
            status.Text = imageUnavailable ? "文字同步已完成；图片暂不可用，保留队列重试。" : rejected == 0 ? Product.PollSuccess : Product.Rejected(rejected);
            if (uploaded > 0) delivery.Text = Product.Written(uploaded);
        }
        catch (OperationCanceledException) when (operationToken.IsCancellationRequested) { }
        catch { if (!capture.PrivacyPaused && !operationToken.IsCancellationRequested) status.Text = Product.Unavailable; }
        finally { polling = false; if (acquired) gate.Release(); }
    }
    static bool IsDrivePairSecret(string text) => text.Trim().StartsWith("clipday-drive1:", StringComparison.Ordinal);
    void Add(HistoryItem item)
    {
        if (!item.IsImage && IsDrivePairSecret(item.Text)) return;
        if (item.Expires <= Wire.Now || history.Any(x => x.Id == item.Id || (!item.IsImage && !x.IsImage && x.Text == item.Text && x.Created >= item.Created))) return;
        if (!item.IsImage) history.RemoveAll(x => !x.IsImage && x.Text == item.Text); history.Add(item); history.Sort((a, b) => b.Created.CompareTo(a.Created)); Prune();
    }
    void Prune()
    {
        int removed = history.RemoveAll(x => x.Expires <= Wire.Now);
        long bytes = history.Sum(x => (long)Encoding.UTF8.GetByteCount(x.Text));
        while (history.Count(x => !x.IsImage) > 2000 || bytes > 100 * 1024 * 1024) { int index = history.FindLastIndex(x => !x.IsImage); if (index < 0) break; bytes -= Encoding.UTF8.GetByteCount(history[index].Text); history.RemoveAt(index); removed++; }
        if (removed > 0) { RefreshHistory(); _ = PersistHistory(); }
    }
    void RefreshHistory()
    {
        var selected = (list.SelectedItem as HistoryItem)?.Id;
        list.BeginUpdate(); list.Items.Clear();
        foreach (var item in history.Where(x => (x.Summary + " " + x.Source).Contains(search.Text, StringComparison.OrdinalIgnoreCase))) list.Items.Add(item);
        for (int i = 0; i < list.Items.Count; i++) if (((HistoryItem)list.Items[i]).Id == selected) list.SelectedIndex = i;
        list.EndUpdate();
        historyCount.Text = $"24 小时内 · {history.Count} 条";
        emptyHistory.Text = history.Count == 0 ? "还没有记录\n复制文字或图片，它会自动出现在这里。" : "没有找到匹配的记录";
        emptyHistory.Visible = list.Items.Count == 0;
        list.Visible = !emptyHistory.Visible;
    }
    async Task PersistHistory()
    {
        await gate.WaitAsync();
        try { var snapshot = history.ToList(); await Task.Run(() => { Storage.SaveHistory(snapshot); imageVault?.Prune(Wire.Now); }); }
        catch { status.Text = "本机历史保存失败。"; }
        finally { gate.Release(); }
    }
    async Task ClearHistory()
    {
        epoch++; holdUntil = Wire.Now + 10000;
        await gate.WaitAsync();
        try { await Task.Run(() => imageVault?.ClearHistory(Wire.Now)); history.Clear(); RefreshHistory(); await Task.Run(() => Storage.SaveHistory([])); }
        catch { status.Text = "本机历史清理失败；未发送图片仍保留在队列中。"; }
        finally { gate.Release(); }
    }
    async Task<Bitmap?> SelectedBitmap(HistoryItem item)
    {
        if (item.Image == null || imageVault == null) return null;
        await gate.WaitAsync();
        try { var png = await Task.Run(() => imageVault.Read(item.Image)); return ClipboardImages.Decode(png); }
        finally { gate.Release(); }
    }
    async Task PreviewSelected()
    {
        if (list.SelectedItem is not HistoryItem { IsImage: true } item || item.Expires <= Wire.Now) return;
        try
        {
            using var bitmap = await SelectedBitmap(item); if (bitmap == null || item.Expires <= Wire.Now || IsDisposed) return;
            using var preview = new Form { Text = item.Summary, StartPosition = FormStartPosition.CenterParent, Size = new Size(760, 600), MinimizeBox = false };
            preview.Controls.Add(new PictureBox { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, Image = bitmap, BackColor = Ui.Canvas });
            preview.ShowDialog(this);
        }
        catch { status.Text = "图片已过期或无法解密/校验，未打开预览。"; }
    }
    async Task CopySelected()
    {
        if (list.SelectedItem is not HistoryItem item || item.Expires <= Wire.Now) return;
        epoch++; clipboardActivityCreated = Wire.Now; long request = epoch; holdUntil = Wire.Now + 10000;
        try
        {
            using var bitmap = item.IsImage ? await SelectedBitmap(item) : null;
            if (request != epoch || item.Expires <= Wire.Now || IsDisposed) return;
            writingClipboard = true;
            if (bitmap != null) Clipboard.SetImage(bitmap); else if (!item.IsImage) Clipboard.SetText(item.Text, TextDataFormat.UnicodeText); else return;
            capture.Ignore(GetClipboardSequenceNumber()); epoch++; holdUntil = Wire.Now + 10000; status.Text = "已复制，切回目标窗口按 Ctrl+V。";
        }
        catch (ExternalException) { status.Text = "剪贴板正忙，请再试一次。"; }
        catch { status.Text = "图片已过期或校验失败，未更改剪贴板。"; }
        finally { writingClipboard = false; }
    }
}
