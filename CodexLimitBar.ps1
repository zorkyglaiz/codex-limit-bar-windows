# Codex Limit Bar for Windows
# v1.2.0
# Read-only usage monitor. UI never waits for Codex synchronously.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppName = 'Codex Limit Bar'
$script:Version = '1.2.0'
$script:CurrentUsage = $null
$script:LastRefresh = [datetime]::MinValue
$script:ProbeProcess = $null
$script:ProbeStartedAt = [datetime]::MinValue
$script:ProbeFileStamp = [datetime]::MinValue
$script:Exiting = $false
$script:dragging = $false
$script:dragStart = New-Object Drawing.Point(0,0)
$script:TrayIcon = $null
$script:LastTrayPercent = -999
$script:miniDragging = $false
$script:miniDragStart = New-Object Drawing.Point(0,0)

$script:MainScriptPath = $MyInvocation.MyCommand.Path
$script:AppDir = Split-Path -Parent $script:MainScriptPath
$script:ProbeScript = Join-Path $script:AppDir 'CodexLimitProbe.ps1'
$script:StateDir = Join-Path $env:LOCALAPPDATA 'CodexLimitBar'
$script:ProbeOutput = Join-Path $script:StateDir 'usage.json'
$script:ProbeStatus = Join-Path $script:StateDir 'status.txt'
$script:SettingsPath = Join-Path $script:StateDir 'settings.json'
$script:StartupShortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Codex Limit Bar.lnk'
if (-not (Test-Path -LiteralPath $script:StateDir)) {
    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
}

# Persistent UI preferences. They live in LocalAppData and survive app updates.
$script:Settings = [ordered]@{
    TopMost = $true
    Opacity = 1.0
    StartHidden = $false
    DisplayMode = 'full'
    LastVisibleMode = 'full'
    MiniX = -1
    MiniY = -1
}

function Load-Settings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:SettingsPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $j = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $j.TopMost) { $script:Settings.TopMost = [bool]$j.TopMost }
        if ($null -ne $j.Opacity) {
            $op = [double]$j.Opacity
            if ($op -ge 0.10 -and $op -le 1.0) { $script:Settings.Opacity = $op }
        }
        if ($null -ne $j.StartHidden) { $script:Settings.StartHidden = [bool]$j.StartHidden }
        if ($null -ne $j.DisplayMode -and @('full','mini','tray') -contains [string]$j.DisplayMode) { $script:Settings.DisplayMode = [string]$j.DisplayMode }
        if ($null -ne $j.LastVisibleMode -and @('full','mini') -contains [string]$j.LastVisibleMode) { $script:Settings.LastVisibleMode = [string]$j.LastVisibleMode }
        if ($null -ne $j.MiniX) { $script:Settings.MiniX = [int]$j.MiniX }
        if ($null -ne $j.MiniY) { $script:Settings.MiniY = [int]$j.MiniY }
    } catch { }
}

function Save-Settings {
    try {
        $obj = [ordered]@{
            TopMost = [bool]$form.TopMost
            Opacity = [double]$form.Opacity
            StartHidden = [bool]$script:Settings.StartHidden
            DisplayMode = [string]$script:Settings.DisplayMode
            LastVisibleMode = [string]$script:Settings.LastVisibleMode
            MiniX = [int]$script:Settings.MiniX
            MiniY = [int]$script:Settings.MiniY
        }
        $obj | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    } catch { }
}

Load-Settings

function Convert-EpochToLocal($value) {
    if ($null -eq $value) { return $null }
    try {
        $seconds = [int64]$value
        if ($seconds -le 0) { return $null }
        return [DateTimeOffset]::FromUnixTimeSeconds($seconds).LocalDateTime
    } catch { return $null }
}

function Get-RemainingText($resetEpoch) {
    $resetAt = Convert-EpochToLocal $resetEpoch
    if ($null -eq $resetAt) { return 'время сброса неизвестно' }
    $left = $resetAt - [datetime]::Now
    if ($left.TotalSeconds -le 0) { return 'сброс сейчас' }
    if ($left.TotalDays -ge 1) {
        return ('сброс через {0} д {1} ч' -f [math]::Floor($left.TotalDays), $left.Hours)
    }
    if ($left.TotalHours -ge 1) {
        return ('сброс через {0} ч {1} мин' -f [math]::Floor($left.TotalHours), $left.Minutes)
    }
    return ('сброс через {0} мин {1} сек' -f [math]::Max(0, $left.Minutes), [math]::Max(0, $left.Seconds))
}

function Read-ProbeResult([bool]$allowOld) {
    if (-not (Test-Path -LiteralPath $script:ProbeOutput)) { return $null }
    try {
        $item = Get-Item -LiteralPath $script:ProbeOutput -ErrorAction Stop
        if ($allowOld -and (([datetime]::Now - $item.LastWriteTime).TotalMinutes -gt 10)) { return $null }
        if (-not $allowOld) {
            if ($item.LastWriteTime -le $script:ProbeFileStamp) { return $null }
            $script:ProbeFileStamp = $item.LastWriteTime
        }
        $raw = Get-Content -LiteralPath $script:ProbeOutput -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}

# ---------- UI ----------
$bg = [Drawing.Color]::FromArgb(24, 24, 27)
$text = [Drawing.Color]::FromArgb(244, 244, 245)
$muted = [Drawing.Color]::FromArgb(161, 161, 170)
$muted2 = [Drawing.Color]::FromArgb(113, 113, 122)
$track = [Drawing.Color]::FromArgb(63, 63, 70)
$dividerColor = [Drawing.Color]::FromArgb(39, 39, 42)
$good = [Drawing.Color]::FromArgb(74, 222, 128)
$warn = [Drawing.Color]::FromArgb(250, 204, 21)
$bad = [Drawing.Color]::FromArgb(248, 113, 113)

$form = New-Object System.Windows.Forms.Form
$form.Text = $script:AppName
$form.ClientSize = New-Object Drawing.Size(420, 260)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.BackColor = $bg
$form.ForeColor = $text
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.TopMost = [bool]$script:Settings.TopMost
$form.Opacity = [double]$script:Settings.Opacity
$form.ShowInTaskbar = $false
$form.Padding = New-Object System.Windows.Forms.Padding(14)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object Drawing.Point(($wa.Right - $form.Width - 18), ($wa.Bottom - $form.Height - 18))

$title = New-Object System.Windows.Forms.Label
$title.Text = 'CODEX LIMIT'
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 10.5)
$title.ForeColor = $text
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(16, 13)
$form.Controls.Add($title)

