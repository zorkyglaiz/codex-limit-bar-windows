using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace CodexLimitBar;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new TrayAppContext());
    }
}

internal sealed class TrayAppContext : ApplicationContext
{
    private const string AppName = "Codex Limit Bar";
    private const string Version = "1.3.0";
    private readonly string stateDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexLimitBar");
    private readonly string settingsPath;
    private readonly string logPath;

    private readonly NotifyIcon trayIcon;
    private readonly ContextMenuStrip trayMenu;
    private readonly ToolStripMenuItem statusItem;
    private readonly ToolStripMenuItem topMostItem;
    private readonly ToolStripMenuItem startHiddenItem;
    private readonly ToolStripMenuItem autostartItem;
    private readonly List<ToolStripMenuItem> opacityItems = new();

    private readonly FullPanelForm fullForm;
    private readonly MiniWidgetForm miniForm;
    private readonly System.Windows.Forms.Timer uiTimer;
    private readonly System.Windows.Forms.Timer refreshTimer;
    private readonly SemaphoreSlim refreshLock = new(1, 1);

    private AppSettings settings;
    private UsageResult? currentUsage;
    private DateTime lastUpdated = DateTime.MinValue;
    private bool exiting;
    private Icon? dynamicTrayIcon;

    public TrayAppContext()
    {
        Directory.CreateDirectory(stateDir);
        settingsPath = Path.Combine(stateDir, "settings-exe.json");
        logPath = Path.Combine(stateDir, "CodexLimitBar-exe.log");
        settings = AppSettings.Load(settingsPath);

        fullForm = new FullPanelForm();
        miniForm = new MiniWidgetForm();
        ApplyWindowSettings();
        RestoreMiniLocation();

        fullForm.HideRequested += (_, _) => HideAllWindows();
        fullForm.MiniRequested += (_, _) => ShowMini();
        fullForm.RefreshRequested += async (_, _) => await RefreshUsageAsync(true);
        fullForm.TopMostChangedByUser += topMost => SetTopMost(topMost);
        fullForm.FormMovedOrChanged += (_, _) => SaveSettings();

        miniForm.FullRequested += (_, _) => ShowFull();
        miniForm.HideRequested += (_, _) => HideAllWindows();
        miniForm.MovedByUser += (_, _) =>
        {
            settings.MiniX = miniForm.Left;
            settings.MiniY = miniForm.Top;
            SaveSettings();
        };

        trayMenu = new ContextMenuStrip();
        statusItem = new ToolStripMenuItem("Лимиты: ожидание данных") { Enabled = false };
        var fullItem = new ToolStripMenuItem("Полная панель", null, (_, _) => ShowFull());
        var miniItem = new ToolStripMenuItem("Мини-виджет", null, (_, _) => ShowMini());
        var hideItem = new ToolStripMenuItem("Свернуть в трей", null, (_, _) => HideAllWindows());
        var refreshItem = new ToolStripMenuItem("Обновить", null, async (_, _) => await RefreshUsageAsync(true));
        topMostItem = new ToolStripMenuItem("Поверх всех окон") { CheckOnClick = true, Checked = settings.TopMost };
        topMostItem.CheckedChanged += (_, _) => SetTopMost(topMostItem.Checked);

        var opacityMenu = new ToolStripMenuItem("Прозрачность");
        for (var p = 100; p >= 10; p -= 10)
        {
            var item = new ToolStripMenuItem($"{p}%") { Tag = p / 100.0 };
            item.Click += (sender, _) => SetOpacity((double)((ToolStripMenuItem)sender!).Tag!);
            opacityItems.Add(item);
            opacityMenu.DropDownItems.Add(item);
        }

        startHiddenItem = new ToolStripMenuItem("Запускать свернутым в трей") { CheckOnClick = true, Checked = settings.StartHidden };
        startHiddenItem.CheckedChanged += (_, _) =>
        {
            settings.StartHidden = startHiddenItem.Checked;
            SaveSettings();
        };

        autostartItem = new ToolStripMenuItem("Автозапуск с Windows") { CheckOnClick = true, Checked = IsAutostartEnabled() };
        autostartItem.CheckedChanged += (_, _) => SetAutostart(autostartItem.Checked);

        var diagnosticsItem = new ToolStripMenuItem("Открыть журнал диагностики", null, (_, _) => OpenLog());
        var exitItem = new ToolStripMenuItem("Выход", null, (_, _) => ExitApplication());

        trayMenu.Items.AddRange(new ToolStripItem[]
        {
            statusItem,
            new ToolStripSeparator(),
            fullItem,
            miniItem,
            hideItem,
            refreshItem,
            new ToolStripSeparator(),
            topMostItem,
            opacityMenu,
            startHiddenItem,
            autostartItem,
            new ToolStripSeparator(),
            diagnosticsItem,
            exitItem
        });

        trayIcon = new NotifyIcon
        {
            Visible = true,
            Text = AppName,
            ContextMenuStrip = trayMenu,
            Icon = LoadBaseIcon()
        };
        trayIcon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left)
            {
                if (settings.LastVisibleMode == "mini") ShowMini();
                else ShowFull();
            }
        };

        uiTimer = new System.Windows.Forms.Timer { Interval = 1000 };
        uiTimer.Tick += (_, _) => RenderUsage();
        uiTimer.Start();

        refreshTimer = new System.Windows.Forms.Timer { Interval = 180_000 };
        refreshTimer.Tick += async (_, _) => await RefreshUsageAsync(false);
        refreshTimer.Start();

        UpdateOpacityChecks();

        if (!settings.StartHidden)
        {
            if (settings.DisplayMode == "mini") ShowMini();
            else ShowFull();
        }
        else
        {
            HideAllWindows(save: false);
        }

        _ = RefreshUsageAsync(true);
    }

    private Icon LoadBaseIcon()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (!string.IsNullOrWhiteSpace(exe))
            {
                var icon = Icon.ExtractAssociatedIcon(exe);
                if (icon != null) return (Icon)icon.Clone();
            }
        }
        catch { }
        return (Icon)SystemIcons.Application.Clone();
    }

    private void ApplyWindowSettings()
    {
        fullForm.TopMost = settings.TopMost;
        miniForm.TopMost = settings.TopMost;
        fullForm.Opacity = Math.Clamp(settings.Opacity, 0.1, 1.0);
        miniForm.Opacity = Math.Clamp(settings.Opacity, 0.1, 1.0);
    }

    private void RestoreMiniLocation()
    {
        if (settings.MiniX >= 0 && settings.MiniY >= 0)
        {
            var point = new Point(settings.MiniX, settings.MiniY);
            if (Screen.AllScreens.Any(s => s.WorkingArea.Contains(point)))
            {
                miniForm.Location = point;
                return;
            }
        }

        var wa = Screen.PrimaryScreen?.WorkingArea ?? Screen.GetWorkingArea(Point.Empty);
        miniForm.Location = new Point(wa.Right - miniForm.Width - 18, wa.Bottom - miniForm.Height - 18);
    }

    private void ShowFull()
    {
        miniForm.Hide();
        settings.DisplayMode = "full";
        settings.LastVisibleMode = "full";
        ShowAndActivate(fullForm);
        SaveSettings();
    }

    private void ShowMini()
    {
        fullForm.Hide();
        settings.DisplayMode = "mini";
        settings.LastVisibleMode = "mini";
        ShowAndActivate(miniForm);
        SaveSettings();
    }

    private void ShowAndActivate(Form form)
    {
        if (!form.Visible) form.Show();
        if (form.WindowState == FormWindowState.Minimized) form.WindowState = FormWindowState.Normal;
        form.BringToFront();
        form.Activate();

        if (!settings.TopMost)
        {
            form.TopMost = true;
            form.BeginInvoke(new Action(() => form.TopMost = false));
        }
    }

    private void HideAllWindows(bool save = true)
    {
        fullForm.Hide();
        miniForm.Hide();
        settings.DisplayMode = "tray";
        if (save) SaveSettings();
    }

    private void SetTopMost(bool value)
    {
        settings.TopMost = value;
        fullForm.TopMost = value;
        miniForm.TopMost = value;
        fullForm.SetPinState(value);
        if (topMostItem.Checked != value) topMostItem.Checked = value;
        SaveSettings();
    }

    private void SetOpacity(double opacity)
    {
        opacity = Math.Clamp(opacity, 0.1, 1.0);
        settings.Opacity = opacity;
        fullForm.Opacity = opacity;
        miniForm.Opacity = opacity;
        UpdateOpacityChecks();
        SaveSettings();
    }

    private void UpdateOpacityChecks()
    {
        foreach (var item in opacityItems)
        {
            var value = (double)item.Tag!;
            item.Checked = Math.Abs(value - settings.Opacity) < 0.001;
        }
    }

    private void SaveSettings()
    {
        try { settings.Save(settingsPath); } catch { }
    }

    private static string AutostartName => "CodexLimitBar";

    private bool IsAutostartEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", false);
            var value = key?.GetValue(AutostartName) as string;
            return !string.IsNullOrWhiteSpace(value);
        }
        catch { return false; }
    }

    private void SetAutostart(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true)
                            ?? Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
            if (enabled)
            {
                var exe = Environment.ProcessPath ?? Application.ExecutablePath;
                key.SetValue(AutostartName, $"\"{exe}\"");
            }
            else
            {
                key.DeleteValue(AutostartName, false);
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Не удалось изменить автозапуск.\n\n{ex.Message}", AppName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private void OpenLog()
    {
        try
        {
            if (!File.Exists(logPath)) File.WriteAllText(logPath, "Журнал пока пуст.\r\n", Encoding.UTF8);
            Process.Start(new ProcessStartInfo(logPath) { UseShellExecute = true });
        }
        catch { }
    }

    private async Task RefreshUsageAsync(bool manual)
    {
        if (!await refreshLock.WaitAsync(0)) return;
        try
        {
            fullForm.SetSourceText(manual ? "обновление…" : "получаю данные…");
            var result = await CodexUsageReader.ReadAsync(LogAsync);
            if (result != null && result.Status == "ok")
            {
                currentUsage = result;
                lastUpdated = DateTime.Now;
            }
            else if (currentUsage == null)
            {
                fullForm.SetSourceText("лимиты не найдены");
            }
        }
        catch (Exception ex)
        {
            await LogAsync("refresh exception: " + ex.Message);
        }
        finally
        {
            refreshLock.Release();
            RenderUsage();
        }
    }

    private Task LogAsync(string line)
    {
        try
        {
            File.AppendAllText(logPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {line}\r\n", Encoding.UTF8);
        }
        catch { }
        return Task.CompletedTask;
    }

    private void RenderUsage()
    {
        if (currentUsage == null || currentUsage.Status != "ok")
        {
            fullForm.Render(null, lastUpdated);
            miniForm.Render(null);
            statusItem.Text = "Лимиты: ожидание данных";
            SetTrayTooltip("Codex Limit Bar - ожидание данных");
            UpdateDynamicTrayIcon(null);
            return;
        }

        fullForm.Render(currentUsage, lastUpdated);
        miniForm.Render(currentUsage);

        var five = currentUsage.FiveHour ?? currentUsage.FirstWindow;
        var weekly = currentUsage.Weekly;
        var fivePct = five?.RemainingPercent;
        var weekPct = weekly?.RemainingPercent;

        statusItem.Text = fivePct.HasValue
            ? $"Лимиты: 5ч {Math.Round(fivePct.Value):0}% · нед {(weekPct.HasValue ? Math.Round(weekPct.Value).ToString("0") + "%" : "-")}" 
            : "Лимиты: данные получены";

        var tipParts = new List<string>();
        if (five != null) tipParts.Add($"5ч {Math.Round(five.RemainingPercent):0}% · {ShortReset(five.ResetAtEpoch)}");
        if (weekly != null) tipParts.Add($"Нед {Math.Round(weekly.RemainingPercent):0}% · {WeeklyReset(weekly.ResetAtEpoch)}");
        SetTrayTooltip(string.Join(" | ", tipParts));
        UpdateDynamicTrayIcon(fivePct);
    }

    private void SetTrayTooltip(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) text = AppName;
        if (text.Length > 63) text = text[..63];
        try { trayIcon.Text = text; } catch { }
    }

    private void UpdateDynamicTrayIcon(double? percent)
    {
        try
        {
            using var bmp = new Bitmap(32, 32);
            using var g = Graphics.FromImage(bmp);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var dark = new SolidBrush(Color.FromArgb(45, 45, 48));
            g.FillEllipse(dark, 2, 2, 28, 28);
            using var trackPen = new Pen(Color.FromArgb(80, 80, 85), 3.2f)
            {
                StartCap = LineCap.Round,
                EndCap = LineCap.Round
            };
            g.DrawArc(trackPen, 4.5f, 4.5f, 23, 23, -90, 359.9f);

            if (percent.HasValue)
            {
                var p = Math.Clamp(percent.Value, 0, 100);
                using var quotaPen = new Pen(QuotaColors.ForPercent(p), 3.2f)
                {
                    StartCap = LineCap.Round,
                    EndCap = LineCap.Round
                };
                if (p > 0) g.DrawArc(quotaPen, 4.5f, 4.5f, 23, 23, -90, (float)(360 * p / 100.0));
            }

            using var font = new Font("Segoe UI", 10, FontStyle.Bold, GraphicsUnit.Pixel);
            using var brush = new SolidBrush(Color.White);
            var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString("C", font, brush, new RectangleF(7, 7, 18, 18), sf);

            var hIcon = bmp.GetHicon();
            try
            {
                using var temp = Icon.FromHandle(hIcon);
                var clone = (Icon)temp.Clone();
                var old = dynamicTrayIcon;
                dynamicTrayIcon = clone;
                trayIcon.Icon = clone;
                old?.Dispose();
            }
            finally
            {
                DestroyIcon(hIcon);
            }
        }
        catch { }
    }

    private static string ShortReset(long? epoch)
    {
        if (!epoch.HasValue || epoch.Value <= 0) return "сброс ?";
        var reset = DateTimeOffset.FromUnixTimeSeconds(epoch.Value).LocalDateTime;
        var left = reset - DateTime.Now;
        if (left.TotalSeconds <= 0) return "сейчас";
        if (left.TotalHours >= 1) return $"{(int)left.TotalHours}ч {left.Minutes}м";
        return $"{Math.Max(0, left.Minutes)}м";
    }

    private static string WeeklyReset(long? epoch)
    {
        if (!epoch.HasValue || epoch.Value <= 0) return "сброс ?";
        return DateTimeOffset.FromUnixTimeSeconds(epoch.Value).LocalDateTime.ToString("dd.MM HH:mm");
    }

    private void ExitApplication()
    {
        exiting = true;
        SaveSettings();
        uiTimer.Stop();
        refreshTimer.Stop();
        trayIcon.Visible = false;
        dynamicTrayIcon?.Dispose();
        trayIcon.Dispose();
        trayMenu.Dispose();
        fullForm.AllowClose = true;
        miniForm.AllowClose = true;
        fullForm.Close();
        miniForm.Close();
        ExitThread();
    }

    protected override void ExitThreadCore()
    {
        if (!exiting)
        {
            HideAllWindows();
            return;
        }
        base.ExitThreadCore();
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern bool DestroyIcon(IntPtr handle);
}

internal sealed class FullPanelForm : Form
{
    public event EventHandler? HideRequested;
    public event EventHandler? MiniRequested;
    public event EventHandler? RefreshRequested;
    public event Action<bool>? TopMostChangedByUser;
    public event EventHandler? FormMovedOrChanged;

    public bool AllowClose { get; set; }

    private readonly Label sourceLabel;
    private readonly Label mainPercent;
    private readonly QuotaBar mainBar;
    private readonly Label mainReset;
    private readonly Label weeklyLabel;
    private readonly Label weeklyReset;
    private readonly QuotaBar weeklyBar;
    private readonly Label updatedLabel;
    private readonly Button pinButton;
    private Point dragOffset;
    private bool dragging;

    public FullPanelForm()
    {
        Text = "Codex Limit Bar";
        ClientSize = new Size(420, 260);
        FormBorderStyle = FormBorderStyle.None;
        BackColor = Theme.Bg;
        ForeColor = Theme.Text;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        AutoScaleMode = AutoScaleMode.Dpi;

        var wa = Screen.PrimaryScreen?.WorkingArea ?? Screen.GetWorkingArea(Point.Empty);
        Location = new Point(wa.Right - Width - 18, wa.Bottom - Height - 18);

        var title = MakeLabel("CODEX LIMIT", 16, 13, 250, 22, 10.5f, FontStyle.Bold, Theme.Text);
        sourceLabel = MakeLabel("запуск…", 16, 37, 290, 20, 8.5f, FontStyle.Regular, Theme.Muted);

        var mini = MakeButton("◉", 278, 6, 34, 30, 11f);
        mini.Click += (_, _) => MiniRequested?.Invoke(this, EventArgs.Empty);
        var refresh = MakeButton("↻", 312, 6, 34, 30, 12f);
        refresh.Click += (_, _) => RefreshRequested?.Invoke(this, EventArgs.Empty);
        pinButton = MakeButton("◆", 346, 6, 34, 30, 10f);
        pinButton.Click += (_, _) => TopMostChangedByUser?.Invoke(!TopMost);
        var close = MakeButton("×", 380, 6, 34, 30, 13f);
        close.Click += (_, _) => HideRequested?.Invoke(this, EventArgs.Empty);

        _ = MakeLabel("5 ЧАСОВ", 18, 66, 190, 18, 8.5f, FontStyle.Bold, Theme.Muted);
        mainPercent = MakeLabel("—", 16, 82, 300, 42, 24f, FontStyle.Bold, Theme.Text);
        mainBar = new QuotaBar { Location = new Point(18, 126), Size = new Size(384, 8) };
        Controls.Add(mainBar);
        mainReset = MakeLabel("", 18, 139, 384, 22, 8.5f, FontStyle.Regular, Theme.Muted);

        var divider = new Panel { BackColor = Theme.Divider, Location = new Point(18, 170), Size = new Size(384, 1) };
        Controls.Add(divider);

        _ = MakeLabel("НЕДЕЛЯ", 18, 182, 100, 18, 8.5f, FontStyle.Bold, Theme.Muted);
        weeklyLabel = MakeLabel("—", 18, 199, 160, 24, 12f, FontStyle.Bold, Theme.Text);
        weeklyReset = MakeLabel("", 167, 201, 235, 22, 8.5f, FontStyle.Regular, Theme.Muted, ContentAlignment.MiddleRight);
        weeklyBar = new QuotaBar { Location = new Point(18, 228), Size = new Size(384, 6) };
        Controls.Add(weeklyBar);
        updatedLabel = MakeLabel("", 252, 239, 150, 16, 8f, FontStyle.Regular, Theme.Muted2, ContentAlignment.MiddleRight);

        var toolTip = new ToolTip();
        toolTip.SetToolTip(mini, "Мини-виджет");
        toolTip.SetToolTip(refresh, "Обновить лимиты");
        toolTip.SetToolTip(pinButton, "Поверх всех окон");
        toolTip.SetToolTip(close, "Свернуть в трей");

        foreach (Control c in Controls)
        {
            if (c is Label || ReferenceEquals(c, divider))
            {
                c.MouseDown += DragMouseDown;
                c.MouseMove += DragMouseMove;
                c.MouseUp += DragMouseUp;
            }
        }
        MouseDown += DragMouseDown;
        MouseMove += DragMouseMove;
        MouseUp += DragMouseUp;
        Move += (_, _) => FormMovedOrChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetSourceText(string text) => sourceLabel.Text = text;

    public void SetPinState(bool topMost)
    {
        pinButton.ForeColor = topMost ? Theme.Good : Theme.Muted;
    }

    public void Render(UsageResult? usage, DateTime updated)
    {
        if (usage == null)
        {
            mainPercent.Text = "—";
            mainBar.Percent = 0;
            mainReset.Text = "ожидание данных";
            weeklyLabel.Text = "Неделя: —";
            weeklyReset.Text = "";
            weeklyBar.Percent = 0;
            updatedLabel.Text = "";
            return;
        }

        sourceLabel.Text = string.IsNullOrWhiteSpace(usage.PlanType) ? usage.Source : $"{usage.Source} · {usage.PlanType}";
        var five = usage.FiveHour ?? usage.FirstWindow;
        if (five != null)
        {
            mainPercent.Text = $"{Math.Round(five.RemainingPercent):0}% осталось";
            mainBar.Percent = five.RemainingPercent;
            mainReset.Text = $"{FormatRemaining(five.ResetAtEpoch)} · до {FormatDateTime(five.ResetAtEpoch, "dd.MM HH:mm")}";
        }
        else
        {
            mainPercent.Text = "—";
            mainBar.Percent = 0;
            mainReset.Text = "5-часовой лимит не найден";
        }

        if (usage.Weekly != null)
        {
            weeklyLabel.Text = $"{Math.Round(usage.Weekly.RemainingPercent):0}% осталось";
            weeklyReset.Text = $"сброс {FormatDateTime(usage.Weekly.ResetAtEpoch, "dd.MM HH:mm")}";
            weeklyBar.Percent = usage.Weekly.RemainingPercent;
        }
        else
        {
            weeklyLabel.Text = "Неделя: —";
            weeklyReset.Text = "";
            weeklyBar.Percent = 0;
        }

        updatedLabel.Text = updated == DateTime.MinValue ? "" : $"обновлено {updated:HH:mm}";
        Invalidate(true);
    }

    private Label MakeLabel(string text, int x, int y, int w, int h, float size, FontStyle style, Color color, ContentAlignment align = ContentAlignment.MiddleLeft)
    {
        var l = new Label
        {
            Text = text,
            Location = new Point(x, y),
            Size = new Size(w, h),
            Font = new Font("Segoe UI", size, style),
            ForeColor = color,
            BackColor = Theme.Bg,
            TextAlign = align,
            AutoSize = false
        };
        Controls.Add(l);
        return l;
    }

    private Button MakeButton(string text, int x, int y, int w, int h, float size)
    {
        var b = new Button
        {
            Text = text,
            Location = new Point(x, y),
            Size = new Size(w, h),
            FlatStyle = FlatStyle.Flat,
            BackColor = Theme.Bg,
            ForeColor = Theme.Muted,
            Font = new Font("Segoe UI Symbol", size),
            Cursor = Cursors.Hand,
            TabStop = false
        };
        b.FlatAppearance.BorderSize = 0;
        Controls.Add(b);
        return b;
    }

    private void DragMouseDown(object? sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        dragging = true;
        dragOffset = new Point(e.X, e.Y);
    }

    private void DragMouseMove(object? sender, MouseEventArgs e)
    {
        if (!dragging || e.Button != MouseButtons.Left) return;
        var p = PointToScreen(e.Location);
        Location = new Point(p.X - dragOffset.X, p.Y - dragOffset.Y);
    }

    private void DragMouseUp(object? sender, MouseEventArgs e) => dragging = false;

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!AllowClose)
        {
            e.Cancel = true;
            HideRequested?.Invoke(this, EventArgs.Empty);
            return;
        }
        base.OnFormClosing(e);
    }

    private static string FormatRemaining(long? epoch)
    {
        if (!epoch.HasValue || epoch.Value <= 0) return "время сброса неизвестно";
        var reset = DateTimeOffset.FromUnixTimeSeconds(epoch.Value).LocalDateTime;
        var left = reset - DateTime.Now;
        if (left.TotalSeconds <= 0) return "сброс сейчас";
        if (left.TotalDays >= 1) return $"сброс через {(int)Math.Floor(left.TotalDays)} д {left.Hours} ч";
        if (left.TotalHours >= 1) return $"сброс через {(int)Math.Floor(left.TotalHours)} ч {left.Minutes} мин";
        return $"сброс через {Math.Max(0, left.Minutes)} мин {Math.Max(0, left.Seconds)} сек";
    }

    private static string FormatDateTime(long? epoch, string format)
    {
        if (!epoch.HasValue || epoch.Value <= 0) return "?";
        return DateTimeOffset.FromUnixTimeSeconds(epoch.Value).LocalDateTime.ToString(format);
    }
}

