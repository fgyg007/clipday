namespace ClipDay.Cloud;

// Never copies credentials automatically. MainForm suppresses capture while this modal is open.
static class DrivePairDialog
{
    static Form Create(string title) => new() { Text = title, Width = 690, Height = 350,
        StartPosition = FormStartPosition.CenterParent, MinimizeBox = false, MaximizeBox = false,
        FormBorderStyle = FormBorderStyle.FixedDialog, Font = new Font("Microsoft YaHei UI", 10) };
    public static string? Enter(IWin32Window owner)
    {
        using var dialog = Create("输入完整配对密钥");
        var hint = new Label { Text = "从首台输入完整 clipday-drive1: 密钥。请先暂停其他剪贴板同步工具。\n若首台的空间文件尚未下载到本机，请等待网盘同步完成后重试。",
            Dock = DockStyle.Top, Height = 65, Padding = new Padding(12) };
        var input = new TextBox { Multiline = true, MaxLength = 2048, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Vertical };
        var ok = new Button { Text = "连接空间", DialogResult = DialogResult.OK, Dock = DockStyle.Bottom, Height = 38 };
        var cancel = new Button { Text = "取消", DialogResult = DialogResult.Cancel, Dock = DockStyle.Bottom, Height = 34 };
        dialog.Controls.Add(input); dialog.Controls.Add(hint); dialog.Controls.Add(ok); dialog.Controls.Add(cancel);
        dialog.AcceptButton = ok; dialog.CancelButton = cancel;
        return dialog.ShowDialog(owner) == DialogResult.OK ? input.Text.Trim() : null;
    }
    public static void Reveal(IWin32Window owner, string bundle)
    {
        using var dialog = Create("配对密钥：仅向自己的另一台电脑展示");
        var hint = new Label { Text = "此密钥可解密此空间内容，无短码有效期。仅通过可信渠道交给自己的电脑。\n不要放进同步文件夹、公开分享或截图上传；请先暂停其他剪贴板同步工具。\n本窗口不提供复制按钮。关闭后可用“配对另一台电脑”再次查看。",
            Dock = DockStyle.Top, Height = 95, Padding = new Padding(12) };
        // Label, not selectable TextBox: avoid accidental clipboard replication of the secret.
        var wrapped = string.Join("\n", Enumerable.Range(0, (bundle.Length + 63) / 64).Select(i => bundle.Substring(i * 64, Math.Min(64, bundle.Length - i * 64))));
        var display = new Label { Text = wrapped, Font = new Font(FontFamily.GenericMonospace, 9), AutoSize = false, Dock = DockStyle.Fill, Padding = new Padding(12), UseMnemonic = false };
        var close = new Button { Text = "关闭密钥", DialogResult = DialogResult.OK, Dock = DockStyle.Bottom, Height = 38 };
        dialog.Controls.Add(display); dialog.Controls.Add(hint); dialog.Controls.Add(close);
        dialog.AcceptButton = close; dialog.CancelButton = close;
        dialog.ShowDialog(owner);
        display.Text = "";
    }
}