$sourceLabel = New-Object System.Windows.Forms.Label
$sourceLabel.Text = 'запуск…'
$sourceLabel.Font = New-Object Drawing.Font('Segoe UI', 8.5)
$sourceLabel.ForeColor = $muted
$sourceLabel.AutoSize = $false
$sourceLabel.Size = New-Object Drawing.Size(300, 20)
$sourceLabel.Location = New-Object Drawing.Point(16, 37)
$form.Controls.Add($sourceLabel)

$closeBtn = New-Object System.Windows.Forms.Button
$closeBtn.Text = '×'
$closeBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$closeBtn.FlatAppearance.BorderSize = 0
$closeBtn.BackColor = $bg
$closeBtn.ForeColor = $muted
$closeBtn.Font = New-Object Drawing.Font('Segoe UI', 13)
$closeBtn.Size = New-Object Drawing.Size(34, 30)
$closeBtn.Location = New-Object Drawing.Point(380, 6)
$closeBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($closeBtn)

$miniBtn = New-Object System.Windows.Forms.Button
$miniBtn.Text = '◉'
$miniBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$miniBtn.FlatAppearance.BorderSize = 0
$miniBtn.BackColor = $bg
$miniBtn.ForeColor = $muted
$miniBtn.Font = New-Object Drawing.Font('Segoe UI Symbol', 11)
$miniBtn.Size = New-Object Drawing.Size(34, 30)
$miniBtn.Location = New-Object Drawing.Point(278, 6)
$miniBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($miniBtn)

$refreshBtn = New-Object System.Windows.Forms.Button
$refreshBtn.Text = '↻'
$refreshBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$refreshBtn.FlatAppearance.BorderSize = 0
$refreshBtn.BackColor = $bg
$refreshBtn.ForeColor = $muted
$refreshBtn.Font = New-Object Drawing.Font('Segoe UI', 12)
$refreshBtn.Size = New-Object Drawing.Size(34, 30)
$refreshBtn.Location = New-Object Drawing.Point(312, 6)
$refreshBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($refreshBtn)

$pinBtn = New-Object System.Windows.Forms.Button
$pinBtn.Text = '📌'
$pinBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$pinBtn.FlatAppearance.BorderSize = 0
$pinBtn.BackColor = $bg
$pinBtn.ForeColor = if ($form.TopMost) { $good } else { $muted }
$pinBtn.Font = New-Object Drawing.Font('Segoe UI Emoji', 10)
$pinBtn.Size = New-Object Drawing.Size(34, 30)
$pinBtn.Location = New-Object Drawing.Point(346, 6)
$pinBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($pinBtn)

# Primary quota section. Give labels enough vertical space so Windows DPI scaling
# cannot make the caption collide with the large percentage text.
$mainCaption = New-Object System.Windows.Forms.Label
$mainCaption.Text = '5 ЧАСОВ'
$mainCaption.Font = New-Object Drawing.Font('Segoe UI Semibold', 8.5)
$mainCaption.ForeColor = $muted
$mainCaption.AutoSize = $false
$mainCaption.Size = New-Object Drawing.Size(190, 18)
$mainCaption.Location = New-Object Drawing.Point(18, 66)
$form.Controls.Add($mainCaption)

$mainPercent = New-Object System.Windows.Forms.Label
$mainPercent.Text = '—'
$mainPercent.Font = New-Object Drawing.Font('Segoe UI Semibold', 24)
$mainPercent.ForeColor = $text
$mainPercent.AutoSize = $false
$mainPercent.Size = New-Object Drawing.Size(250, 42)
$mainPercent.Location = New-Object Drawing.Point(16, 82)
$form.Controls.Add($mainPercent)

$trackPanel = New-Object System.Windows.Forms.Panel
$trackPanel.BackColor = $track
$trackPanel.Size = New-Object Drawing.Size(384, 8)
$trackPanel.Location = New-Object Drawing.Point(18, 126)
$form.Controls.Add($trackPanel)

$fillPanel = New-Object System.Windows.Forms.Panel
$fillPanel.BackColor = $good
$fillPanel.Size = New-Object Drawing.Size(0, 8)
$fillPanel.Location = New-Object Drawing.Point(0, 0)
$trackPanel.Controls.Add($fillPanel)

$resetLabel = New-Object System.Windows.Forms.Label
$resetLabel.Text = 'ожидание данных'
$resetLabel.Font = New-Object Drawing.Font('Segoe UI', 9)
$resetLabel.ForeColor = $muted
$resetLabel.AutoSize = $false
$resetLabel.Size = New-Object Drawing.Size(384, 20)
$resetLabel.Location = New-Object Drawing.Point(18, 141)
$form.Controls.Add($resetLabel)

$divider = New-Object System.Windows.Forms.Panel
$divider.BackColor = $dividerColor
$divider.Size = New-Object Drawing.Size(384, 1)
$divider.Location = New-Object Drawing.Point(18, 171)
$form.Controls.Add($divider)

$weeklyCaption = New-Object System.Windows.Forms.Label
$weeklyCaption.Text = 'НЕДЕЛЯ'
$weeklyCaption.Font = New-Object Drawing.Font('Segoe UI Semibold', 8.5)
$weeklyCaption.ForeColor = $muted
$weeklyCaption.AutoSize = $false
$weeklyCaption.Size = New-Object Drawing.Size(100, 18)
$weeklyCaption.Location = New-Object Drawing.Point(18, 182)
$form.Controls.Add($weeklyCaption)

$weeklyLabel = New-Object System.Windows.Forms.Label
$weeklyLabel.Text = '—'
$weeklyLabel.Font = New-Object Drawing.Font('Segoe UI Semibold', 12)
$weeklyLabel.ForeColor = $text
$weeklyLabel.AutoSize = $false
$weeklyLabel.Size = New-Object Drawing.Size(150, 24)
$weeklyLabel.Location = New-Object Drawing.Point(18, 199)
$form.Controls.Add($weeklyLabel)

$weeklyResetLabel = New-Object System.Windows.Forms.Label
$weeklyResetLabel.Text = ''
$weeklyResetLabel.Font = New-Object Drawing.Font('Segoe UI', 8.5)
$weeklyResetLabel.ForeColor = $muted
$weeklyResetLabel.AutoSize = $false
$weeklyResetLabel.Size = New-Object Drawing.Size(235, 22)
$weeklyResetLabel.Location = New-Object Drawing.Point(167, 201)
$weeklyResetLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$form.Controls.Add($weeklyResetLabel)