internal sealed class MiniWidgetForm : Form
{
    public event EventHandler? FullRequested;
    public event EventHandler? HideRequested;
    public event EventHandler? MovedByUser;
    public bool AllowClose { get; set; }

    private readonly MiniGauge gauge;
    private readonly Label weeklyLabel;
    private readonly Label weeklyReset;
    private Point dragOffset;
    private bool dragging;

    public MiniWidgetForm()
    {
        Text = "Codex Limit Mini";
        ClientSize = new Size(152, 166);
        FormBorderStyle = FormBorderStyle.None;
        BackColor = Theme.Bg;
        ForeColor = Theme.Text;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        AutoScaleMode = AutoScaleMode.Dpi;

        gauge = new MiniGauge { Location = new Point(13, 3), Size = new Size(126, 126), Cursor = Cursors.SizeAll };
        Controls.Add(gauge);
        weeklyLabel = MakeLabel("Неделя —", 6, 127, 140, 20, 9f, FontStyle.Bold, Theme.Text);
        weeklyReset = MakeLabel("", 6, 146, 140, 16, 7.5f, FontStyle.Regular, Theme.Muted);

        var expand = new Button
        {
            Text = "↗",
            Location = new Point(124, 2),
            Size = new Size(24, 22),
            FlatStyle = FlatStyle.Flat,
            BackColor = Theme.Bg,
            ForeColor = Theme.Muted2,
            Font = new Font("Segoe UI Symbol", 8.5f),
            Cursor = Cursors.Hand,
            TabStop = false
        };
        expand.FlatAppearance.BorderSize = 0;
        expand.Click += (_, _) => FullRequested?.Invoke(this, EventArgs.Empty);
        Controls.Add(expand);
        expand.BringToFront();

        gauge.DoubleClick += (_, _) => FullRequested?.Invoke(this, EventArgs.Empty);
        gauge.MouseDown += DragMouseDown;
        gauge.MouseMove += DragMouseMove;
        gauge.MouseUp += DragMouseUp;
        MouseDown += DragMouseDown;
        MouseMove += DragMouseMove;
        MouseUp += DragMouseUp;

        var tip = new ToolTip();
        tip.SetToolTip(gauge, "Перетащите виджет. Двойной клик - полная панель.");
        tip.SetToolTip(expand, "Открыть полную панель");

        SetRoundedRegion();
    }

