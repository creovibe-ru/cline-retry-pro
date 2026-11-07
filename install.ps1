#Requires -Version 5.1
<#
.SYNOPSIS
    Cline Retry Pro - установщик патча авто-повтора для расширения Cline.
.DESCRIPTION
    Патчит бандлы установленного расширения saoudrizwan.claude-dev:
      1) увеличивает число и суммарное время повторов;
      2) учит Cline считать временными текстовые ошибки провайдера
         ("Upstream capacity is temporarily exhausted", 429/503 и подобные);
      3) разрешает повтор, если ошибка пришла уже во время стрима.
    Перед изменением создаются бэкапы *.cline-autoretry*.bak, при неудачной
    проверке файл автоматически восстанавливается.
.PARAMETER Mode
    Apply - применить (по умолчанию), Verify - показать состояние, Revert - откатить.
.PARAMETER ExtensionRoot
    Папка расширения. Если не указана, ищутся VS Code, Insiders, Cursor и Windsurf.
.PARAMETER InstallTask
    Переприменять патч при входе в систему (после обновлений Cline).
.PARAMETER Uninstall
    Убрать задачу планировщика и откатить все изменения.
.EXAMPLE
    iex ((irm https://raw.githubusercontent.com/creovibe-ru/cline-retry-pro/main/install.ps1).Trim([char]0xFEFF))
#>

[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Verify', 'Revert')]
    [string]$Mode = 'Apply',
    [string]$ExtensionRoot,
    [switch]$InstallTask,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$Repo = 'creovibe-ru/cline-retry-pro'
$Branch = 'main'
$Raw = 'https://raw.githubusercontent.com/' + $Repo + '/' + $Branch
$TaskName = 'Cline Retry Pro'
$ScriptNames = @('patch-cline-retry.ps1', 'patch-cline-retry-logic.ps1')

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host $Message -ForegroundColor $Color
}

function Get-ScriptsDir {
    if ($PSScriptRoot) {
        $local = Join-Path $PSScriptRoot 'patch-cline-retry-logic.ps1'
        if (Test-Path -LiteralPath $local) { return $PSScriptRoot }
    }

    $dir = Join-Path $env:LOCALAPPDATA 'cline-retry-pro'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    foreach ($name in $ScriptNames) {
        $dst = Join-Path $dir $name
        Write-Step ('  загрузка ' + $name + '...') 'DarkGray'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri ($Raw + '/' + $name) -OutFile $dst
        }
        catch {
            if (Test-Path -LiteralPath $dst) {
                Write-Step '  обновить не удалось, использую сохранённую копию' 'Yellow'
            }
            else {
                throw ('Не удалось скачать ' + $name + ': ' + $_.Exception.Message)
            }
        }
    }

    return $dir
}

function Find-ExtensionRoots {
    $bases = @(
        (Join-Path $env:USERPROFILE '.vscode\extensions'),
        (Join-Path $env:USERPROFILE '.vscode-insiders\extensions'),
        (Join-Path $env:USERPROFILE '.cursor\extensions'),
        (Join-Path $env:USERPROFILE '.windsurf\extensions')
    )

    $found = @()
    foreach ($base in $bases) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $dirs = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^saoudrizwan\.claude-dev-\d+(\.\d+)+$' })
        foreach ($d in $dirs) {
            if ($found -notcontains $d.FullName) { $found += $d.FullName }
        }
    }
    return $found
}

function Invoke-PatchScript {
    param([string]$ScriptPath, [string]$Root, [string]$Mode)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Mode $Mode -ExtensionRoot $Root
}

$scriptsDir = Get-ScriptsDir
Write-Step ('Скрипты: ' + $scriptsDir) 'DarkGray'

if ($Uninstall) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Step '  задача планировщика удалена' 'Green'
    } catch { }
    $Mode = 'Revert'
}

if ($ExtensionRoot) {
    if (-not (Test-Path -LiteralPath $ExtensionRoot)) { throw ('Папка не найдена: ' + $ExtensionRoot) }
    $roots = @((Resolve-Path -LiteralPath $ExtensionRoot).Path)
} else {
    $roots = @(Find-ExtensionRoots)
}

if ($roots.Count -eq 0) {
    throw 'Расширение Cline не найдено. Укажите папку вручную: -ExtensionRoot "...\saoudrizwan.claude-dev-4.1.26"'
}

foreach ($root in $roots) {
    Write-Step ''
    Write-Step ('== ' + $root) 'White'
    # Патчеры правят одни и те же бандлы, поэтому откат идёт в обратном порядке:
    # бэкап логики снят уже после таймингового патча, и вернуть его первым значит
    # оставить тайминговый патч в файле.
    $order = $ScriptNames
    if ($Mode -eq 'Revert') { $order = @($ScriptNames[($ScriptNames.Count - 1)..0]) }
    foreach ($name in $order) {
        $path = Join-Path $scriptsDir $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        Invoke-PatchScript -ScriptPath $path -Root $root -Mode $Mode
    }
}

if ($InstallTask -and $Mode -ne 'Revert') {
    $self = $PSCommandPath
    if (-not $self) { $self = Join-Path $scriptsDir 'install.ps1' }
    if (-not (Test-Path -LiteralPath $self)) {
        try { Invoke-WebRequest -UseBasicParsing -Uri ($Raw + '/install.ps1') -OutFile $self } catch { }
    }
    if (Test-Path -LiteralPath $self) {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode Apply' -f $self)
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Переприменяет патч Cline Retry Pro после обновлений Cline' -Force | Out-Null
        Write-Step '  задача переприменения установлена' 'Green'
    }
    else {
        Write-Step '  не удалось сохранить install.ps1 - задача переприменения не установлена' 'Yellow'
    }
}

if ($Mode -eq 'Apply') {
    Write-Step ''
    Write-Step 'Готово. Перезагрузите окно: Ctrl+Shift+P -> Developer: Reload Window' 'Yellow'
}
