#Requires -Version 5.1
<#
.SYNOPSIS
    Cline AutoRetry - расширение встроенного авто-повтора запросов к провайдеру.

.DESCRIPTION
    В Cline (расширение saoudrizwan.claude-dev) уже есть авто-ретрай временных
    ошибок провайдера: метод withProviderErrorRetry() в агентном рантайме.
    Но лимит жёстко зашит в бандл: 3 попытки с паузами 1с / 2с / 4с (всего ~7 секунд).
    Если провайдер "тупит" дольше, Cline показывает кнопку Retry и ждёт нажатия.

    Этот скрипт находит объявления констант рядом с withProviderErrorRetry
    (имена в минифицированном коде разные - _mn/ccp/dcp, it/Nu/Mu, bo/Bp/Xp)
    и меняет только три числовых литерала:
        maxRetries  - сколько раз повторять запрос
        baseDelay   - базовая пауза (мс), растёт экспоненциально
        maxDelay    - потолок паузы (мс)

    Логика "ретраить только ошибки, а не нормальное завершение" остаётся родной:
    повтор происходит, только если ход завершился ошибкой и классификатор
    пометил её как временную (408/409/425/429/5xx, сетевые сбои).
    При штатном завершении задачи (finishReason = stop) повторов не будет.

.PARAMETER Mode
    Apply   - применить патч (по умолчанию)
    Verify  - только показать текущие значения, ничего не менять
    Revert  - вернуть оригинальные файлы из .cline-autoretry.bak

.PARAMETER MaxRetries
    Сколько раз повторять запрос при временной ошибке. По умолчанию 12.

.PARAMETER BaseDelayMs
    Базовая пауза перед первой повторной попыткой, мс. По умолчанию 2000.

.PARAMETER MaxDelayMs
    Потолок паузы между попытками, мс. По умолчанию 60000.

.PARAMETER ExtensionRoot
    Путь к папке расширения. По умолчанию ищется последняя версия
    saoudrizwan.claude-dev-* в %USERPROFILE%\.vscode\extensions.

.PARAMETER InstallTask
    Зарегистрировать задачу планировщика: применение патча при входе в систему
    (нужно, потому что обновление Cline перезаписывает файлы расширения).

.PARAMETER UninstallTask
    Удалить зарегистрированную задачу планировщика.

.PARAMETER Quiet
    Минимум вывода (для запуска из планировщика).

.PARAMETER LogPath
    Писать лог в указанный файл (относительный путь считается от папки скрипта).

.EXAMPLE
    .\patch-cline-retry.ps1 -Mode Verify

.EXAMPLE
    .\patch-cline-retry.ps1 -MaxRetries 20 -BaseDelayMs 3000 -MaxDelayMs 120000

.EXAMPLE
    .\patch-cline-retry.ps1 -Mode Revert