    public void Render(UsageResult? usage)
    {
        var five = usage?.FiveHour ?? usage?.FirstWindow;
        gauge.Percent = five?.RemainingPercent;
        gauge.ResetText = five == null ? "" : ShortReset(five.ResetAtEpoch);
        if (usage?.Weekly != null)
        {
            weeklyLabel.Text = $"Неделя {Math.Round(usage.Weekly.RemainingPercent):0}%";
            weeklyReset.Text = $"сброс {FormatDateTime(usage.Weekly.ResetAtEpoch)}";
        }
        else
        {
            weeklyLabel.Text = "Неделя —";
            weeklyReset.Text = "";
        }
        gauge.Invalidate();
    }

    private Label MakeLabel(string text, int x, int y, int w, int h, float size, FontStyle style, Color color)
    {
        var l = new Label
        {
            Text = text,
            Location = new Point(x, y),
            Size = new Size(w, h),
            Font = new Font("Segoe UI", size, style),
            ForeColor = color,
            BackColor = Theme.Bg,
            TextAlign = ContentAlignment.MiddleCenter,
            AutoSize = false
        };
        Controls.Add(l);
        return l;
    }

    private void SetRoundedRegion()
    {
        try
        {
            const int radius = 18;
            var d = radius * 2;
            using var path = new GraphicsPath();
            path.AddArc(0, 0, d, d, 180, 90);
            path.AddArc(Width - d, 0, d, d, 270, 90);
            path.AddArc(Width - d, Height - d, d, d, 0, 90);
            path.AddArc(0, Height - d, d, d, 90, 90);
            path.CloseFigure();
            Region = new Region(path);
        }
        catch { }
    }