$weeklyTrackPanel = New-Object System.Windows.Forms.Panel
$weeklyTrackPanel.BackColor = $track
$weeklyTrackPanel.Size = New-Object Drawing.Size(384, 6)
$weeklyTrackPanel.Location = New-Object Drawing.Point(18, 228)
$form.Controls.Add($weeklyTrackPanel)

$weeklyFillPanel = New-Object System.Windows.Forms.Panel
$weeklyFillPanel.BackColor = $good
$weeklyFillPanel.Size = New-Object Drawing.Size(0, 6)
$weeklyFillPanel.Location = New-Object Drawing.Point(0, 0)
$weeklyTrackPanel.Controls.Add($weeklyFillPanel)

$updatedLabel = New-Object System.Windows.Forms.Label
$updatedLabel.Text = ''
$updatedLabel.Font = New-Object Drawing.Font('Segoe UI', 8)
$updatedLabel.ForeColor = $muted2
$updatedLabel.AutoSize = $false
$updatedLabel.Size = New-Object Drawing.Size(150, 16)
$updatedLabel.Location = New-Object Drawing.Point(252, 239)
$updatedLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$form.Controls.Add($updatedLabel)

# Compact floating widget: a circular 5-hour gauge plus a small weekly line.
# It is intentionally separate from the full panel, so the user can keep only
# the important quota visible without giving up the tray icon or background refresh.
$miniForm = New-Object System.Windows.Forms.Form
$miniForm.Text = 'Codex Limit Mini'
$miniForm.ClientSize = New-Object Drawing.Size(152, 166)
$miniForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$miniForm.BackColor = $bg
$miniForm.ForeColor = $text
$miniForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$miniForm.TopMost = [bool]$script:Settings.TopMost
$miniForm.Opacity = [double]$script:Settings.Opacity
$miniForm.ShowInTaskbar = $false
$miniForm.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$miniGauge = New-Object System.Windows.Forms.PictureBox
$miniGauge.BackColor = $bg
$miniGauge.Size = New-Object Drawing.Size(126, 126)
$miniGauge.Location = New-Object Drawing.Point(13, 3)
$miniGauge.Cursor = [System.Windows.Forms.Cursors]::SizeAll
$miniForm.Controls.Add($miniGauge)

$miniWeeklyLabel = New-Object System.Windows.Forms.Label
$miniWeeklyLabel.Text = 'Неделя —'
$miniWeeklyLabel.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
$miniWeeklyLabel.ForeColor = $text
$miniWeeklyLabel.AutoSize = $false
$miniWeeklyLabel.Size = New-Object Drawing.Size(140, 20)
$miniWeeklyLabel.Location = New-Object Drawing.Point(6, 127)
$miniWeeklyLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$miniForm.Controls.Add($miniWeeklyLabel)

$miniWeeklyReset = New-Object System.Windows.Forms.Label
$miniWeeklyReset.Text = ''
$miniWeeklyReset.Font = New-Object Drawing.Font('Segoe UI', 7.5)
$miniWeeklyReset.ForeColor = $muted
$miniWeeklyReset.AutoSize = $false
$miniWeeklyReset.Size = New-Object Drawing.Size(140, 16)
$miniWeeklyReset.Location = New-Object Drawing.Point(6, 146)
$miniWeeklyReset.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$miniForm.Controls.Add($miniWeeklyReset)

$miniExpandBtn = New-Object System.Windows.Forms.Button
$miniExpandBtn.Text = '↗'
$miniExpandBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$miniExpandBtn.FlatAppearance.BorderSize = 0
$miniExpandBtn.BackColor = $bg
$miniExpandBtn.ForeColor = $muted2
$miniExpandBtn.Font = New-Object Drawing.Font('Segoe UI Symbol', 8.5)
$miniExpandBtn.Size = New-Object Drawing.Size(24, 22)
$miniExpandBtn.Location = New-Object Drawing.Point(124, 2)
$miniExpandBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$miniForm.Controls.Add($miniExpandBtn)
$miniExpandBtn.BringToFront()

$uiTip = New-Object System.Windows.Forms.ToolTip
$uiTip.SetToolTip($miniBtn, 'Мини-виджет')
$uiTip.SetToolTip($miniExpandBtn, 'Открыть полную панель')
$uiTip.SetToolTip($miniGauge, 'Перетащите виджет. Двойной клик — полная панель.')
$uiTip.SetToolTip($pinBtn, 'Поверх всех окон')
$uiTip.SetToolTip($refreshBtn, 'Обновить лимиты')

$miniGauge.Add_Paint({
    $g = $_.Graphics
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    $cx = 63
    $cy = 63
    $ringRect = New-Object Drawing.Rectangle(12, 12, 102, 102)
    $innerRect = New-Object Drawing.Rectangle(22, 22, 82, 82)
    $trackPen = New-Object Drawing.Pen($track, 8)
    $trackPen.StartCap = [Drawing.Drawing2D.LineCap]::Round
    $trackPen.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $innerBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(29,29,33))
    $g.FillEllipse($innerBrush, $innerRect)
    $g.DrawEllipse($trackPen, $ringRect)

    $remaining = $null
    if ($null -ne $script:CurrentUsage -and $script:CurrentUsage.status -eq 'ok') {
        if ($null -ne $script:CurrentUsage.fiveHour) { $remaining = [double]$script:CurrentUsage.fiveHour.remainingPercent }
        elseif ($null -ne $script:CurrentUsage.firstWindow) { $remaining = [double]$script:CurrentUsage.firstWindow.remainingPercent }
    }

    if ($null -ne $remaining) {
        $remaining = [math]::Max(0, [math]::Min(100, $remaining))
        $quotaPen = New-Object Drawing.Pen((Get-BarColor $remaining), 8)
        $quotaPen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $quotaPen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        if ($remaining -gt 0) { $g.DrawArc($quotaPen, $ringRect, -90, [single](360 * $remaining / 100.0)) }
        $quotaPen.Dispose()
        $pctText = ('{0}%' -f [int][math]::Round($remaining,0))
    } else {
        $pctText = '—'
    }

    $miniResetText = ''
    if ($null -ne $script:CurrentUsage -and $script:CurrentUsage.status -eq 'ok' -and $null -ne $script:CurrentUsage.fiveHour) {
        $miniResetText = Get-TrayResetShort $script:CurrentUsage.fiveHour.resetAtEpoch
    }

    $captionFont = New-Object Drawing.Font('Segoe UI Semibold', 7.5)
    $pctFont = New-Object Drawing.Font('Segoe UI Semibold', 22)
    $resetFont = New-Object Drawing.Font('Segoe UI', 7.2)
    $captionBrush = New-Object Drawing.SolidBrush($muted)
    $pctBrush = New-Object Drawing.SolidBrush($text)
    $resetBrush = New-Object Drawing.SolidBrush($muted)
    $fmt = New-Object Drawing.StringFormat
    $fmt.Alignment = [Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [Drawing.StringAlignment]::Center
    $g.DrawString('5 ЧАСОВ', $captionFont, $captionBrush, (New-Object Drawing.RectangleF(25, 33, 76, 18)), $fmt)
    $g.DrawString($pctText, $pctFont, $pctBrush, (New-Object Drawing.RectangleF(17, 48, 92, 43)), $fmt)
    if ($miniResetText) { $g.DrawString($miniResetText, $resetFont, $resetBrush, (New-Object Drawing.RectangleF(23, 88, 80, 17)), $fmt) }

    $fmt.Dispose(); $resetBrush.Dispose(); $pctBrush.Dispose(); $captionBrush.Dispose(); $resetFont.Dispose(); $pctFont.Dispose(); $captionFont.Dispose(); $innerBrush.Dispose(); $trackPen.Dispose()
})