#>
[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Verify', 'Revert')]
    [string]$Mode = 'Apply',

    [int]$MaxRetries = 12,
    [int]$BaseDelayMs = 2000,
    [int]$MaxDelayMs = 60000,

    [string]$ExtensionRoot,

    [string]$LogPath,

    [switch]$InstallTask,
    [switch]$UninstallTask,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:Quiet = [bool]$Quiet
$BackupSuffix = '.cline-autoretry.bak'
$TaskName = 'Cline AutoRetry Reapply'

$script:LogPath = $LogPath
if ($script:LogPath -and -not [System.IO.Path]::IsPathRooted($script:LogPath)) {
    $script:LogPath = Join-Path $PSScriptRoot $script:LogPath
}
if ($script:LogPath) {
    $logDir = Split-Path -Parent $script:LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -LiteralPath $script:LogPath -Value ('=== ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  Mode=' + $Mode) -Encoding utf8
}

function Add-LogLine {
    param([string]$Message)
    if (-not $script:LogPath) { return }
    try { Add-Content -LiteralPath $script:LogPath -Value $Message -Encoding utf8 } catch { }
}

function Write-Info {
    param([string]$Message, [string]$Color = 'Gray')
    Add-LogLine $Message
    if (-not $script:Quiet) { Write-Host $Message -ForegroundColor $Color }
}

function Write-Result {
    param([string]$Message, [string]$Color = 'Gray')
    Add-LogLine $Message
    Write-Host $Message -ForegroundColor $Color
}


# ---------------------------------------------------------------------------
# Поиск папки расширения
# ---------------------------------------------------------------------------
function Resolve-ClineExtensionRoot {
    param([string]$Path)

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Не найдена папка расширения: $Path" }
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $base = Join-Path $env:USERPROFILE '.vscode\extensions'
    $dirs = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^saoudrizwan\.claude-dev-\d+(\.\d+)+$' })

    if ($dirs.Count -eq 0) {
        throw "Расширение saoudrizwan.claude-dev не найдено в $base"
    }

    $best = $dirs |
        Sort-Object { [version]($_.Name -replace '^saoudrizwan\.claude-dev-', '') } -Descending |
        Select-Object -First 1

    return $best.FullName
}

# ---------------------------------------------------------------------------
# Числовые литералы: сохраняем стиль записи (1e3 -> 2e3, 1000 -> 2000)
# ---------------------------------------------------------------------------
function Format-NumberLike {
    param([int]$Value, [string]$Original)

    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    if ($Original -match '^(\d+)e(\d+)$') {
        $exp = [int]$Matches[2]
        $scale = [Math]::Pow(10, $exp)
        $mantissa = $Value / $scale
        return ($mantissa.ToString($inv) + 'e' + $exp)
    }

    return $Value.ToString($inv)
}

# ---------------------------------------------------------------------------
# Разбор констант рядом с withProviderErrorRetry
# ---------------------------------------------------------------------------
function Get-RetryConstants {
    param([string]$Text)

    # 1. Определение функции: withProviderErrorRetry(args){
    $fnName = 'withProviderErrorRetry'
    $fnIdx = -1
    $probe = 0
    while ($true) {
        $i = $Text.IndexOf($fnName, $probe, [StringComparison]::Ordinal)
        if ($i -lt 0) { break }
        $probe = $i + 1

        # слева не должно быть символа идентификатора или точки (this.withProviderErrorRetry(...))
        if ($i -gt 0) {
            $prev = $Text[$i - 1]
            if ([char]::IsLetterOrDigit($prev) -or $prev -eq '_' -or $prev -eq '$' -or $prev -eq '.') { continue }
        }

        # справа должна быть сигнатура, сразу за которой открывается тело
        $afterStart = $i + $fnName.Length
        $after = $Text.Substring($afterStart, [Math]::Min(500, $Text.Length - $afterStart))
        if ($after -match '^\([^)]{0,400}\)\s*\{') { $fnIdx = $i; break }
    }
    if ($fnIdx -lt 0) { return $null }

    # 2. Голова тела функции - там же условия цикла повторов
    $head = $Text.Substring($fnIdx, [Math]::Min(3000, $Text.Length - $fnIdx))

    # ... if(attempt>=MAX||!this.isRetryableProviderErrorTurn(result)) return result ...
    $mMax = [regex]::Match($head, '>=([A-Za-z_$][\w$]*)\s*\|\|\s*!this\.isRetryableProviderErrorTurn')
    if (-not $mMax.Success) { return $null }

    # ... let delay=Math.min(BASE*2**(attempt-1),CAP) ...
    $mMin = [regex]::Match($head, 'Math\.min\(([A-Za-z_$][\w$]*)\*2\*\*\([^)]*\),([A-Za-z_$][\w$]*)\)')
    if (-not $mMin.Success) { return $null }

    $roles = [ordered]@{
        maxRetries = $mMax.Groups[1].Value
        baseDelay  = $mMin.Groups[1].Value
        maxDelay   = $mMin.Groups[2].Value
    }

    if (($roles['maxRetries'] -eq $roles['baseDelay']) -or ($roles['maxRetries'] -eq $roles['maxDelay']) -or ($roles['baseDelay'] -eq $roles['maxDelay'])) {
        return $null
    }

    # 3. Ищем цепочку объявлений "A=n,B=n,C=n" выше функции (окно 200 КБ).
    #    Regex по всему 25-МБ бандлу не запускаем: только по окну.
    $window = 200000
    $winStart = [Math]::Max(0, $fnIdx - $window)
    $windowText = $Text.Substring($winStart, $fnIdx - $winStart)

    $numberToken = '\d+(?:\.\d+)?(?:[eE][+-]?\d+)?'
    $rxTriple = [regex]::new('[A-Za-z_$][\w$]*=' + $numberToken + '(?:,[A-Za-z_$][\w$]*=' + $numberToken + '){2}')

    $best = $null
    $bestDistance = [int]::MaxValue
    foreach ($m in $rxTriple.Matches($windowText)) {
        $parts = $m.Value.Split(',')
        if ($parts.Count -ne 3) { continue }

        $byName = @{}
        foreach ($part in $parts) {
            $kv = $part.Split('=')
            $byName[$kv[0]] = $kv[1]
        }

        if (-not $byName.ContainsKey($roles['maxRetries'])) { continue }
        if (-not $byName.ContainsKey($roles['baseDelay'])) { continue }
        if (-not $byName.ContainsKey($roles['maxDelay'])) { continue }

        $spanStart = $winStart + $m.Index
        $distance = $fnIdx - $spanStart
        if ($distance -ge $bestDistance) { continue }

        $bestDistance = $distance
        $best = @{
            spanStart = $spanStart
            spanText  = $m.Value
            byName    = $byName
        }
    }

    if ($null -eq $best) { return $null }

    # 4. Абсолютные позиции числовых литералов внутри найденной цепочки
    $literals = @{}
    $cursor = $best.spanStart
    foreach ($part in $best.spanText.Split(',')) {
        $kv = $part.Split('=')
        $literals[$kv[0]] = [pscustomobject]@{
            Name   = $kv[0]
            Token  = $kv[1]
            Index  = $cursor + $kv[0].Length + 1
            Length = $kv[1].Length
        }
        $cursor += $part.Length + 1
    }

    return [pscustomobject]@{
        Declaration = $best.spanText
        DeclIndex   = $best.spanStart
        MaxRetries  = $literals[$roles['maxRetries']]
        BaseDelay   = $literals[$roles['baseDelay']]
        MaxDelay    = $literals[$roles['maxDelay']]
    }
}

# ---------------------------------------------------------------------------
# Список файлов расширения, содержащих withProviderErrorRetry
# ---------------------------------------------------------------------------
function Get-RetryPatchTargets {
    param([string]$Root)

    $result = @()
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.js -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -ge 100000 }

    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        if ($text.IndexOf('withProviderErrorRetry', [StringComparison]::Ordinal) -lt 0) { continue }

        $info = Get-RetryConstants -Text $text
        if ($null -eq $info) { continue }

        $result += [pscustomobject]@{
            Path     = $file.FullName
            Relative = $file.FullName.Replace($Root, '').TrimStart('\')
            Text     = $text
            Info     = $info
            Backup   = $file.FullName + $BackupSuffix
        }
    }

    return $result
}