    private void DragMouseDown(object? sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        dragging = true;
        dragOffset = new Point(e.X, e.Y);
    }

    private void DragMouseMove(object? sender, MouseEventArgs e)
    {
        if (!dragging || e.Button != MouseButtons.Left) return;
        var p = PointToScreen(e.Location);
        Location = new Point(p.X - dragOffset.X, p.Y - dragOffset.Y);
    }

    private void DragMouseUp(object? sender, MouseEventArgs e)
    {
        dragging = false;
        MovedByUser?.Invoke(this, EventArgs.Empty);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!AllowClose)
        {
            e.Cancel = true;
            HideRequested?.Invoke(this, EventArgs.Empty);
            return;
        }
        base.OnFormClosing(e);
    }

    private static string ShortReset(long? epoch)
    {
        if (!epoch.HasValue || epoch.Value <= 0) return "";
        var left = DateTimeOffset.FromUnixTimeSeconds(epoch.Value).LocalDateTime - DateTime.Now;
        if (left.TotalSeconds <= 0) return "сейчас";
        if (left.TotalHours >= 1) return $"{(int)left.TotalHours}ч {left.Minutes}м";
        return $"{Math.Max(0, left.Minutes)}м";
    }

    private static string FormatDateTime(long? epoch)
    {
        if (!epoch.HasValue || epoch.Value <= 0) return "?";
        return DateTimeOffset.FromUnixTimeSeconds(epoch.Value).LocalDateTime.ToString("dd.MM HH:mm");
    }
}