# Soft rounded corners make the mini widget read as a small desktop card.
try {
    $radius = 18
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($miniForm.Width - $d, 0, $d, $d, 270, 90)
    $path.AddArc($miniForm.Width - $d, $miniForm.Height - $d, $d, $d, 0, 90)
    $path.AddArc(0, $miniForm.Height - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $miniForm.Region = New-Object Drawing.Region($path)
    $path.Dispose()
} catch { }

# Real Windows tray icon. The icon itself becomes a tiny quota gauge.
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$iconPath = Join-Path $script:AppDir 'CodexLimitBar.ico'
if (Test-Path -LiteralPath $iconPath) {
    try { $notifyIcon.Icon = New-Object Drawing.Icon($iconPath) } catch { $notifyIcon.Icon = [Drawing.SystemIcons]::Application }
} else {
    $notifyIcon.Icon = [Drawing.SystemIcons]::Application
}
$notifyIcon.Text = 'Codex Limit Bar'
$notifyIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$statusItem.Text = 'Лимиты: ожидание данных'
$statusItem.Enabled = $false
$showItem = New-Object System.Windows.Forms.ToolStripMenuItem
$showItem.Text = 'Полная панель'
$miniItem = New-Object System.Windows.Forms.ToolStripMenuItem
$miniItem.Text = 'Мини-виджет'
$hideItem = New-Object System.Windows.Forms.ToolStripMenuItem
$hideItem.Text = 'Свернуть в трей'
$refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem
$refreshItem.Text = 'Обновить'
$topMostItem = New-Object System.Windows.Forms.ToolStripMenuItem
$topMostItem.Text = 'Поверх всех окон'
$topMostItem.CheckOnClick = $true
$topMostItem.Checked = [bool]$form.TopMost
$opacityMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$opacityMenu.Text = 'Прозрачность'
$opacity100 = New-Object System.Windows.Forms.ToolStripMenuItem
$opacity100.Text = '100%'
$opacity90 = New-Object System.Windows.Forms.ToolStripMenuItem
$opacity90.Text = '90%'
$opacity80 = New-Object System.Windows.Forms.ToolStripMenuItem
$opacity80.Text = '80%'
$opacity70 = New-Object System.Windows.Forms.ToolStripMenuItem
$opacity70.Text = '70%'
$opacity60 = New-Object System.Windows.Forms.ToolStripMenuItem
$opacity60.Text = '60%'
$opacity50 = New-Object System.Windows.Forms.ToolStripMenuItem
$opacity50.Text = '50%'
$opacity40 = New-Object System.Windows.Forms.ToolStripMenuItem
$opacity40.Text = '40%'
$opacity30 = New-Object System.Windows.Forms.ToolStripMenuItem
$opacity30.Text = '30%'
$opacity20 = New-Object System.Windows.Forms.ToolStripMenuItem
$opacity20.Text = '20%'
$opacity10 = New-Object System.Windows.Forms.ToolStripMenuItem
$opacity10.Text = '10%'
[void]$opacityMenu.DropDownItems.Add($opacity100)
[void]$opacityMenu.DropDownItems.Add($opacity90)
[void]$opacityMenu.DropDownItems.Add($opacity80)
[void]$opacityMenu.DropDownItems.Add($opacity70)
[void]$opacityMenu.DropDownItems.Add($opacity60)
[void]$opacityMenu.DropDownItems.Add($opacity50)
[void]$opacityMenu.DropDownItems.Add($opacity40)
[void]$opacityMenu.DropDownItems.Add($opacity30)
[void]$opacityMenu.DropDownItems.Add($opacity20)
[void]$opacityMenu.DropDownItems.Add($opacity10)
$startHiddenItem = New-Object System.Windows.Forms.ToolStripMenuItem
$startHiddenItem.Text = 'Запускать свернутым в трей'
$startHiddenItem.CheckOnClick = $true
$startHiddenItem.Checked = [bool]$script:Settings.StartHidden
$autostartItem = New-Object System.Windows.Forms.ToolStripMenuItem
$autostartItem.Text = 'Автозапуск с Windows'
$autostartItem.CheckOnClick = $true
$autostartItem.Checked = (Test-Path -LiteralPath $script:StartupShortcut)
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitItem.Text = 'Выход'
[void]$trayMenu.Items.Add($statusItem)
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$trayMenu.Items.Add($showItem)
[void]$trayMenu.Items.Add($miniItem)
[void]$trayMenu.Items.Add($hideItem)
[void]$trayMenu.Items.Add($refreshItem)
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$trayMenu.Items.Add($topMostItem)
[void]$trayMenu.Items.Add($opacityMenu)
[void]$trayMenu.Items.Add($startHiddenItem)
[void]$trayMenu.Items.Add($autostartItem)
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$trayMenu.Items.Add($exitItem)
$notifyIcon.ContextMenuStrip = $trayMenu
$miniForm.ContextMenuStrip = $trayMenu
$miniGauge.ContextMenuStrip = $trayMenu
$miniWeeklyLabel.ContextMenuStrip = $trayMenu
$miniWeeklyReset.ContextMenuStrip = $trayMenu

function Get-BarColor([double]$remaining) {
    if ($remaining -le 15) { return $bad }
    if ($remaining -le 35) { return $warn }
    return $good
}

function Get-TrayResetShort($resetEpoch) {
    $resetAt = Convert-EpochToLocal $resetEpoch
    if ($null -eq $resetAt) { return '?' }
    $left = $resetAt - [datetime]::Now
    if ($left.TotalSeconds -le 0) { return 'сейчас' }
    if ($left.TotalHours -ge 1) {
        return ('{0}ч {1}м' -f [math]::Floor($left.TotalHours), $left.Minutes)
    }
    return ('{0}м' -f [math]::Max(0, [math]::Ceiling($left.TotalMinutes)))
}

function New-QuotaTrayIcon([double]$remaining) {
    try {
        $remaining = [math]::Max(0, [math]::Min(100, $remaining))
        $bmp = New-Object Drawing.Bitmap 32, 32
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([Drawing.Color]::Transparent)

        # Filled dark badge stays visible on both light and dark Windows taskbars.
        $badgeRect = New-Object Drawing.Rectangle(2, 2, 28, 28)
        $badgeBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(31, 31, 35))
        $g.FillEllipse($badgeBrush, $badgeRect)

        $ringRect = New-Object Drawing.Rectangle(3, 3, 26, 26)
        $basePen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(120, 82, 82, 91), 3.2)
        $quotaPen = New-Object Drawing.Pen((Get-BarColor $remaining), 3.4)
        $basePen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $basePen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $quotaPen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $quotaPen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $g.DrawEllipse($basePen, $ringRect)
        if ($remaining -gt 0) {
            $g.DrawArc($quotaPen, $ringRect, -90, [single](360 * $remaining / 100.0))
        }

        $font = New-Object Drawing.Font('Segoe UI Semibold', 13, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
        $brush = New-Object Drawing.SolidBrush([Drawing.Color]::White)
        $fmt = New-Object Drawing.StringFormat
        $fmt.Alignment = [Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [Drawing.StringAlignment]::Center
        $g.DrawString('C', $font, $brush, (New-Object Drawing.RectangleF(4,3.5,24,24)), $fmt)

        $h = $bmp.GetHicon()
        $temp = [Drawing.Icon]::FromHandle($h)
        $clone = [Drawing.Icon]$temp.Clone()
        if (-not ('CodexLimitBar.NativeMethods' -as [type])) {
            Add-Type -TypeDefinition 'namespace CodexLimitBar { public static class NativeMethods { [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr handle); } }'
        }
        [CodexLimitBar.NativeMethods]::DestroyIcon($h) | Out-Null
        $fmt.Dispose(); $brush.Dispose(); $font.Dispose(); $quotaPen.Dispose(); $basePen.Dispose(); $badgeBrush.Dispose(); $g.Dispose(); $bmp.Dispose()
        return $clone
    } catch { return $null }
}

function Update-TrayGauge([double]$remaining) {
    $pct = [int][math]::Round($remaining,0)
    if ($pct -eq $script:LastTrayPercent) { return }
    $script:LastTrayPercent = $pct
    $newIcon = New-QuotaTrayIcon $remaining
    if ($null -eq $newIcon) { return }
    $old = $script:TrayIcon
    $script:TrayIcon = $newIcon
    $notifyIcon.Icon = $newIcon
    if ($null -ne $old) { try { $old.Dispose() } catch { } }
}

function Set-OpacityValue([double]$value) {
    $form.Opacity = $value
    $miniForm.Opacity = $value
    $script:Settings.Opacity = $value
    $opacity100.Checked = ([math]::Abs($value - 1.0) -lt 0.01)
    $opacity90.Checked = ([math]::Abs($value - 0.9) -lt 0.01)
    $opacity80.Checked = ([math]::Abs($value - 0.8) -lt 0.01)
    $opacity70.Checked = ([math]::Abs($value - 0.7) -lt 0.01)
    $opacity60.Checked = ([math]::Abs($value - 0.6) -lt 0.01)
    $opacity50.Checked = ([math]::Abs($value - 0.5) -lt 0.01)
    $opacity40.Checked = ([math]::Abs($value - 0.4) -lt 0.01)
    $opacity30.Checked = ([math]::Abs($value - 0.3) -lt 0.01)
    $opacity20.Checked = ([math]::Abs($value - 0.2) -lt 0.01)
    $opacity10.Checked = ([math]::Abs($value - 0.1) -lt 0.01)
    Save-Settings
}

function Set-TopMostValue([bool]$value) {
    $wasVisible = $form.Visible
    $miniWasVisible = $miniForm.Visible
    $form.TopMost = $value
    $miniForm.TopMost = $value
    $script:Settings.TopMost = $value
    $topMostItem.Checked = $value
    $pinBtn.ForeColor = if ($value) { $good } else { $muted }
    Save-Settings

    # Turning pinning off must not look like the panel suddenly vanished behind
    # the current app. Keep it in front once; future windows may cover it normally.
    if ($wasVisible) {
        try {
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $form.BringToFront()
            $form.Activate()
        } catch { }
    } elseif ($miniWasVisible) {
        try {
            $miniForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $miniForm.BringToFront()
            $miniForm.Activate()
        } catch { }
    }
}

function Set-AutostartValue([bool]$enabled) {
    try {
        if ($enabled) {
            $dir = Split-Path -Parent $script:StartupShortcut
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($script:StartupShortcut)
            $psExe = Join-Path $PSHOME 'powershell.exe'
            if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
            $shortcut.TargetPath = $psExe
            $shortcut.Arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:MainScriptPath)
            $shortcut.WorkingDirectory = $script:AppDir
            $ico = Join-Path $script:AppDir 'CodexLimitBar.ico'
            if (Test-Path -LiteralPath $ico) { $shortcut.IconLocation = $ico }
            $shortcut.Save()
            $autostartItem.Checked = $true
        } else {
            if (Test-Path -LiteralPath $script:StartupShortcut) { Remove-Item -LiteralPath $script:StartupShortcut -Force }
            $autostartItem.Checked = $false
        }
    } catch {
        $autostartItem.Checked = (Test-Path -LiteralPath $script:StartupShortcut)
    }
}