# ---------------------------------------------------------------------------
# Сборка нового текста: меняем только три числовых литерала
# ---------------------------------------------------------------------------
function New-PatchedText {
    param(
        [string]$Text,
        $Info,
        [int]$Retries,
        [int]$BaseMs,
        [int]$CapMs
    )

    $edits = @(
        @{ Index = $Info.MaxRetries.Index; Length = $Info.MaxRetries.Length; New = (Format-NumberLike -Value $Retries -Original $Info.MaxRetries.Token) },
        @{ Index = $Info.BaseDelay.Index;  Length = $Info.BaseDelay.Length;  New = (Format-NumberLike -Value $BaseMs  -Original $Info.BaseDelay.Token) },
        @{ Index = $Info.MaxDelay.Index;   Length = $Info.MaxDelay.Length;   New = (Format-NumberLike -Value $CapMs   -Original $Info.MaxDelay.Token) }
    )

    $builder = New-Object System.Text.StringBuilder($Text)
    foreach ($edit in ($edits | Sort-Object { $_.Index } -Descending)) {
        [void]$builder.Remove($edit.Index, $edit.Length)
        [void]$builder.Insert($edit.Index, $edit.New)
    }

    return $builder.ToString()
}

function Test-IsPatched {
    param($Info, [int]$Retries, [int]$BaseMs, [int]$CapMs)

    return ($Info.MaxRetries.Token -eq (Format-NumberLike -Value $Retries -Original $Info.MaxRetries.Token)) -and
           ($Info.BaseDelay.Token  -eq (Format-NumberLike -Value $BaseMs  -Original $Info.BaseDelay.Token)) -and
           ($Info.MaxDelay.Token   -eq (Format-NumberLike -Value $CapMs   -Original $Info.MaxDelay.Token))
}

