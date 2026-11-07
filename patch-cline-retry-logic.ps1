#Requires -Version 5.1
<#
.SYNOPSIS
    Cline AutoRetry, часть 2: разрешаем повтор для текстовых ошибок провайдера.
.DESCRIPTION
    В Cline повтор запроса разрешён только если ошибка помечена как временная.
    Решение принимает классификатор: сначала смотрит HTTP-статус, а если его нет,
    проверяет текст сообщения по регулярке /provider returned error/i.
    Ошибки вида "Upstream capacity is temporarily exhausted. Retry shortly." приходят
    текстом без статуса, поэтому временными не считаются и авто-ретрай не запускается.

    Скрипт делает три точечные правки в каждом бандле, где они есть:
      1. расширяет регулярку классификатора (capacity/overloaded/rate limit/...);
      2. снимает запрет на повтор для ошибок, случившихся во время стрима
         (retryable: X!=="stream_callback" && X!=="stream_part" && ...);
      3. частичный текст в ответе больше не блокирует повтор (блокируют только tool-call).

.PARAMETER Mode
    Apply - применить правки (по умолчанию); Verify - только показать; Revert - откатить.
.PARAMETER ExtensionRoot
    Папка расширения. По умолчанию - последняя saoudrizwan.claude-dev-* в ~/.vscode/extensions.
.PARAMETER LogPath
    Писать лог в файл.
.PARAMETER Quiet
    Минимум вывода.
.EXAMPLE
    .\patch-cline-retry-logic.ps1 -Mode Verify