internal sealed class MiniGauge : Control
{
    public double? Percent { get; set; }
    public string ResetText { get; set; } = "";

    public MiniGauge()
    {
        DoubleBuffered = true;
        BackColor = Theme.Bg;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var ringRect = new Rectangle(12, 12, 102, 102);
        var innerRect = new Rectangle(22, 22, 82, 82);
        using var innerBrush = new SolidBrush(Color.FromArgb(29, 29, 33));
        using var trackPen = new Pen(Theme.Track, 8) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        g.FillEllipse(innerBrush, innerRect);
        g.DrawEllipse(trackPen, ringRect);

        var pctText = "—";
        if (Percent.HasValue)
        {
            var p = Math.Clamp(Percent.Value, 0, 100);
            using var quotaPen = new Pen(QuotaColors.ForPercent(p), 8) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            if (p > 0) g.DrawArc(quotaPen, ringRect, -90, (float)(360 * p / 100.0));
            pctText = $"{Math.Round(p):0}%";
        }

        using var captionFont = new Font("Segoe UI", 7.5f, FontStyle.Bold);
        using var pctFont = new Font("Segoe UI", 22f, FontStyle.Bold);
        using var resetFont = new Font("Segoe UI", 7.2f);
        using var captionBrush = new SolidBrush(Theme.Muted);
        using var pctBrush = new SolidBrush(Theme.Text);
        using var resetBrush = new SolidBrush(Theme.Muted);
        using var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        g.DrawString("5 ЧАСОВ", captionFont, captionBrush, new RectangleF(25, 33, 76, 18), fmt);
        g.DrawString(pctText, pctFont, pctBrush, new RectangleF(17, 48, 92, 43), fmt);
        if (!string.IsNullOrWhiteSpace(ResetText))
            g.DrawString(ResetText, resetFont, resetBrush, new RectangleF(23, 88, 80, 17), fmt);
    }
}

