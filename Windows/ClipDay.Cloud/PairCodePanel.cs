using ClipDay.Sync;
using System.Drawing.Drawing2D;

namespace ClipDay.Cloud;
sealed class PairCodePanel : Control
{
    string code = "", message = "";
    long expires;
    public PairCodePanel() { DoubleBuffered = true; BackColor = Ui.Soft; Padding = new Padding(14); }
    public void ShowEvent(PairEvent ev)
    {
        code = ev.Type == "offer" ? ev.Code ?? "" : "";
        expires = ev.Expires; message = ev.Message ?? "";
        Height = Ui.Px(this, code.Length == 6 ? 110 : ev.Type == "success" ? 44 : 64);
        Visible = true; Invalidate();
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        int seconds = Math.Max(0, (int)Math.Ceiling((expires - Wire.Now) / 1000d));
        var teal = Ui.Teal;
        int P(int value) => Ui.Px(this, value);
        if (code.Length == 6 && seconds > 0)
        {
            using var font = new Font("Consolas", 30, FontStyle.Bold);
            TextRenderer.DrawText(e.Graphics, code[..3] + " " + code[3..], font, new Point(P(14), P(8)), teal);
            var ring = new Rectangle(Width - P(78), P(12), P(54), P(54));
            using var track = new Pen(Color.FromArgb(200, 230, 229), P(4));
            using var progress = new Pen(teal, P(4)) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            e.Graphics.DrawEllipse(track, ring);
            e.Graphics.DrawArc(progress, ring, -90, Math.Min(360, seconds * 3));
            TextRenderer.DrawText(e.Graphics, $"{seconds / 60}:{seconds % 60:00}", Font, ring, ForeColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            TextRenderer.DrawText(e.Graphics, message + " · 2 分钟有效 · 无需复制", Font, new Rectangle(P(14), P(76), Width - P(28), P(30)), Color.DimGray, TextFormatFlags.EndEllipsis);
            AccessibleName = "配对码 " + code; AccessibleDescription = $"剩余 {seconds} 秒";
        }
        else
        {
            var text = code.Length > 0 ? "配对码已过期，点击重新生成" : message;
            TextRenderer.DrawText(e.Graphics, text, Font, new Rectangle(P(14), P(8), Width - P(28), Height - P(16)), teal, TextFormatFlags.WordBreak | TextFormatFlags.VerticalCenter);
            AccessibleName = text; AccessibleDescription = "";
        }
    }
}