function Update-TrayText {
    $u = $script:CurrentUsage
    if ($null -eq $u -or $u.status -ne 'ok') {
        $notifyIcon.Text = 'Codex Limit Bar: нет данных'
        $statusItem.Text = 'Лимиты: ожидание данных'
        return
    }

    $tipParts = @()
    $statusParts = @()
    if ($null -ne $u.fiveHour) {
        $p = [int][math]::Round([double]$u.fiveHour.remainingPercent,0)
        $tipParts += ('5ч {0}% • {1}' -f $p, (Get-TrayResetShort $u.fiveHour.resetAtEpoch))
        $statusParts += ('5ч {0}%' -f $p)
        Update-TrayGauge ([double]$u.fiveHour.remainingPercent)
    } elseif ($null -ne $u.weekly) {
        Update-TrayGauge ([double]$u.weekly.remainingPercent)
    }
    if ($null -ne $u.weekly) {
        $w = [int][math]::Round([double]$u.weekly.remainingPercent,0)
        $wr = Convert-EpochToLocal $u.weekly.resetAtEpoch
        if ($null -ne $wr) { $tipParts += ('Нед {0}% • {1}' -f $w, $wr.ToString('dd.MM HH:mm')) }
        else { $tipParts += ('Нед {0}%' -f $w) }
        $statusParts += ('нед {0}%' -f $w)
    }

    $s = if ($tipParts.Count -gt 0) { $tipParts -join ' | ' } else { 'Codex Limit Bar' }
    # .NET Framework NotifyIcon.Text is limited to 63 characters on many Windows builds.
    if ($s.Length -gt 63) { $s = $s.Substring(0,63) }
    $notifyIcon.Text = $s
    $statusItem.Text = if ($statusParts.Count -gt 0) { 'Лимиты: ' + ($statusParts -join ' · ') } else { 'Лимиты: нет данных' }
}