internal sealed class QuotaBar : Control
{
    private double percent;
    public double Percent
    {
        get => percent;
        set { percent = Math.Clamp(value, 0, 100); Invalidate(); }
    }

    public QuotaBar()
    {
        DoubleBuffered = true;
        BackColor = Theme.Track;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        e.Graphics.Clear(Theme.Track);
        var width = (int)Math.Round(ClientSize.Width * Percent / 100.0);
        if (width <= 0) return;
        using var brush = new SolidBrush(QuotaColors.ForPercent(Percent));
        e.Graphics.FillRectangle(brush, 0, 0, width, ClientSize.Height);
    }
}

internal static class Theme
{
    public static readonly Color Bg = Color.FromArgb(24, 24, 27);
    public static readonly Color Text = Color.FromArgb(244, 244, 245);
    public static readonly Color Muted = Color.FromArgb(161, 161, 170);
    public static readonly Color Muted2 = Color.FromArgb(113, 113, 122);
    public static readonly Color Track = Color.FromArgb(63, 63, 70);
    public static readonly Color Divider = Color.FromArgb(39, 39, 42);
    public static readonly Color Good = Color.FromArgb(74, 222, 128);
    public static readonly Color Warn = Color.FromArgb(250, 204, 21);
    public static readonly Color Bad = Color.FromArgb(248, 113, 113);
}

internal static class QuotaColors
{
    public static Color ForPercent(double remaining)
    {
        if (remaining <= 20) return Theme.Bad;
        if (remaining <= 50) return Theme.Warn;
        return Theme.Good;
    }
}

internal sealed class AppSettings
{
    public bool TopMost { get; set; } = true;
    public double Opacity { get; set; } = 1.0;
    public bool StartHidden { get; set; }
    public string DisplayMode { get; set; } = "full";
    public string LastVisibleMode { get; set; } = "full";
    public int MiniX { get; set; } = -1;
    public int MiniY { get; set; } = -1;

    public static AppSettings Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return new AppSettings();
            var loaded = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path, Encoding.UTF8));
            if (loaded == null) return new AppSettings();
            loaded.Opacity = Math.Clamp(loaded.Opacity, 0.1, 1.0);
            if (loaded.LastVisibleMode is not ("full" or "mini")) loaded.LastVisibleMode = "full";
            if (loaded.DisplayMode is not ("full" or "mini" or "tray")) loaded.DisplayMode = "full";
            return loaded;
        }
        catch { return new AppSettings(); }
    }

    public void Save(string path)
    {
        var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json, new UTF8Encoding(false));
    }
}

internal sealed class UsageResult
{
    public string Status { get; set; } = "error";
    public string Source { get; set; } = "";
    public string PlanType { get; set; } = "";
    public long ObservedAtEpoch { get; set; }
    public UsageWindow? FiveHour { get; set; }
    public UsageWindow? Weekly { get; set; }
    public UsageWindow? FirstWindow { get; set; }
}

internal sealed class UsageWindow
{
    public double UsedPercent { get; set; }
    public double RemainingPercent { get; set; }
    public long? WindowMinutes { get; set; }
    public long? ResetAtEpoch { get; set; }
}

internal static class CodexUsageReader
{
    public static async Task<UsageResult?> ReadAsync(Func<string, Task> log)
    {
        var launchers = FindLaunchers(log).Take(3).ToList();
        foreach (var launcher in launchers)
        {
            var usage = await ReadFromAppServerAsync(launcher, log);
            if (usage != null) return usage;
        }

        await log("live read unavailable; trying local session fallback");
        return await ReadFromSessionsAsync(log);
    }

