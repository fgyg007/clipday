using System.Drawing.Drawing2D;

namespace ClipDay.Cloud;

static class Ui
{
    public static readonly Color Ink = Color.FromArgb(29, 47, 53);
    public static readonly Color Muted = Color.FromArgb(105, 122, 128);
    public static readonly Color Teal = Color.FromArgb(11, 130, 128);
    public static readonly Color Canvas = Color.FromArgb(244, 248, 249);
    public static readonly Color Border = Color.FromArgb(222, 232, 234);
    public static readonly Color Soft = Color.FromArgb(232, 246, 244);
    public static readonly Icon AppIcon = LoadIcon(48);
    public static readonly Icon TrayIcon = LoadIcon(32);
    static Icon LoadIcon(int size)
    {
        using var stream = typeof(Ui).Assembly.GetManifestResourceStream("ClipDay.Cloud.Assets.ClipDay.ico")
            ?? throw new InvalidOperationException("应用图标缺失，请重新下载完整安装包。");
        using var original = new Icon(stream, size, size);
        return (Icon)original.Clone();
    }
    public static int Px(Control control, int value) => (int)Math.Round(value * control.DeviceDpi / 96d);
    public static Button Button(string text, bool primary = false)
    {
        var button = new Button { Text = text, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            MinimumSize = new Size(0, 36), Padding = new Padding(14, 6, 14, 6), Margin = new Padding(0, 0, 8, 8),
            FlatStyle = FlatStyle.Flat, BackColor = primary ? Teal : Color.White,
            ForeColor = primary ? Color.White : Ink, Cursor = Cursors.Hand, UseVisualStyleBackColor = false };
        button.FlatAppearance.BorderColor = primary ? Teal : Border;
        button.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(9, 112, 112) : Soft;
        return button;
    }
    public static Label Label(string text, bool heading = false) => new() { Text = text, AutoSize = true,
        Dock = DockStyle.Fill, ForeColor = heading ? Ink : Muted,
        Font = new Font("Microsoft YaHei UI", heading ? 11 : 9, heading ? FontStyle.Bold : FontStyle.Regular),
        Margin = new Padding(0, 0, 0, 10) };
    public static TableLayoutPanel Stack(int rows, bool card = false)
    {
        var table = new TableLayoutPanel { ColumnCount = 1, RowCount = rows, Dock = DockStyle.Fill,
            AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, BackColor = card ? Color.White : Color.Transparent,
            Padding = card ? new Padding(20) : Padding.Empty, Margin = card ? new Padding(0, 0, 0, 16) : Padding.Empty };
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (int i = 0; i < rows; i++) table.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        return table;
    }
    public static Control Field(TextBox input)
    {
        input.BorderStyle = BorderStyle.None; input.BackColor = Color.White; input.ForeColor = Ink;
        input.Dock = DockStyle.Fill; input.Margin = Padding.Empty;
        var field = new TableLayoutPanel { ColumnCount = 1, RowCount = 1, AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Fill, BackColor = Color.White,
            Padding = new Padding(12, 10, 12, 10), Margin = new Padding(0, 0, 8, 8), CellBorderStyle = TableLayoutPanelCellBorderStyle.Single };
        field.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        field.RowStyles.Add(new RowStyle(SizeType.AutoSize)); field.Controls.Add(input);
        return field;
    }
}

sealed class HistoryList : ListBox
{
    public HistoryList()
    {
        Dock = DockStyle.Fill; BorderStyle = BorderStyle.None; BackColor = Color.White; ForeColor = Ui.Ink;
        DrawMode = DrawMode.OwnerDrawFixed; IntegralHeight = false; HorizontalScrollbar = false;
        ItemHeight = 74;
    }
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); ItemHeight = Ui.Px(this, 74); }
    protected override void OnDpiChangedAfterParent(EventArgs e) { base.OnDpiChangedAfterParent(e); ItemHeight = Ui.Px(this, 74); }
    protected override void OnDrawItem(DrawItemEventArgs e)
    {
        if (e.Index < 0 || Items[e.Index] is not HistoryItem item) return;
        bool selected = (e.State & DrawItemState.Selected) != 0;
        using var background = new SolidBrush(selected ? Ui.Soft : Color.White); e.Graphics.FillRectangle(background, e.Bounds);
        int pad = Ui.Px(this, 14), top = e.Bounds.Top;
        using var meta = new Font(Font.FontFamily, 8.5f);
        string label = $"{item.Source}  ·  {DateTimeOffset.FromUnixTimeMilliseconds(item.Created).ToLocalTime():HH:mm}";
        var flags = TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine;
        TextRenderer.DrawText(e.Graphics, label, meta, new Rectangle(pad, top + Ui.Px(this, 10), Width - 2 * pad, Ui.Px(this, 20)), selected ? Ui.Teal : Ui.Muted, flags);
        TextRenderer.DrawText(e.Graphics, item.Summary.Replace('\r', ' ').Replace('\n', ' '), Font,
            new Rectangle(pad, top + Ui.Px(this, 33), Width - 2 * pad, Ui.Px(this, 26)), Ui.Ink, flags);
        using var line = new Pen(Ui.Border); e.Graphics.DrawLine(line, pad, e.Bounds.Bottom - 1, Width - pad, e.Bounds.Bottom - 1);
        e.DrawFocusRectangle();
    }
}

sealed class PairDialog : Form
{
    readonly TextBox input = new() { MaxLength = 7, PlaceholderText = "000 000", TextAlign = HorizontalAlignment.Center,
        Font = new Font("Consolas", 28), AccessibleName = "6 位配对码" };
    public string Code => input.Text;
    public PairDialog()
    {
        SuspendLayout(); AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi;
        Text = "配对另一台电脑"; Icon = Ui.AppIcon; Font = new Font("Microsoft YaHei UI", 10);
        BackColor = Color.White; ForeColor = Ui.Ink; StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false; ShowInTaskbar = false;
        ClientSize = new Size(440, 270); AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
        var layout = Ui.Stack(5); layout.Padding = new Padding(24);
        layout.MinimumSize = new Size(440, 0);
        layout.Controls.Add(Ui.Label("输入 6 位配对码", true), 0, 0);
        layout.Controls.Add(Ui.Label("查看另一台电脑的数字，在倒计时结束前输入。"), 0, 1);
        layout.Controls.Add(Ui.Field(input), 0, 2);
        layout.Controls.Add(Ui.Label("两台电脑需要选择同一个 NAS 文件夹。"), 0, 3);
        var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, WrapContents = false, Margin = new Padding(0, 8, 0, 0) };
        var ok = Ui.Button("配对", true); ok.DialogResult = DialogResult.OK;
        var cancel = Ui.Button("取消"); cancel.DialogResult = DialogResult.Cancel;
        actions.Controls.AddRange([ok, cancel]); layout.Controls.Add(actions, 0, 4); Controls.Add(layout);
        AcceptButton = ok; CancelButton = cancel; Shown += (_, _) => input.Focus();
        ResumeLayout(true);
    }
}