function Save-TextFile {
    param([string]$Path, [string]$Text)

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Write-TargetReport {
    param($Target)

    Write-Result ("  файл: " + $Target.Relative) 'White'
    Write-Result ("    объявление: " + $Target.Info.Declaration)
    Write-Result ("    maxRetries=" + $Target.Info.MaxRetries.Token + " (" + $Target.Info.MaxRetries.Name + ")")
    Write-Result ("    baseDelay=" + $Target.Info.BaseDelay.Token + " мс (" + $Target.Info.BaseDelay.Name + ")")
    Write-Result ("    maxDelay=" + $Target.Info.MaxDelay.Token + " мс (" + $Target.Info.MaxDelay.Name + ")")
}

# ---------------------------------------------------------------------------
# Планировщик: переприменение патча после обновления Cline
# ---------------------------------------------------------------------------
function Install-ReapplyTask {
    param([string]$ScriptPath)

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode Apply -Quiet -LogPath "autoretry-task.log"' -f $ScriptPath)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Description 'Переприменяет патч Cline AutoRetry после обновления расширения Cline' -Force | Out-Null
}

function Remove-ReapplyTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

function Get-TotalWaitSeconds {
    param([int]$Retries, [int]$BaseMs, [int]$CapMs)

    $total = 0
    for ($i = 1; $i -le $Retries; $i++) {
        $total += [Math]::Min($BaseMs * [Math]::Pow(2, $i - 1), $CapMs)
    }
    return [Math]::Round($total / 1000.0, 1)
}


# ===========================================================================
# Основная логика
# ===========================================================================
$exitCode = 0

try {
    $root = Resolve-ClineExtensionRoot -Path $ExtensionRoot
    Write-Info ("Cline: " + $root) 'Cyan'

    if ($UninstallTask) {
        try {
            Remove-ReapplyTask
            Write-Result ("Задача планировщика удалена: " + $TaskName) 'Yellow'
        }
        catch {
            Write-Result ("Не удалось удалить задачу '" + $TaskName + "': " + $_.Exception.Message) 'Yellow'
        }
    }

    Write-Info 'Сканирую бандлы расширения...' 'DarkGray'
    $targets = @(Get-RetryPatchTargets -Root $root)
    if ($targets.Count -eq 0) {
        throw "Не найдены файлы с withProviderErrorRetry в $root. Похоже, структура бандла изменилась - патч не применён."
    }

    $waitSeconds = Get-TotalWaitSeconds -Retries $MaxRetries -BaseMs $BaseDelayMs -CapMs $MaxDelayMs
    Write-Info ("Найдено бандлов с авто-ретраем: " + $targets.Count) 'Cyan'
    Write-Info ("Цель: maxRetries=" + $MaxRetries + ", baseDelay=" + $BaseDelayMs + " мс, maxDelay=" + $MaxDelayMs + " мс, суммарное ожидание ~" + $waitSeconds + " с") 'Cyan'
    Write-Info ''

    switch ($Mode) {

        'Verify' {
            foreach ($target in $targets) {
                $patched = Test-IsPatched -Info $target.Info -Retries $MaxRetries -BaseMs $BaseDelayMs -CapMs $MaxDelayMs
                $backupText = if (Test-Path -LiteralPath $target.Backup) { 'бэкап есть' } else { 'бэкапа нет' }
                $stateText = if ($patched) { 'ПАТЧ ПРИМЕНЁН' } else { 'оригинал / другие значения' }
                Write-TargetReport -Target $target
                Write-Result ("    состояние: " + $stateText + ", " + $backupText) $(if ($patched) { 'Green' } else { 'Yellow' })
            }
        }

        'Revert' {
            foreach ($target in $targets) {
                if (-not (Test-Path -LiteralPath $target.Backup)) {
                    Write-Result ("  " + $target.Relative + ": бэкапа нет, пропуск") 'Yellow'
                    continue
                }
                Copy-Item -LiteralPath $target.Backup -Destination $target.Path -Force
                Remove-Item -LiteralPath $target.Backup -Force
                Write-Result ("  " + $target.Relative + ": восстановлен оригинал") 'Green'
            }
            Write-Result 'Готово. Перезагрузите окно VS Code (Ctrl+Shift+P -> Reload Window).' 'Green'
        }

        'Apply' {
            $changed = 0
            foreach ($target in $targets) {
                if (Test-IsPatched -Info $target.Info -Retries $MaxRetries -BaseMs $BaseDelayMs -CapMs $MaxDelayMs) {
                    if (Test-Path -LiteralPath $target.Backup) {
                        Write-Result ("  " + $target.Relative + ": уже пропатчен, пропуск") 'DarkGray'
                    }
                    else {
                        Write-Result ("  " + $target.Relative + ": уже пропатчен, но бэкапа нет - откат невозможен") 'Yellow'
                        Write-Result '    для чистого отката переустановите расширение Cline и запустите установщик заново' 'Yellow'
                    }
                    continue
                }

                if (-not (Test-Path -LiteralPath $target.Backup)) {
                    Copy-Item -LiteralPath $target.Path -Destination $target.Backup -Force
                }

                $newText = New-PatchedText -Text $target.Text -Info $target.Info -Retries $MaxRetries -BaseMs $BaseDelayMs -CapMs $MaxDelayMs
                Save-TextFile -Path $target.Path -Text $newText

                # Контроль: перечитываем файл и заново разбираем константы
                $checkText = [System.IO.File]::ReadAllText($target.Path)
                $checkInfo = Get-RetryConstants -Text $checkText
                $ok = ($null -ne $checkInfo) -and (Test-IsPatched -Info $checkInfo -Retries $MaxRetries -BaseMs $BaseDelayMs -CapMs $MaxDelayMs)

                if (-not $ok) {
                    Copy-Item -LiteralPath $target.Backup -Destination $target.Path -Force
                    throw ("Проверка после записи не прошла для " + $target.Relative + " - файл восстановлен из бэкапа.")
                }

                $changed++
                Write-Result ("  " + $target.Relative + ": пропатчен (" + $checkInfo.Declaration + ")") 'Green'
            }

            if ($changed -eq 0) {
                Write-Result 'Все файлы уже пропатчены - изменений не требуется.' 'Green'
            }
            else {
                Write-Result ("Пропатчено файлов: " + $changed) 'Green'
                Write-Result 'ВАЖНО: перезагрузите окно VS Code (Ctrl+Shift+P -> Reload Window), чтобы Cline подхватил патч.' 'Yellow'
            }
        }
    }

    if ($InstallTask) {
        try {
            Install-ReapplyTask -ScriptPath $PSCommandPath
            Write-Result ("Задача планировщика зарегистрирована: " + $TaskName + " (при входе в систему)") 'Green'
        }
        catch {
            Write-Result ("Не удалось зарегистрировать задачу: " + $_.Exception.Message) 'Yellow'
        }
    }
}
catch {
    Write-Result ("ОШИБКА: " + $_.Exception.Message) 'Red'
    $exitCode = 1
}

exit $exitCode