function Update-Display {
    $u = $script:CurrentUsage
    if ($null -eq $u -or $u.status -ne 'ok') {
        $mainPercent.Text = '—'
        $mainPercent.Font = New-Object Drawing.Font('Segoe UI Semibold', 24)
        $mainCaption.Text = '5 ЧАСОВ'
        $fillPanel.Width = 0
        $resetLabel.Text = 'ожидание данных'
        $weeklyCaption.Text = 'НЕДЕЛЯ'
        $weeklyLabel.Text = '—'
        $weeklyResetLabel.Text = ''
        $weeklyFillPanel.Width = 0
        $updatedLabel.Text = ''
        $miniWeeklyLabel.Text = 'Неделя —'
        $miniWeeklyReset.Text = ''
        $miniGauge.Invalidate()
        Update-TrayText
        return
    }

    $sourceText = [string]$u.source
    if ($u.planType) { $sourceText += (' · ' + [string]$u.planType) }
    $sourceLabel.Text = $sourceText

    $main = $u.fiveHour
    $mainIsWeeklyFallback = $false
    if ($null -eq $main) {
        if ($null -ne $u.weekly) {
            $main = $u.weekly
            $mainIsWeeklyFallback = $true
            $mainCaption.Text = 'НЕДЕЛЯ · 5 Ч НЕДОСТУПНО'
        } elseif ($null -ne $u.firstWindow) {
            $main = $u.firstWindow
            $mainCaption.Text = 'ЛИМИТ CODEX'
        }
    } else {
        $mainCaption.Text = '5 ЧАСОВ'
    }

    if ($null -ne $main) {
        $remaining = [double]$main.remainingPercent
        $mainPercent.Font = New-Object Drawing.Font('Segoe UI Semibold', 24)
        $mainPercent.Text = ('{0}% осталось' -f [int][math]::Round($remaining,0))
        $fillPanel.BackColor = Get-BarColor $remaining
        $fillPanel.Width = [int][math]::Round($trackPanel.Width * ($remaining / 100.0))
        $resetLabel.Text = Get-RemainingText $main.resetAtEpoch
        $rt = Convert-EpochToLocal $main.resetAtEpoch
        if ($null -ne $rt) { $resetLabel.Text += (' · до {0}' -f $rt.ToString('dd.MM HH:mm')) }
    } else {
        $mainPercent.Text = 'нет данных'
        $mainPercent.Font = New-Object Drawing.Font('Segoe UI Semibold', 16)
        $fillPanel.Width = 0
        $resetLabel.Text = 'лимит не найден в ответе Codex'
    }

    # Weekly quota gets its own compact row and progress bar.
    # Hide duplication if weekly is already being used as the primary fallback.
    if ($null -ne $u.weekly -and -not $mainIsWeeklyFallback) {
        $wk = $u.weekly
        $wkRemaining = [double]$wk.remainingPercent
        $weeklyCaption.Text = 'НЕДЕЛЯ'
        $weeklyLabel.Text = ('{0}% осталось' -f [int][math]::Round($wkRemaining,0))
        $weeklyFillPanel.BackColor = Get-BarColor $wkRemaining
        $weeklyFillPanel.Width = [int][math]::Round($weeklyTrackPanel.Width * ($wkRemaining / 100.0))
        $wkReset = Convert-EpochToLocal $wk.resetAtEpoch
        if ($null -ne $wkReset) { $weeklyResetLabel.Text = ('сброс {0}' -f $wkReset.ToString('dd.MM HH:mm')) }
        else { $weeklyResetLabel.Text = 'время сброса неизвестно' }
    } elseif ($mainIsWeeklyFallback) {
        $weeklyCaption.Text = '5 ЧАСОВ'
        $weeklyLabel.Text = 'недоступно'
        $weeklyResetLabel.Text = 'Codex не вернул отдельное окно'
        $weeklyFillPanel.Width = 0
    } else {
        $weeklyCaption.Text = 'НЕДЕЛЯ'
        $weeklyLabel.Text = 'недоступно'
        $weeklyResetLabel.Text = ''
        $weeklyFillPanel.Width = 0
    }

    try {
        $obs = Convert-EpochToLocal $u.observedAtEpoch
        if ($null -ne $obs) { $updatedLabel.Text = ('обновлено {0}' -f $obs.ToString('HH:mm')) }
        else { $updatedLabel.Text = '' }
    } catch { $updatedLabel.Text = '' }

    if ($null -ne $u.weekly) {
        $mw = [int][math]::Round([double]$u.weekly.remainingPercent,0)
        $miniWeeklyLabel.Text = ('Неделя {0}%' -f $mw)
        $mwr = Convert-EpochToLocal $u.weekly.resetAtEpoch
        if ($null -ne $mwr) { $miniWeeklyReset.Text = ('сброс {0}' -f $mwr.ToString('dd.MM HH:mm')) }
        else { $miniWeeklyReset.Text = '' }
    } else {
        $miniWeeklyLabel.Text = 'Неделя —'
        $miniWeeklyReset.Text = ''
    }
    $miniGauge.Invalidate()
    Update-TrayText
}