#>
[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Verify', 'Revert')]
    [string]$Mode = 'Apply',

    [string]$ExtensionRoot,

    [string]$LogPath,

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:Quiet = [bool]$Quiet
$BackupSuffix = '.cline-autoretry-logic.bak'

$script:LogPath = $LogPath
if ($script:LogPath -and -not [System.IO.Path]::IsPathRooted($script:LogPath)) {
    $script:LogPath = Join-Path $PSScriptRoot $script:LogPath
}
if ($script:LogPath) {
    $d = Split-Path -Parent $script:LogPath
    if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
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

# Классификатор временных ошибок: было / было только одно значение.
$OldClassifier = '/provider returned error/i'
$NewClassifier = '/provider returned error|temporarily exhausted|capacity exhausted|insufficient capacity|over capacity|overloaded|temporarily unavailable|service unavailable|retry shortly|server is busy|too many requests|rate limit|rate_limit/i'

function Get-LogicEdits {
    param([string]$Text)

    $edits = @()

    # 1. Текстовая ошибка без HTTP-статуса тоже считается временной.
    $i = $Text.IndexOf($OldClassifier, [StringComparison]::Ordinal)
    if ($i -ge 0) {
        $edits += [pscustomobject]@{ Kind = 'classifier'; Index = $i; Length = $OldClassifier.Length; New = $NewClassifier }
    }

    # 2. Ошибка во время стрима тоже имеет право на повтор.
    $gateTail = '!=="stream_part"&&'
    $gateEnd = $Text.IndexOf($gateTail, [StringComparison]::Ordinal)
    if ($gateEnd -ge 0) {
        $start = $Text.LastIndexOf('retryable:', $gateEnd)
        if ($start -ge 0 -and ($gateEnd - $start) -lt 160) {
            $len = ($gateEnd + $gateTail.Length) - $start
            $frag = $Text.Substring($start, $len)
            if ($frag -match '^retryable:[A-Za-z_$][\w$]*!=="stream_callback"&&[A-Za-z_$][\w$]*!=="stream_part"&&$') {
                $edits += [pscustomobject]@{ Kind = 'streamGate'; Index = $start; Length = $len; New = 'retryable:' }
            }
        }
    }

    # 3. Частичный текст не блокирует повтор, блокирует только вызов инструмента.
    $pos = 0
    $guardDone = $false
    while (-not $guardDone) {
        $someIdx = $Text.IndexOf('message.content.some(', $pos, [StringComparison]::Ordinal)
        if ($someIdx -lt 0) { break }
        $probeLen = [Math]::Min(160, $Text.Length - $someIdx)
        $probe = $Text.Substring($someIdx, $probeLen)
        $m = [regex]::Match($probe, '^message\.content\.some\(\(?([A-Za-z_$][\w$]*)\)?=>\1\.type!=="reasoning"\)')
        if ($m.Success) {
            $v = $m.Groups[1].Value
            $new = 'message.content.some((' + $v + ')=>' + $v + '.type==="tool-call")'
            $edits += [pscustomobject]@{ Kind = 'contentGuard'; Index = $someIdx; Length = $m.Length; New = $new }
            $guardDone = $true
        }
        $pos = $someIdx + 1
    }

    return $edits
}

function Get-LogicState {
    param([string]$Text)

    $kinds = @(Get-LogicEdits -Text $Text | ForEach-Object { $_.Kind })
    return [pscustomobject]@{
        Classifier = ($Text.IndexOf('insufficient capacity', [StringComparison]::Ordinal) -ge 0)
        StreamGate = ($kinds -notcontains 'streamGate')
        Content    = ($kinds -notcontains 'contentGuard')
    }
}

function Save-TextFile {
    param([string]$Path, [string]$Text)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function New-PatchedText {
    param([string]$Text, $Edits)

    $builder = New-Object System.Text.StringBuilder($Text)
    foreach ($e in ($Edits | Sort-Object { $_.Index } -Descending)) {
        [void]$builder.Remove($e.Index, $e.Length)
        [void]$builder.Insert($e.Index, $e.New)
    }
    return $builder.ToString()
}

function Get-LogicTargets {
    param([string]$Root)

    $result = @()
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.js -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -ge 100000 }

    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        if ($text.IndexOf('provider returned error', [StringComparison]::Ordinal) -lt 0 -and $text.IndexOf('insufficient capacity', [StringComparison]::Ordinal) -lt 0 -and $text.IndexOf('.type!=="reasoning"', [StringComparison]::Ordinal) -lt 0) { continue }

        $result += [pscustomobject]@{
            Path     = $file.FullName
            Relative = $file.FullName.Replace($Root, '').TrimStart('\')
            Text     = $text
            Backup   = $file.FullName + $BackupSuffix
        }
    }

    return $result
}

$root = Resolve-ClineExtensionRoot -Path $ExtensionRoot
$targets = @(Get-LogicTargets -Root $root)

Write-Info ('Папка расширения: ' + $root) 'Cyan'
Write-Info ('Бандлов с авто-ретраем: ' + $targets.Count) 'Cyan'
Write-Info '' 'Cyan'


switch ($Mode) {

    'Verify' {
        foreach ($t in $targets) {
            $st = Get-LogicState -Text $t.Text
            $a = 'исходный'; if ($st.Classifier) { $a = 'расширен' }
            $b = 'запрещён'; if ($st.StreamGate) { $b = 'разрешён' }
            $c = 'блокирует'; if ($st.Content) { $c = 'не мешает' }
            Write-Result ('  файл: ' + $t.Relative) 'White'
            Write-Result ('    классификатор временных ошибок: ' + $a) $(if ($st.Classifier) { 'Green' } else { 'Yellow' })
            Write-Result ('    повтор после ошибки в стриме: ' + $b) $(if ($st.StreamGate) { 'Green' } else { 'Yellow' })
            Write-Result ('    частичный ответ и повтор: ' + $c) $(if ($st.Content) { 'Green' } else { 'Yellow' })
        }
    }

    'Revert' {
        foreach ($t in $targets) {
            if (-not (Test-Path -LiteralPath $t.Backup)) {
                Write-Result ('  ' + $t.Relative + ': бэкапа нет, пропуск') 'Yellow'
                continue
            }
            Copy-Item -LiteralPath $t.Backup -Destination $t.Path -Force
            Remove-Item -LiteralPath $t.Backup -Force
            Write-Result ('  ' + $t.Relative + ': восстановлен оригинал') 'Green'
        }
        Write-Result 'Готово. Перезагрузите окно VS Code (Ctrl+Shift+P -> Reload Window).' 'Green'
    }

    'Apply' {
        $changed = 0
        foreach ($t in $targets) {
            $edits = @(Get-LogicEdits -Text $t.Text)
            if ($edits.Count -eq 0) {
                Write-Result ('  ' + $t.Relative + ': уже пропатчен, пропуск') 'DarkGray'
                continue
            }
            if (-not (Test-Path -LiteralPath $t.Backup)) {
                Copy-Item -LiteralPath $t.Path -Destination $t.Backup -Force
            }
            $newText = New-PatchedText -Text $t.Text -Edits $edits
            Save-TextFile -Path $t.Path -Text $newText
            $checkText = [System.IO.File]::ReadAllText($t.Path)
            $left = @(Get-LogicEdits -Text $checkText)
            $st = Get-LogicState -Text $checkText
            $ok = ($left.Count -eq 0)
            if (-not $ok) {
                Copy-Item -LiteralPath $t.Backup -Destination $t.Path -Force
                throw ('Проверка после записи не прошла для ' + $t.Relative + ' - файл восстановлен из бэкапа.')
            }
            $changed++
            $kinds = ($edits | ForEach-Object { $_.Kind }) -join ', '
            Write-Result ('  ' + $t.Relative + ': пропатчен (' + $kinds + ')') 'Green'
        }

        if ($changed -eq 0) {
            Write-Result 'Все файлы уже пропатчены - изменений не требуется.' 'Green'
        }
        else {
            Write-Result ('Пропатчено файлов: ' + $changed) 'Green'
            Write-Result 'ВАЖНО: перезагрузите окно VS Code (Ctrl+Shift+P -> Reload Window).' 'Yellow'
        }
    }
}