    private static IEnumerable<string> FindLaunchers(Func<string, Task> log)
    {
        var found = new List<string>();
        void Add(string? path, string label)
        {
            if (string.IsNullOrWhiteSpace(path)) return;
            try
            {
                path = Path.GetFullPath(path);
                if (!File.Exists(path)) return;
                if (found.Contains(path, StringComparer.OrdinalIgnoreCase)) return;
                found.Add(path);
                _ = log($"{label}: {path}");
            }
            catch { }
        }

        Add(Environment.GetEnvironmentVariable("CODEX_CLI_PATH"), "CODEX_CLI_PATH");

        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var cache = Path.Combine(local, "OpenAI", "Codex", "bin");
        _ = log("Store cache path: " + cache);
        try
        {
            if (Directory.Exists(cache))
            {
                foreach (var file in Directory.EnumerateFiles(cache, "codex.exe", SearchOption.AllDirectories)
                             .Select(p => new FileInfo(p))
                             .OrderByDescending(f => f.LastWriteTimeUtc)
                             .Take(8))
                {
                    Add(file.FullName, "Store backend");
                }
            }
        }
        catch { }

        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        Add(Path.Combine(local, "Programs", "OpenAI", "Codex", "bin", "codex.exe"), "fixed path");
        Add(Path.Combine(appData, "npm", "codex.cmd"), "fixed path");
        Add(Path.Combine(local, "Microsoft", "WinGet", "Links", "codex.exe"), "fixed path");

        var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in pathEnv.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            Add(Path.Combine(dir, "codex.exe"), "PATH");
            Add(Path.Combine(dir, "codex.cmd"), "PATH");
        }