function Apply-ProbeResult($result) {
    if ($null -eq $result) { return }
    if ($result.status -eq 'ok') {
        $script:CurrentUsage = $result
        $script:LastRefresh = [datetime]::Now
        Update-Display
    } elseif ($null -eq $script:CurrentUsage) {
        $sourceLabel.Text = if ($result.message) { [string]$result.message } else { 'данные пока недоступны' }
    } else {
        $sourceLabel.Text = 'обновление не удалось · показаны последние данные'
    }
}

function Start-Probe {
    if ($null -ne $script:ProbeProcess) {
        try { if (-not $script:ProbeProcess.HasExited) { return } } catch { }
        try { $script:ProbeProcess.Dispose() } catch { }
        $script:ProbeProcess = $null
    }
    if (-not (Test-Path -LiteralPath $script:ProbeScript)) {
        $sourceLabel.Text = 'нет CodexLimitProbe.ps1'
        return
    }

    try {
        if (Test-Path -LiteralPath $script:ProbeOutput) {
            $script:ProbeFileStamp = (Get-Item -LiteralPath $script:ProbeOutput).LastWriteTime
        }
        $psExe = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
        try { if (Test-Path -LiteralPath $script:ProbeStatus) { Remove-Item -LiteralPath $script:ProbeStatus -Force } } catch { }
        $argLine = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -OutputPath "{1}" -StatusPath "{2}"' -f $script:ProbeScript, $script:ProbeOutput, $script:ProbeStatus)
        $script:ProbeProcess = Start-Process -FilePath $psExe -ArgumentList $argLine -WindowStyle Hidden -PassThru
        $script:ProbeStartedAt = [datetime]::Now
        $sourceLabel.Text = 'обновление…'
        $refreshBtn.Enabled = $false
    } catch {
        $sourceLabel.Text = 'не удалось запустить обновление'
        $refreshBtn.Enabled = $true
    }
}

function Poll-Probe {
    if ($null -ne $script:ProbeProcess -and $null -eq $script:CurrentUsage -and (Test-Path -LiteralPath $script:ProbeStatus)) {
        try {
            $stage = (Get-Content -LiteralPath $script:ProbeStatus -Raw -ErrorAction Stop).Trim()
            if ($stage) { $sourceLabel.Text = $stage }
        } catch { }
    }
    $fresh = Read-ProbeResult $false
    if ($null -ne $fresh) { Apply-ProbeResult $fresh }

    if ($null -eq $script:ProbeProcess) { return }
    $exited = $false
    try { $exited = $script:ProbeProcess.HasExited } catch { $exited = $true }

    if (-not $exited -and (([datetime]::Now - $script:ProbeStartedAt).TotalSeconds -gt 22)) {
        try { $script:ProbeProcess.Kill() } catch { }
        $exited = $true
        if ($null -eq $script:CurrentUsage) { $sourceLabel.Text = 'Codex не ответил за 22 секунды' }
        else { $sourceLabel.Text = 'таймаут обновления · показаны последние данные' }
    }

    if ($exited) {
        try { $script:ProbeProcess.Dispose() } catch { }
        $script:ProbeProcess = $null
        $refreshBtn.Enabled = $true
        $final = Read-ProbeResult $false
        if ($null -ne $final) { Apply-ProbeResult $final }
        elseif ($null -eq $script:CurrentUsage) { $sourceLabel.Text = 'лимиты пока не получены' }
    }
}

function Position-PopupNearTray {
    try {
        $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
        $area = $screen.WorkingArea
        $form.Location = New-Object Drawing.Point(($area.Right - $form.Width - 12), ($area.Bottom - $form.Height - 12))
    } catch { }
}

function Position-MiniWidget {
    try {
        if ($script:Settings.MiniX -ge 0 -and $script:Settings.MiniY -ge 0) {
            $candidate = New-Object Drawing.Rectangle([int]$script:Settings.MiniX, [int]$script:Settings.MiniY, $miniForm.Width, $miniForm.Height)
            $visible = $false
            foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
                if ($s.WorkingArea.IntersectsWith($candidate)) { $visible = $true; break }
            }
            if ($visible) {
                $miniForm.Location = New-Object Drawing.Point([int]$script:Settings.MiniX, [int]$script:Settings.MiniY)
                return
            }
        }
        $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
        $area = $screen.WorkingArea
        $miniForm.Location = New-Object Drawing.Point(($area.Right - $miniForm.Width - 12), ($area.Bottom - $miniForm.Height - 12))
    } catch { }
}

function Update-ModeChecks {
    $mode = [string]$script:Settings.DisplayMode
    $showItem.Checked = ($mode -eq 'full')
    $miniItem.Checked = ($mode -eq 'mini')
    $hideItem.Checked = ($mode -eq 'tray')
}

function Show-Window {
    try {
        $miniForm.Hide()
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        if (-not $form.Visible) {
            Position-PopupNearTray
            $form.Show()
        }
        $form.BringToFront()
        $form.Activate()
    } catch { }
}

function Show-MiniWidget {
    try {
        $form.Hide()
        if (-not $miniForm.Visible) {
            Position-MiniWidget
            $miniForm.Show()
        }
        $miniForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $miniForm.BringToFront()
        $miniForm.Activate()
        $miniGauge.Invalidate()
    } catch { }
}

function Set-DisplayMode([string]$mode) {
    if (@('full','mini','tray') -notcontains $mode) { return }
    $script:Settings.DisplayMode = $mode
    if ($mode -eq 'full') {
        $script:Settings.LastVisibleMode = 'full'
        Show-Window
    } elseif ($mode -eq 'mini') {
        $script:Settings.LastVisibleMode = 'mini'
        Show-MiniWidget
    } else {
        try { $form.Hide() } catch { }
        try { $miniForm.Hide() } catch { }
    }
    Update-ModeChecks
    Save-Settings
}

function Restore-VisibleMode {
    $mode = [string]$script:Settings.DisplayMode
    if ($mode -eq 'tray') { $mode = [string]$script:Settings.LastVisibleMode }
    if ($mode -ne 'mini') { $mode = 'full' }
    Set-DisplayMode $mode
}

function Hide-Window {
    Set-DisplayMode 'tray'
}