        _ = log($"codex candidates: {found.Count}");
        return found;
    }

    private static async Task<UsageResult?> ReadFromAppServerAsync(string launcher, Func<string, Task> log)
    {
        Process? proc = null;
        try
        {
            var ext = Path.GetExtension(launcher).ToLowerInvariant();
            var psi = new ProcessStartInfo
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            if (ext is ".cmd" or ".bat")
            {
                psi.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
                psi.Arguments = $"/d /s /c \"\"{launcher}\" app-server --listen stdio://\"";
            }
            else
            {
                psi.FileName = launcher;
                psi.Arguments = "app-server --listen stdio://";
            }

            await log("starting app-server: " + launcher);
            proc = new Process { StartInfo = psi };
            if (!proc.Start()) return null;
            _ = Task.Run(async () =>
            {
                try { while (await proc.StandardError.ReadLineAsync() is { } line) await log("stderr: " + line); } catch { }
            });

            var init = JsonSerializer.Serialize(new
            {
                id = 1,
                method = "initialize",
                @params = new
                {
                    clientInfo = new { name = "codex-limit-bar", title = "Codex Limit Bar", version = "1.3.0" },
                    capabilities = new { experimentalApi = false }
                }
            });
            await proc.StandardInput.WriteLineAsync(init);
            await proc.StandardInput.FlushAsync();

            var initReply = await ReadReplyByIdAsync(proc, 1, TimeSpan.FromSeconds(5));
            if (initReply == null || initReply.RootElement.TryGetProperty("error", out _))
            {
                await log("initialize failed or timed out");
                initReply?.Dispose();
                return null;
            }
            initReply.Dispose();
            await log("initialize ok");

            await proc.StandardInput.WriteLineAsync("{\"method\":\"initialized\"}");
            await proc.StandardInput.WriteLineAsync("{\"id\":2,\"method\":\"account/rateLimits/read\"}");
            await proc.StandardInput.FlushAsync();

            var reply = await ReadReplyByIdAsync(proc, 2, TimeSpan.FromSeconds(8));
            if (reply == null)
            {
                await log("rateLimits timeout");
                return null;
            }
            using (reply)
            {
                var root = reply.RootElement;
                if (root.TryGetProperty("error", out var error))
                {
                    await log("rateLimits error: " + error.GetRawText());
                    return null;
                }
                if (!root.TryGetProperty("result", out var result)) return null;
                var snapshot = SelectSnapshot(result);
                if (!snapshot.HasValue) return null;
                var usage = BuildUsage(snapshot.Value, "Codex app-server", DateTimeOffset.Now.ToUnixTimeSeconds());
                if (usage != null) await log("account/rateLimits/read ok");
                return usage;
            }
        }
        catch (Exception ex)
        {
            await log("app-server exception: " + ex.Message);
            return null;
        }
        finally
        {
            if (proc != null)
            {
                try { proc.StandardInput.Close(); } catch { }
                try { if (!proc.HasExited) proc.Kill(true); } catch { }
                proc.Dispose();
            }
        }
    }

    private static async Task<JsonDocument?> ReadReplyByIdAsync(Process proc, int id, TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        try
        {
            while (!cts.IsCancellationRequested)
            {
                var line = await proc.StandardOutput.ReadLineAsync(cts.Token);
                if (line == null) return null;
                if (string.IsNullOrWhiteSpace(line)) continue;
                try
                {
                    var doc = JsonDocument.Parse(line);
                    var root = doc.RootElement;
                    if (root.TryGetProperty("id", out var idEl) && idEl.ToString() == id.ToString()) return doc;
                    doc.Dispose();
                }
                catch { }
            }
        }
        catch (OperationCanceledException) { }
        return null;
    }

    private static JsonElement? SelectSnapshot(JsonElement result)
    {
        if (TryGet(result, "rateLimitsByLimitId", out var byId) && byId.ValueKind == JsonValueKind.Object)
        {
            if (byId.TryGetProperty("codex", out var codex)) return codex.Clone();
        }
        if (TryGet(result, "rateLimits", out var rateLimits)) return rateLimits.Clone();
        return null;
    }

    private static UsageResult? BuildUsage(JsonElement snapshot, string source, long observedAt)
    {
        if (TryGetString(snapshot, out var limitId, "limitId", "limit_id") && !string.IsNullOrWhiteSpace(limitId) && limitId != "codex") return null;
        var windows = new List<UsageWindow>();
        foreach (var slot in new[] { "primary", "secondary" })
        {
            if (TryGet(snapshot, slot, out var el))
            {
                var w = ConvertWindow(el);
                if (w != null) windows.Add(w);
            }
        }
        if (windows.Count == 0)
        {
            var w = ConvertWindow(snapshot);
            if (w != null) windows.Add(w);
        }
        if (windows.Count == 0) return null;

        var five = windows.FirstOrDefault(w => w.WindowMinutes == 300)
                   ?? windows.FirstOrDefault(w => w.WindowMinutes is >= 240 and <= 360);
        var weekly = windows.FirstOrDefault(w => w.WindowMinutes == 10080)
                     ?? windows.FirstOrDefault(w => w.WindowMinutes is >= 9000 and <= 11000);
        TryGetString(snapshot, out var plan, "planType", "plan_type");
        return new UsageResult
        {
            Status = "ok",
            Source = source,
            PlanType = plan ?? "",
            ObservedAtEpoch = observedAt,
            FiveHour = five,
            Weekly = weekly,
            FirstWindow = windows.FirstOrDefault()
        };
    }

    private static UsageWindow? ConvertWindow(JsonElement window)
    {
        if (!TryGetDouble(window, out var used, "usedPercent", "used_percent")) return null;
        long? mins = TryGetLong(window, out var m, "windowDurationMins", "window_minutes") ? m : null;
        long? reset = TryGetLong(window, out var r, "resetsAt", "resets_at") ? r : null;
        used = Math.Clamp(used, 0, 100);
        return new UsageWindow
        {
            UsedPercent = Math.Round(used, 1),
            RemainingPercent = Math.Round(100 - used, 1),
            WindowMinutes = mins,
            ResetAtEpoch = reset
        };
    }

    private static async Task<UsageResult?> ReadFromSessionsAsync(Func<string, Task> log)
    {
        try
        {
            var sessions = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions");
            await log("sessions path: " + sessions);
            if (!Directory.Exists(sessions)) return null;

            var candidates = new List<FileInfo>();
            for (var i = 0; i < 4; i++)
            {
                var d = DateTime.Now.Date.AddDays(-i);
                var folder = Path.Combine(sessions, d.ToString("yyyy"), d.ToString("MM"), d.ToString("dd"));
                if (!Directory.Exists(folder)) continue;
                candidates.AddRange(Directory.EnumerateFiles(folder, "rollout-*.jsonl", SearchOption.TopDirectoryOnly).Select(p => new FileInfo(p)));
            }

            foreach (var file in candidates.OrderByDescending(f => f.LastWriteTimeUtc).Take(8))
            {
                if ((DateTime.Now - file.LastWriteTime).TotalHours > 24) continue;
                var text = await ReadTailAsync(file.FullName, 2 * 1024 * 1024);
                var lines = text.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
                for (var i = lines.Length - 1; i >= 0; i--)
                {
                    var line = lines[i];
                    if (!line.Contains("rate_limits", StringComparison.OrdinalIgnoreCase) && !line.Contains("rateLimits", StringComparison.OrdinalIgnoreCase)) continue;
                    try
                    {
                        using var doc = JsonDocument.Parse(line);
                        var rateLimits = FindRateLimits(doc.RootElement);
                        if (!rateLimits.HasValue) continue;
                        var usage = BuildUsage(rateLimits.Value, "локальная сессия Codex", new DateTimeOffset(file.LastWriteTime).ToUnixTimeSeconds());
                        if (usage != null)
                        {
                            await log("local rate_limits hit: " + file.Name);
                            return usage;
                        }
                    }
                    catch { }
                }
            }
        }
        catch (Exception ex)
        {
            await log("local fallback exception: " + ex.Message);
        }
        return null;
    }

    private static async Task<string> ReadTailAsync(string path, int maxBytes)
    {
        await using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 8192, true);
        if (fs.Length <= 0) return "";
        var count = (int)Math.Min(maxBytes, fs.Length);
        var start = fs.Length - count;
        fs.Seek(start, SeekOrigin.Begin);
        var buffer = new byte[count];
        var read = 0;
        while (read < count)
        {
            var n = await fs.ReadAsync(buffer.AsMemory(read, count - read));
            if (n <= 0) break;
            read += n;
        }
        var text = Encoding.UTF8.GetString(buffer, 0, read);
        if (start > 0)
        {
            var idx = text.IndexOf('\n');
            if (idx >= 0 && idx + 1 < text.Length) text = text[(idx + 1)..];
        }
        return text;
    }

    private static JsonElement? FindRateLimits(JsonElement obj)
    {
        if (TryGet(obj, "rate_limits", out var direct) || TryGet(obj, "rateLimits", out direct)) return direct.Clone();
        if (TryGet(obj, "payload", out var payload))
        {
            if (TryGet(payload, "rate_limits", out var p) || TryGet(payload, "rateLimits", out p)) return p.Clone();
            if (TryGet(payload, "info", out var info))
            {
                if (TryGet(info, "rate_limits", out var i) || TryGet(info, "rateLimits", out i)) return i.Clone();
            }
        }
        return null;
    }

    private static bool TryGet(JsonElement obj, string name, out JsonElement value)
    {
        value = default;
        return obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out value);
    }

    private static bool TryGetString(JsonElement obj, out string? value, params string[] names)
    {
        value = null;
        foreach (var name in names)
        {
            if (!TryGet(obj, name, out var el)) continue;
            if (el.ValueKind == JsonValueKind.String) { value = el.GetString(); return true; }
            value = el.ToString(); return true;
        }
        return false;
    }

    private static bool TryGetDouble(JsonElement obj, out double value, params string[] names)
    {
        value = 0;
        foreach (var name in names)
        {
            if (!TryGet(obj, name, out var el)) continue;
            if (el.ValueKind == JsonValueKind.Number && el.TryGetDouble(out value)) return true;
            if (double.TryParse(el.ToString(), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out value)) return true;
        }
        return false;
    }

    private static bool TryGetLong(JsonElement obj, out long value, params string[] names)
    {
        value = 0;
        foreach (var name in names)
        {
            if (!TryGet(obj, name, out var el)) continue;
            if (el.ValueKind == JsonValueKind.Number && el.TryGetInt64(out value)) return true;
            if (long.TryParse(el.ToString(), out value)) return true;
        }
        return false;
    }
}