# Drag borderless window.
$form.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:dragging = $true
        $script:dragStart = $_.Location
    }
})
$form.Add_MouseMove({
    if ($script:dragging) {
        $p = [System.Windows.Forms.Cursor]::Position
        $form.Location = New-Object Drawing.Point(($p.X - $script:dragStart.X), ($p.Y - $script:dragStart.Y))
    }
})
$form.Add_MouseUp({ $script:dragging = $false })
$title.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:dragging = $true
        $script:dragStart = $form.PointToClient([System.Windows.Forms.Cursor]::Position)
    }
})
$title.Add_MouseMove({
    if ($script:dragging) {
        $p = [System.Windows.Forms.Cursor]::Position
        $form.Location = New-Object Drawing.Point(($p.X - $script:dragStart.X), ($p.Y - $script:dragStart.Y))
    }
})
$title.Add_MouseUp({ $script:dragging = $false })

# Drag the compact widget from the circle/body. Save its custom position at drag end.
$miniForm.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:miniDragging = $true
        $script:miniDragStart = $_.Location
    }
})
$miniForm.Add_MouseMove({
    if ($script:miniDragging) {
        $p = [System.Windows.Forms.Cursor]::Position
        $miniForm.Location = New-Object Drawing.Point(($p.X - $script:miniDragStart.X), ($p.Y - $script:miniDragStart.Y))
    }
})
$miniForm.Add_MouseUp({
    $script:miniDragging = $false
    $script:Settings.MiniX = $miniForm.Left
    $script:Settings.MiniY = $miniForm.Top
    Save-Settings
})
$miniGauge.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:miniDragging = $true
        $script:miniDragStart = $miniForm.PointToClient([System.Windows.Forms.Cursor]::Position)
    }
})
$miniGauge.Add_MouseMove({
    if ($script:miniDragging) {
        $p = [System.Windows.Forms.Cursor]::Position
        $miniForm.Location = New-Object Drawing.Point(($p.X - $script:miniDragStart.X), ($p.Y - $script:miniDragStart.Y))
    }
})
$miniGauge.Add_MouseUp({
    $script:miniDragging = $false
    $script:Settings.MiniX = $miniForm.Left
    $script:Settings.MiniY = $miniForm.Top
    Save-Settings
})

$closeBtn.Add_Click({ Set-DisplayMode 'tray' })
$miniBtn.Add_Click({ Set-DisplayMode 'mini' })
$refreshBtn.Add_Click({ Start-Probe })
$pinBtn.Add_Click({ Set-TopMostValue (-not $form.TopMost) })
$showItem.Add_Click({ Set-DisplayMode 'full' })
$miniItem.Add_Click({ Set-DisplayMode 'mini' })
$hideItem.Add_Click({ Set-DisplayMode 'tray' })
$refreshItem.Add_Click({ Start-Probe })
$topMostItem.Add_Click({ Set-TopMostValue ([bool]$topMostItem.Checked) })
$opacity100.Add_Click({ Set-OpacityValue 1.0 })
$opacity90.Add_Click({ Set-OpacityValue 0.9 })
$opacity80.Add_Click({ Set-OpacityValue 0.8 })
$opacity70.Add_Click({ Set-OpacityValue 0.7 })
$opacity60.Add_Click({ Set-OpacityValue 0.6 })
$opacity50.Add_Click({ Set-OpacityValue 0.5 })
$opacity40.Add_Click({ Set-OpacityValue 0.4 })
$opacity30.Add_Click({ Set-OpacityValue 0.3 })
$opacity20.Add_Click({ Set-OpacityValue 0.2 })
$opacity10.Add_Click({ Set-OpacityValue 0.1 })
$startHiddenItem.Add_Click({
    $script:Settings.StartHidden = [bool]$startHiddenItem.Checked
    Save-Settings
})
$autostartItem.Add_Click({ Set-AutostartValue ([bool]$autostartItem.Checked) })
$notifyIcon.Add_MouseClick({
    # Left click restores whichever visible mode the user used last: full or mini.
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Restore-VisibleMode }
})
$notifyIcon.Add_DoubleClick({ Set-DisplayMode 'full' })
$miniExpandBtn.Add_Click({ Set-DisplayMode 'full' })
$miniGauge.Add_DoubleClick({ Set-DisplayMode 'full' })
$miniWeeklyLabel.Add_DoubleClick({ Set-DisplayMode 'full' })
$exitItem.Add_Click({
    $script:Exiting = $true
    $form.Close()
})

$form.Add_FormClosing({
    if (-not $script:Exiting) {
        $_.Cancel = $true
        Set-DisplayMode 'tray'
    }
})
$miniForm.Add_FormClosing({
    if (-not $script:Exiting) {
        $_.Cancel = $true
        Set-DisplayMode 'tray'
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    Poll-Probe
    Update-Display
    if ($null -eq $script:ProbeProcess -and (([datetime]::Now - $script:LastRefresh).TotalMinutes -ge 3)) {
        Start-Probe
    }
})

$form.Add_Shown({
    # Show previously cached successful reading immediately, then refresh in background.
    $old = Read-ProbeResult $true
    if ($null -ne $old -and $old.status -eq 'ok') { Apply-ProbeResult $old }
    Set-OpacityValue ([double]$script:Settings.Opacity)
    Set-TopMostValue ([bool]$script:Settings.TopMost)
    Start-Probe
    $timer.Start()
    Update-ModeChecks
    $startupMode = if ([bool]$script:Settings.StartHidden) { 'tray' } else { [string]$script:Settings.DisplayMode }
    $form.BeginInvoke([Action]{ Set-DisplayMode $startupMode }) | Out-Null
})

$form.Add_FormClosed({
    $timer.Stop()
    $timer.Dispose()
    if ($null -ne $script:ProbeProcess) {
        try { if (-not $script:ProbeProcess.HasExited) { $script:ProbeProcess.Kill() } } catch { }
        try { $script:ProbeProcess.Dispose() } catch { }
    }
    try { $miniForm.Hide(); $miniForm.Dispose() } catch { }
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    if ($null -ne $script:TrayIcon) { try { $script:TrayIcon.Dispose() } catch { } }
})

# Keep the Windows message loop alive even while the main panel is hidden.
# ShowDialog() returns when a modal form is hidden, which terminated the PowerShell
# process and removed the tray icon. Application.Run() keeps the tray/mini app alive;
# only the explicit "Выход" action closes the form and ends the loop.
[System.Windows.Forms.Application]::Run($form)
