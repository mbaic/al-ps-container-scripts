#Requires -Version 5.1
#Requires -Modules BcContainerHelper
<#
.SYNOPSIS
    Interactive admin menu for Business Central Docker containers (BcContainerHelper).

.DESCRIPTION
    Menu-driven wrapper around BcContainerHelper for day-to-day dev-container work:
    restart / stop, status, logs, remove + cache cleanup, license import,
    permission fix for AL Test Runner, listing / uninstalling non-Microsoft apps,
    dependency-ordered install / upgrade of apps from a folder, service-tier event log,
    database backup / restore, company copy / delete and a container-specific API access guide.

    Safety rules this script follows:
      - The container is only changed through BcContainerHelper cmdlets (no raw docker writes).
      - Every destructive step shows exactly what it will do and needs an explicit y (Enter = No).
      - Defaults are the non-destructive choice (keep app data, artifacts-only cache cleanup).

    To add an operation: write one function and add one line to $script:MenuItems.

.PARAMETER ContainerName
    Container pre-selected as the default target. If omitted or not found, the first
    running BC container is used. Every container operation still asks which container
    to run on (Enter = current); operations marked * also accept several (1,3 / 1-3 / A).

.PARAMETER LicenseFile
    License file offered by default in "Import license".

.PARAMETER Tenant
    Tenant used for all app operations. Default: 'default'.

.PARAMETER ExcludedPublisher
    Publishers hidden from the "non-Microsoft apps" operations. Default: 'Microsoft'.

.EXAMPLE
    .\Admin.Containers.AsMenu.ps1

.EXAMPLE
    .\Admin.Containers.AsMenu.ps1 -ContainerName bcdev -LicenseFile 'D:\Licenses\dev.bclicense'

.NOTES
    Requires BcContainerHelper 6.x on Windows PowerShell 5.1 or PowerShell 7.
    Keep this file saved as UTF-8 *with BOM*, otherwise Windows PowerShell 5.1 garbles the box characters.
    Run with -Verbose to get script stack traces when an operation fails.
    Database backups are stored in <hostHelperFolder>\Backups\<container>\<timestamp>[_label]
    (by default C:\ProgramData\BcContainerHelper\Backups). Nothing deletes them automatically.
#>
[CmdletBinding()]
param(
    [string]   $ContainerName,
    [string]   $LicenseFile       = 'C:\Downloads\BC-License.bclicense',
    [ValidateNotNullOrEmpty()]
    [string]   $Tenant            = 'default',
    [string[]] $ExcludedPublisher = @('Microsoft')
)

# Preferences apply to this script only. $ErrorActionPreference is deliberately left at
# 'Continue': under Windows PowerShell 5.1 in VS Code, 'Stop' turns docker's stderr output
# into terminating errors. BcContainerHelper throws on real failures, and the menu
# dispatcher catches anything an operation doesn't handle itself.
$ProgressPreference = 'SilentlyContinue'

# The script relies on PowerShell's default (non-strict) semantics, e.g. properties that
# BcContainerHelper objects only sometimes have. If the calling session enabled strict mode
# (profile, VS Code, another script), turn it off for this script's scope only; the caller's
# own setting is not changed (unless the script is dot-sourced).
Set-StrictMode -Off

#region ── UI helpers ──────────────────────────────────────────────────────────────

$script:BannerWidth = 71

function Write-Banner {
    param([Parameter(Mandatory)][string] $Title, [ConsoleColor] $TitleColor = 'Green')
    $w     = $script:BannerWidth
    $left  = [int][math]::Max(0, [math]::Floor(($w - $Title.Length) / 2))
    $right = [int][math]::Max(0, $w - $left - $Title.Length)
    Write-Host ''
    Write-Host ('╔' + ('═' * $w) + '╗') -ForegroundColor Cyan
    Write-Host ('║' + (' ' * $w) + '║') -ForegroundColor Cyan
    Write-Host '║' -NoNewline -ForegroundColor Cyan
    Write-Host ((' ' * $left) + $Title + (' ' * $right)) -NoNewline -ForegroundColor $TitleColor
    Write-Host '║' -ForegroundColor Cyan
    Write-Host ('║' + (' ' * $w) + '║') -ForegroundColor Cyan
    Write-Host ('╚' + ('═' * $w) + '╝') -ForegroundColor Cyan
    Write-Host ''
}

function Write-Header {
    param([Parameter(Mandatory)][string] $Title, [ConsoleColor] $Color = 'Yellow')
    Write-Host ''
    Write-Host "━━━ $Title ━━━" -ForegroundColor $Color
    Write-Host ''
}

function Write-Step { param([string] $Text) Write-Host "[→] $Text" -ForegroundColor Gray }
function Write-Ok   { param([string] $Text) Write-Host "[✓] $Text" -ForegroundColor Green }
function Write-Note { param([string] $Text) Write-Host "[i] $Text" -ForegroundColor Cyan }
function Write-Warn { param([string] $Text) Write-Host "[!] $Text" -ForegroundColor Yellow }
function Write-Fail { param([string] $Text) Write-Host "[✗] $Text" -ForegroundColor Red }

function Write-KeyValue {
    # Aligned "  Key........ value" line used for all result summaries.
    param([Parameter(Mandatory)][string] $Key, $Value, [ConsoleColor] $Color = 'White')
    Write-Host ('  {0} {1}' -f $Key.PadRight(28, '.'), $Value) -ForegroundColor $Color
}

function Format-Fit {
    # Pads or truncates text to an exact column width so tables stay aligned.
    param([string] $Text, [int] $Width)
    if ($Text.Length -gt $Width) { return $Text.Substring(0, $Width - 1) + '…' }
    $Text.PadRight($Width)
}

function Wait-Continue { [void](Read-Host 'Press Enter to continue') }

function Read-YesNo {
    # Yes/No prompt that re-asks on invalid input; Enter returns the default.
    param([Parameter(Mandatory)][string] $Prompt, [bool] $Default = $false)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = "$(Read-Host "$Prompt [$hint]")".Trim()
        if (-not $answer)              { return $Default }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$')  { return $false }
        Write-Warn 'Please answer Y or N.'
    }
}

function Confirm-Action {
    # Final y/N confirmation before a change. The question must name exactly what will happen.
    # Default is No: only "y" / "yes" proceeds, Enter cancels.
    param([Parameter(Mandatory)][string] $Question)
    if (Read-YesNo -Prompt $Question -Default $false) { return $true }
    Write-Warn 'Operation cancelled.'
    $false
}

function ConvertFrom-SelectionText {
    # "1,3,5-7" -> distinct 0-based indexes within 1..$Count, in the order given.
    param([Parameter(Mandatory)][string] $Text, [Parameter(Mandatory)][int] $Count)
    $result = New-Object System.Collections.Generic.List[int]
    foreach ($token in $Text.Split(',')) {
        $t = $token.Trim()
        if (-not $t) { continue }
        if     ($t -match '^(\d+)\s*-\s*(\d+)$') { $from = [int]$Matches[1]; $to = [int]$Matches[2] }
        elseif ($t -match '^\d+$')               { $from = [int]$t;          $to = $from }
        else   { Write-Warn "Ignored invalid entry '$t'"; continue }

        if ($from -gt $to) { $from, $to = $to, $from }
        if ($from -lt 1 -or $to -gt $Count) { Write-Warn "Ignored out-of-range part of '$t' (valid: 1-$Count)" }
        $from = [math]::Max($from, 1)
        $to   = [math]::Min($to, $Count)
        for ($n = $from; $n -le $to; $n++) {
            if (-not $result.Contains($n - 1)) { $result.Add($n - 1) }
        }
    }
    , $result.ToArray()
}

#endregion

#region ── Container helpers ───────────────────────────────────────────────────────

function Get-ContainerState {
    # 'running', 'exited', 'paused', ... or $null when the container does not exist.
    # One read-only 'docker ps' call: cheap enough to run on every menu render.
    param([string] $Name)
    if (-not $Name) { return $null }
    foreach ($line in @(docker ps -a --format '{{.Names}}|{{.State}}')) {
        $parts = "$line".Split('|')
        if ($parts[0] -eq $Name) { return $parts[1] }
    }
    $null
}

function Get-ContainerList {
    # BC containers (BcContainerHelper's definition) with their docker state, sorted by name.
    $states = @{}
    foreach ($line in @(docker ps -a --format '{{.Names}}|{{.State}}')) {
        $parts = "$line".Split('|')
        if ($parts.Count -eq 2) { $states[$parts[0]] = $parts[1] }
    }
    @(Get-BcContainers) | Where-Object { $_ } | Sort-Object | ForEach-Object {
        [pscustomobject]@{ Name = "$_"; State = $states["$_"] }
    }
}

function Get-StateColor {
    param([string] $State)
    if ($State -eq 'running') { 'Green' } elseif ($State) { 'Yellow' } else { 'Red' }
}

function Read-TargetContainer {
    # Asks which container(s) the chosen operation runs on and outputs their names (nothing when
    # cancelled). Numbers refer to the list on the menu screen; Enter keeps the current container.
    # With -AllowMultiple: "1,3", "1-3" and "A" (all) are accepted as well.
    param(
        [object[]] $Containers = @($script:Containers),
        [string]   $Current    = $script:ContainerName,
        [switch]   $AllowMultiple
    )
    $list = @($Containers)
    if ($list.Count -eq 1) { return $list[0].Name }   # nothing to choose
    $prompt = if ($AllowMultiple) { "Run on container(s) # (e.g. 2 | 1,3 | 1-3 | A = all, Enter = $Current, C = cancel)" }
              else                { "Run on container # (Enter = $Current, C = cancel)" }
    while ($true) {
        $choice = "$(Read-Host $prompt)".Trim().TrimStart('#')
        if (-not $choice)    { return $Current }
        if ($choice -eq 'C') { return }
        if ($AllowMultiple -and $choice -eq 'A') { return $list | ForEach-Object { $_.Name } }

        if ($choice -match '^\d+$') {
            $index = [int]$choice - 1
            if ($index -ge 0 -and $index -lt $list.Count) { return $list[$index].Name }
        }
        elseif ($AllowMultiple -and $choice -match '^[\d\s,-]+$') {
            # Plain assignment on purpose: the function emits its array as one object, and @(...)
            # around an empty result would give a 1-element array holding an empty array.
            $indexes = ConvertFrom-SelectionText -Text $choice -Count $list.Count
            if (@($indexes).Count) { return $indexes | ForEach-Object { $list[$_].Name } }
        }
        else {
            $match = $list | Where-Object { $_.Name -eq $choice } | Select-Object -First 1
            if ($match) { return $match.Name }
        }
        Write-Fail "'$choice' is not a valid choice from the container list."
    }
}

function Get-SharedValue {
    # Runs $Ask and returns its result. During a multi-container run the question is asked for the
    # first container only and the answer is reused for the others; otherwise it is asked every time.
    param(
        [Parameter(Mandatory)][string]      $Key,
        [Parameter(Mandatory)][scriptblock] $Ask,
        [string] $Label = $Key
    )
    if ($null -ne $script:SharedAnswers -and $script:SharedAnswers.ContainsKey($Key)) {
        $value = $script:SharedAnswers[$Key]
        Write-Host ('  ↺ {0}: {1} (same as the first container)' -f $Label, $value) -ForegroundColor DarkGray
        return $value
    }
    $value = & $Ask
    if ($null -ne $script:SharedAnswers) { $script:SharedAnswers[$Key] = $value }
    $value
}

function Invoke-MultiContainerAction {
    # Runs one operation on several containers, one after another. Shared questions
    # (Get-SharedValue) are asked once; a failure on one container does not stop the others.
    # The current container is left unchanged.
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)][string[]] $Containers
    )
    $previous = $script:ContainerName
    $script:SharedAnswers = @{}
    $results = New-Object System.Collections.Generic.List[object]
    try {
        for ($i = 0; $i -lt $Containers.Count; $i++) {
            $name = $Containers[$i]
            $script:ContainerName = $name
            Write-Host ''
            Write-Host ('═══ [{0}/{1}] {2} ═══' -f ($i + 1), $Containers.Count, $name) -ForegroundColor Magenta
            try {
                & $Item.Action
                $results.Add([pscustomobject]@{ Container = $name; Ok = $true; Detail = '' })
            }
            catch {
                Write-Fail "Failed on '$name': $($_.Exception.Message)"
                Write-Verbose $_.ScriptStackTrace
                $results.Add([pscustomobject]@{ Container = $name; Ok = $false; Detail = $_.Exception.Message })
            }
        }
    }
    finally {
        $script:SharedAnswers = $null
        $script:ContainerName = $previous
    }

    Write-Host ''
    Write-Host "Summary - $($Item.Label):" -ForegroundColor Cyan
    foreach ($r in $results) {
        $text = if ($r.Ok) { '✓ Finished' } else { "✗ Failed - $($r.Detail)" }
        Write-Host ('  {0} {1}' -f (Format-Fit $r.Container 30), $text) -ForegroundColor $(if ($r.Ok) { 'Green' } else { 'Red' })
    }
    $results
}

function Test-ContainerExists {
    if (Get-ContainerState $script:ContainerName) { return $true }
    Write-Fail "Container '$script:ContainerName' no longer exists."
    $false
}

function Confirm-ContainerRunning {
    # $true when the container is running; offers to start it otherwise.
    $state = Get-ContainerState $script:ContainerName
    if ($state -eq 'running') { return $true }
    if (-not $state) {
        Write-Fail "Container '$script:ContainerName' no longer exists."
        return $false
    }
    Write-Warn "Container '$script:ContainerName' is $state - this operation needs it running."
    if (-not (Read-YesNo 'Start it now?' -Default $true)) { return $false }
    Write-Step 'Starting container and waiting until it is ready...'
    Start-BcContainer -containerName $script:ContainerName
    $true
}

function Get-ContainerApp {
    # Published apps with tenant state (IsInstalled, SyncState, ExtensionDataVersion).
    # -tenantSpecificProperties is required: without it IsInstalled is not populated.
    param(
        [switch] $ThirdPartyOnly,
        [ValidateSet('None', 'DependenciesFirst', 'DependenciesLast')]
        [string] $Sort = 'None'
    )
    $query = {
        Get-BcContainerAppInfo -containerName $script:ContainerName -tenant $script:Tenant `
            -tenantSpecificProperties -sort $Sort
    }
    try {
        $apps = & $query
    }
    catch {
        # "Get-NavAppInfo is not recognized" and similar are almost always a stale cached
        # PowerShell session (e.g. container restarted outside this script). Reset, retry once.
        Write-Warn "App query failed: $($_.Exception.Message)"
        Write-Step 'Resetting the container session and retrying...'
        Remove-BcContainerSession -containerName $script:ContainerName
        $apps = & $query
    }
    $apps | Where-Object {
        $null -ne $_ -and (-not $ThirdPartyOnly -or $script:ExcludedPublisher -notcontains $_.Publisher)
    }
}

function Get-InstallPlanEntry {
    # Decides what to do with one .app file. Pure function (no container access), so the
    # decision table is unit-tested. Downgrades are skipped: BC cannot install a lower
    # version over a higher one.
    param(
        [Parameter(Mandatory)] $Manifest,      # app.json content: id, name, publisher, version
        [object[]] $CurrentApps = @(),         # Get-BcContainerAppInfo -tenantSpecificProperties output
        [string] $File
    )
    $version       = [version]"$($Manifest.version)"
    $sameId        = @($CurrentApps | Where-Object { $_ -and "$($_.AppId)" -eq "$($Manifest.id)" })
    $installed     = $sameId | Where-Object { $_.IsInstalled } | Select-Object -First 1
    $samePublished = [bool]($sameId | Where-Object { [version]"$($_.Version)" -eq $version })

    $action = 'Install'; $detail = 'new'
    if ($installed) {
        $installedVersion = [version]"$($installed.Version)"
        if     ($version -gt $installedVersion) { $action = 'Upgrade'; $detail = "v$installedVersion → v$version" }
        elseif ($version -eq $installedVersion) { $action = 'Skip';    $detail = 'same version installed' }
        else                                    { $action = 'Skip';    $detail = "downgrade from v$installedVersion not supported" }
    }
    elseif ($samePublished) { $detail = 'already published, not installed' }
    elseif ($sameId.Count)  { $detail = 'other version published' }

    [pscustomobject]@{
        File          = $File
        Name          = "$($Manifest.name)"
        Publisher     = "$($Manifest.publisher)"
        Version       = $version
        Action        = $action
        Detail        = $detail
        SamePublished = $samePublished
        Installed     = $installed
    }
}

function Get-AppKey {
    param($App)
    '{0}|{1}' -f $App.AppId, $App.Version
}

function Show-AppTable {
    param([object[]] $Apps)
    $Apps | Sort-Object Publisher, Name, Version |
        Format-Table -AutoSize -Property Publisher, Name, Version, IsInstalled, SyncState |
        Out-Host   # Out-Host keeps tables in order with the surrounding Write-Host output
}

function Get-BackupRoot {
    # Backups must live under the BcContainerHelper host folder: that folder is shared into the
    # container, which is what lets SQL Server inside the container write the .bak files.
    Join-Path $bcContainerHelperConfig.hostHelperFolder "Backups\$script:ContainerName"
}

function Invoke-DatabaseBackup {
    # Backs up the container database(s) to <hostHelperFolder>\Backups\<container>\<timestamp>[_label]
    # and returns that folder. Single-tenant: database.bak; multitenant: app.bak + <tenant>.bak.
    param([string] $Label)
    $folderName = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeLabel  = ($Label -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
    if ($safeLabel) { $folderName += "_$safeLabel" }
    $folder = Join-Path (Get-BackupRoot) $folderName
    New-Item -Path $folder -ItemType Directory -Force | Out-Null

    Write-Step "Backing up database to $folder ..."
    Backup-BcContainerDatabases -containerName $script:ContainerName -bakFolder $folder   # no -compress: SQL Express can't
    $files = @(Get-ChildItem -LiteralPath $folder -Filter '*.bak' -File)
    if ($files.Count -eq 0) { throw "Backup reported success but no .bak file exists in $folder" }
    $sizeMb = [math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
    Write-Ok "Backup created: $folderName ($($files.Count) file(s), $sizeMb MB)"
    $folder
}

function Get-ContainerCompany {
    Get-CompanyInBcContainer -containerName $script:ContainerName -tenant $script:Tenant |
        Where-Object { $_ -and $_.CompanyName } |
        Sort-Object CompanyName
}

function Read-CompanyChoice {
    # Numbered company picker. Returns the company name, or $null when cancelled.
    param([Parameter(Mandatory)][object[]] $Companies, [string] $Prompt = 'Company #')
    for ($i = 0; $i -lt $Companies.Count; $i++) {
        $c = $Companies[$i]
        Write-Host ('  [{0,2}] {1}' -f ($i + 1), $c.CompanyName) -NoNewline -ForegroundColor White
        Write-Host $(if ($c.EvaluationCompany) { '  (evaluation)' } else { '' }) -ForegroundColor DarkGray
    }
    Write-Host ''
    while ($true) {
        $choice = "$(Read-Host "$Prompt (Enter = cancel)")".Trim()
        if (-not $choice) { return $null }
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $Companies.Count) {
            return $Companies[[int]$choice - 1].CompanyName
        }
        Write-Fail "'$choice' is not a number from the list."
    }
}

function Format-EventMessage {
    # BC server events start with a block of metadata; surface the lines that matter.
    param([string] $Message, [int] $MaxLength = 400)
    $lines = @($Message -split '\r?\n' | Where-Object { $_.Trim() })
    $key   = @($lines | Where-Object { $_ -match '^\s*(Message|Type|User|Session type|AL CallStack)\s*:' })
    $show  = if ($key.Count) { $key } else { $lines | Select-Object -First 6 }
    foreach ($line in $show) {
        $clean = ($line -replace '</?ii>', '').Trim()
        if ($clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength - 1) + '…' }
        $clean
    }
}

function Write-Guide {
    # Renders guide lines (Kind/Text objects) in the terminal.
    param([Parameter(Mandatory)][object[]] $Lines)
    foreach ($line in $Lines) {
        switch ($line.Kind) {
            'Title' { Write-Host $line.Text -ForegroundColor Green }
            'Head'  { Write-Host ''; Write-Host $line.Text -ForegroundColor Cyan }
            'Code'  { Write-Host "    $($line.Text)" -ForegroundColor White }
            'Ok'    { Write-Host "  $($line.Text)" -ForegroundColor Green }
            'Warn'  { Write-Host "  $($line.Text)" -ForegroundColor Yellow }
            default { Write-Host "  $($line.Text)" -ForegroundColor Gray }
        }
    }
}

function ConvertTo-GuideMarkdown {
    # Same guide lines as Markdown: consecutive Code lines become one fenced block.
    param([Parameter(Mandatory)][object[]] $Lines)
    $sb     = New-Object System.Text.StringBuilder
    $inCode = $false
    foreach ($line in $Lines) {
        if ($line.Kind -eq 'Code' -and -not $inCode) { [void]$sb.AppendLine('```'); $inCode = $true }
        if ($line.Kind -ne 'Code' -and $inCode)      { [void]$sb.AppendLine('```'); $inCode = $false }
        switch ($line.Kind) {
            'Title' { [void]$sb.AppendLine("# $($line.Text)") }
            'Head'  { [void]$sb.AppendLine(''); [void]$sb.AppendLine("## $($line.Text)") }
            'Code'  { [void]$sb.AppendLine($line.Text) }
            default { [void]$sb.AppendLine("- $($line.Text)") }
        }
    }
    if ($inCode) { [void]$sb.AppendLine('```') }
    $sb.ToString()
}

#endregion

#region ── Operations (one function per menu item) ─────────────────────────────────

function Restart-SelectedContainer {
    Write-Header 'Restart container'
    if (-not (Test-ContainerExists)) { return }
    Write-Step "Restarting '$script:ContainerName' and waiting until it is ready..."
    Restart-BcContainer -containerName $script:ContainerName
    Write-Host ''
    Write-KeyValue 'Container' '✓ Restarted' Green
}

function Stop-SelectedContainer {
    Write-Header 'Stop container'
    if (-not (Test-ContainerExists)) { return }
    if ((Get-ContainerState $script:ContainerName) -ne 'running') {
        Write-Note "Container '$script:ContainerName' is not running - nothing to do."
        return
    }
    Write-Step "Stopping '$script:ContainerName'..."
    Stop-BcContainer -containerName $script:ContainerName
    Write-Host ''
    Write-KeyValue 'Container' '✓ Stopped' Green
}

function Show-ContainerStatus {
    Write-Header 'Container status'
    Write-Host 'Business Central containers:' -ForegroundColor Cyan
    @(Get-BcContainers -includeLabels) |
        Sort-Object name |
        Format-Table -AutoSize -Property name, status, version, country, platform, image |
        Out-Host

    Write-Host 'Resource usage (running containers):' -ForegroundColor Cyan
    Write-Host ''
    docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}' | Out-Host
}

function Show-ContainerLog {
    Write-Header 'Container logs'
    if (-not (Test-ContainerExists)) { return }

    $lines = Get-SharedValue -Key 'logs.lines' -Label 'Lines' -Ask {
        $answer = "$(Read-Host 'Number of lines to show (Enter = 50)')".Trim()
        if (-not $answer) { return 50 }
        if ($answer -notmatch '^\d+$' -or [int]$answer -lt 1 -or [int]$answer -gt 100000) {
            Write-Fail "'$answer' is not a number between 1 and 100000."
            return 0
        }
        [int]$answer
    }
    if (-not $lines) { return }
    Write-Step "Last $lines lines from '$script:ContainerName':"
    Write-Host ''
    docker logs --tail $lines $script:ContainerName
}

function Remove-SelectedContainer {
    Write-Header 'Remove container' -Color Red
    if (-not (Test-ContainerExists)) { return }

    Write-Host '⚠  This permanently deletes the container, including its database.' -ForegroundColor Red
    Write-Host ''
    Write-KeyValue 'Container' $script:ContainerName
    Write-Host ''
    Write-Host 'Cache cleanup afterwards:' -ForegroundColor Cyan
    Write-Host '  [1] BC artifacts not used for 2+ days (default)' -ForegroundColor White
    Write-Host '  [2] Full: all helper caches + unused BC images + docker image prune (2+ days)' -ForegroundColor Yellow
    Write-Host '  [3] No cache cleanup' -ForegroundColor White
    $flush = "$(Read-Host 'Cleanup option (Enter = 1)')".Trim()
    if (-not $flush) { $flush = '1' }
    if ($flush -notin '1', '2', '3') {
        Write-Fail "Invalid option '$flush' - operation cancelled."
        return
    }
    Write-Host ''
    if (-not (Confirm-Action "Permanently delete container '$($script:ContainerName)'?")) { return }

    Write-Host ''
    Write-Step 'Removing container...'
    Remove-BcContainer -containerName $script:ContainerName   # stops it first (docker rm -f)
    $removed = $script:ContainerName
    $script:ContainerName = $null   # main loop falls back to the first running container

    # Note: BcContainerHelper only matches lower-case cache names, hence 'bcartifacts'.
    switch ($flush) {
        '1' { Write-Step 'Flushing unused BC artifacts...'; Flush-ContainerHelperCache -cache 'bcartifacts' -keepDays 2 }
        '2' { Write-Step 'Flushing all caches and unused images...'; Flush-ContainerHelperCache -cache 'all' -keepDays 2 }
    }

    Write-Host ''
    Write-KeyValue 'Container removed' "✓ $removed" Green
    Write-KeyValue 'Cache cleanup' $(switch ($flush) { '1' { '✓ artifacts' } '2' { '✓ full' } default { 'skipped' } }) Green
}

function Import-ContainerLicense {
    Write-Header 'Import license'
    if (-not (Confirm-ContainerRunning)) { return }

    $path = Get-SharedValue -Key 'license.path' -Label 'License file' -Ask {
        $candidate = $script:LicenseFile
        while ($true) {
            Write-KeyValue 'License file' $(if ($candidate) { $candidate } else { '(none)' }) Cyan
            $answer = "$(Read-Host 'Enter = use this file, or type another path (C = cancel)')".Trim().Trim('"')
            if ($answer -eq 'C') { return '' }
            if ($answer) { $candidate = $answer }
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
            Write-Fail "File not found: $candidate"
            Write-Host ''
        }
    }
    if (-not $path) { Write-Warn 'License import cancelled.'; return }

    $disableScheduler = Get-SharedValue -Key 'license.scheduler' -Label 'Disable Task Scheduler' -Ask {
        Read-YesNo 'Disable the Task Scheduler (job queue) in this container?' -Default $true
    }

    if ($disableScheduler) {
        Write-Step 'Setting EnableTaskScheduler = false...'
        Set-BcContainerServerConfiguration -containerName $script:ContainerName -keyName 'EnableTaskScheduler' -keyValue 'false'
    }
    # The service-tier restart done by -restart also applies the configuration change above,
    # so a full container restart is not needed.
    Write-Step 'Importing license and restarting the service tier...'
    Import-BcContainerLicense -containerName $script:ContainerName -licenseFile $path -restart

    Write-Host ''
    Write-KeyValue 'License imported' '✓' Green
    Write-KeyValue 'Task Scheduler' $(if ($disableScheduler) { 'disabled' } else { 'unchanged' }) Cyan
}

function Repair-HelperPermission {
    Write-Header 'Fix BcContainerHelper permissions (AL Test Runner)'
    Write-Step 'Checking and fixing permissions (may ask for elevation)...'
    Check-BcContainerHelperPermissions -Fix
    Write-Ok 'Done - restart VS Code if AL Test Runner was already open.'
}

function Show-ThirdPartyApp {
    Write-Header 'Non-Microsoft apps'
    if (-not (Confirm-ContainerRunning)) { return }
    Write-Step "Querying apps in '$script:ContainerName' (tenant '$script:Tenant')..."
    $apps = @(Get-ContainerApp -ThirdPartyOnly)
    Write-Host ''
    Write-KeyValue 'Apps found' $apps.Count $(if ($apps.Count) { 'Green' } else { 'Yellow' })
    if ($apps.Count) { Show-AppTable $apps }
}

function Uninstall-ThirdPartyApp {
    Write-Header 'Uninstall / unpublish non-Microsoft apps' -Color Red
    if (-not (Confirm-ContainerRunning)) { return }

    Write-Step "Querying apps in '$script:ContainerName' (tenant '$script:Tenant')..."
    # DependenciesLast = dependents first, which is the order uninstall/unpublish must run in.
    $ordered = @(Get-ContainerApp -ThirdPartyOnly -Sort DependenciesLast)
    if ($ordered.Count -eq 0) { Write-Warn 'No non-Microsoft apps found.'; return }
    $display = @($ordered | Sort-Object Publisher, Name, Version)

    Write-Host ''
    for ($i = 0; $i -lt $display.Count; $i++) {
        $app   = $display[$i]
        $state = if ($app.IsInstalled) { 'Installed' } else { 'Published' }
        Write-Host ('  [{0,2}] {1} {2} v{3,-15} ' -f ($i + 1), (Format-Fit $app.Name 34), (Format-Fit $app.Publisher 20), $app.Version) -NoNewline -ForegroundColor White
        Write-Host $state -ForegroundColor $(if ($app.IsInstalled) { 'Green' } else { 'Gray' })
    }
    Write-Host ''

    $selection = "$(Read-Host 'Apps to process (e.g. 1,3,5-7), A = all, Enter = cancel')".Trim()
    if (-not $selection) { Write-Warn 'Operation cancelled.'; return }
    $indexes = if ($selection -eq 'A') { 0..($display.Count - 1) } else { ConvertFrom-SelectionText -Text $selection -Count $display.Count }
    $keys     = @($indexes | ForEach-Object { Get-AppKey $display[$_] })
    $selected = @($ordered | Where-Object { $keys -contains (Get-AppKey $_) })   # keep dependency order
    if ($selected.Count -eq 0) { Write-Fail 'No valid apps selected.'; return }

    Write-Host ''
    $unpublish  = Read-YesNo 'Also unpublish the selected apps?' -Default $false
    $deleteData = Read-YesNo 'Delete the apps'' table data as well (doNotSaveData)?' -Default $false

    Write-Host ''
    Write-KeyValue 'Container' $script:ContainerName Cyan
    Write-Host ''
    Write-Host 'About to process (in dependency order):' -ForegroundColor Red
    $selected | ForEach-Object { Write-Host "  • $($_.Name) v$($_.Version) by $($_.Publisher)" -ForegroundColor Yellow }
    Write-Host ''
    Write-KeyValue 'Uninstall' 'Yes' Yellow
    Write-KeyValue 'Unpublish' $(if ($unpublish) { 'Yes' } else { 'No' }) $(if ($unpublish) { 'Red' } else { 'Gray' })
    Write-KeyValue 'Delete app data' $(if ($deleteData) { 'Yes' } else { 'No' }) $(if ($deleteData) { 'Red' } else { 'Gray' })
    Write-Host ''
    if (-not (Confirm-Action "Process the $($selected.Count) app(s) listed above in '$($script:ContainerName)'?")) { return }

    Write-Host ''
    $ok = 0; $skipped = 0; $failed = 0
    foreach ($app in $selected) {
        Write-Host "$($app.Name) v$($app.Version)" -ForegroundColor Cyan
        $target = @{
            containerName = $script:ContainerName
            name          = $app.Name
            publisher     = $app.Publisher
            version       = "$($app.Version)"
        }
        try {
            if (-not $app.IsInstalled -and -not $unpublish) {
                Write-Note '  Not installed - nothing to do.'
                $skipped++
                continue
            }
            if ($app.IsInstalled) {
                Write-Step '  Uninstalling...'
                UnInstall-BcContainerApp @target -tenant $script:Tenant -doNotSaveData:$deleteData -Force
                Write-Ok '  Uninstalled'
            }
            if ($unpublish) {
                Write-Step '  Unpublishing...'
                UnPublish-BcContainerApp @target
                Write-Ok '  Unpublished'
            }
            $ok++
        }
        catch {
            Write-Fail "  $($_.Exception.Message)"
            $failed++
        }
    }

    Write-Host ''
    Write-Host 'Summary:' -ForegroundColor Cyan
    Write-KeyValue 'Processed' $selected.Count
    Write-KeyValue 'Successful' $ok Green
    Write-KeyValue 'Skipped' $skipped Gray
    Write-KeyValue 'Failed' $failed $(if ($failed) { 'Red' } else { 'Gray' })

    Write-Host ''
    Write-Step 'Remaining non-Microsoft apps:'
    $remaining = @(Get-ContainerApp -ThirdPartyOnly)
    if ($remaining.Count) { Show-AppTable $remaining } else { Write-Ok 'None left.' }
}

function Install-AppFromFolder {
    Write-Header 'Install / upgrade apps from folder' -Color Cyan
    if (-not (Confirm-ContainerRunning)) { return }

    $folder = "$(Read-Host 'Folder containing .app files (Enter = cancel)')".Trim().Trim('"')
    if (-not $folder) { Write-Warn 'Operation cancelled.'; return }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { Write-Fail "Folder not found: $folder"; return }

    # .alpackages holds downloaded symbols/dependencies, never something to publish.
    $appFiles = @(Get-ChildItem -LiteralPath $folder -Filter '*.app' -File -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/]\.alpackages[\\/]' } |
        Select-Object -ExpandProperty FullName)
    if ($appFiles.Count -eq 0) { Write-Fail 'No .app files found (.alpackages folders are ignored).'; return }

    $unpublishOld = Read-YesNo 'Unpublish superseded versions after a successful upgrade?' -Default $true

    Write-Host ''
    Write-Step 'Sorting apps by dependencies...'
    $sortedFiles = @(Sort-AppFilesByDependencies -containerName $script:ContainerName -appFiles $appFiles)
    Write-Step 'Reading current app state from the container...'
    $current = @(Get-ContainerApp)   # all publishers, so upgrades of any app are detected

    # Build the plan (decision table lives in Get-InstallPlanEntry).
    $plan = @(foreach ($file in $sortedFiles) {
        Get-InstallPlanEntry -Manifest (Get-AppJsonFromAppFile -appFile $file) -CurrentApps $current -File $file
    })

    Write-Host ''
    Write-Host 'Installation plan (dependency order):' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('  {0} {1} {2} {3}' -f (Format-Fit 'App' 34), (Format-Fit 'Publisher' 20), (Format-Fit 'Version' 16), 'Action') -ForegroundColor White
    Write-Host ('  {0} {1} {2} {3}' -f ('-' * 34), ('-' * 20), ('-' * 16), ('-' * 30)) -ForegroundColor DarkGray
    foreach ($p in $plan) {
        $color = switch ($p.Action) { 'Install' { 'Green' } 'Upgrade' { 'Yellow' } default { 'Gray' } }
        Write-Host ('  {0} {1} {2} ' -f (Format-Fit $p.Name 34), (Format-Fit $p.Publisher 20), (Format-Fit "$($p.Version)" 16)) -NoNewline -ForegroundColor White
        Write-Host "$($p.Action) ($($p.Detail))" -ForegroundColor $color
    }

    $toRun = @($plan | Where-Object { $_.Action -ne 'Skip' })
    if ($toRun.Count -eq 0) { Write-Host ''; Write-Note 'Nothing to install or upgrade.'; return }

    Write-Host ''
    Write-KeyValue 'Container' $script:ContainerName
    Write-KeyValue 'Tenant' $script:Tenant
    Write-KeyValue 'Apps to process' $toRun.Count
    Write-KeyValue 'Unpublish old versions' $(if ($unpublishOld) { 'Yes' } else { 'No' })
    Write-Host ''
    if (-not (Confirm-Action "Install / upgrade $($toRun.Count) app(s) in '$($script:ContainerName)'?")) { return }

    Write-Host ''
    $installedCount = 0; $upgradedCount = 0; $failedCount = 0
    $superseded = New-Object System.Collections.Generic.List[object]

    for ($i = 0; $i -lt $toRun.Count; $i++) {
        $p = $toRun[$i]
        Write-Host "[$($i + 1)/$($toRun.Count)] $($p.Name) v$($p.Version) - $($p.Action)" -ForegroundColor Cyan
        try {
            # -install and -upgrade together: BcContainerHelper chooses install vs. data upgrade
            # from the tenant's ExtensionDataVersion, which also covers apps that were
            # uninstalled earlier with their data kept.
            # -ignoreIfAppExists only when this exact version is already published, so the
            # existing package is reused instead of failing with "already published".
            $publishParams = @{
                containerName     = $script:ContainerName
                appFile           = $p.File
                tenant            = $script:Tenant
                skipVerification  = $true
                sync              = $true
                install           = $true
                upgrade           = $true
                ignoreIfAppExists = $p.SamePublished
            }
            Publish-BcContainerApp @publishParams

            if ($p.Action -eq 'Upgrade') {
                $upgradedCount++
                if ($unpublishOld) { $superseded.Add($p.Installed) }
            }
            else { $installedCount++ }
            Write-Ok '  Done'
        }
        catch {
            $failedCount++
            Write-Fail "  $($_.Exception.Message)"
            if ($i -lt $toRun.Count - 1 -and -not (Read-YesNo 'Continue with the remaining apps?' -Default $true)) {
                Write-Warn 'Installation aborted by user.'
                break
            }
        }
        Write-Host ''
    }

    # Unpublish in reverse install order = dependents first.
    $unpublishedCount = 0
    if ($superseded.Count) {
        Write-Step 'Unpublishing superseded versions...'
        for ($i = $superseded.Count - 1; $i -ge 0; $i--) {
            $old = $superseded[$i]
            try {
                UnPublish-BcContainerApp -containerName $script:ContainerName -name $old.Name -publisher $old.Publisher -version "$($old.Version)"
                Write-Ok "  Unpublished $($old.Name) v$($old.Version)"
                $unpublishedCount++
            }
            catch { Write-Fail "  $($old.Name) v$($old.Version): $($_.Exception.Message)" }
        }
        Write-Host ''
    }

    $skippedCount = @($plan | Where-Object { $_.Action -eq 'Skip' }).Count
    Write-Host 'Summary:' -ForegroundColor Cyan
    Write-KeyValue 'Apps in folder' $plan.Count
    Write-KeyValue 'New installs' $installedCount Green
    Write-KeyValue 'Upgrades' $upgradedCount Green
    Write-KeyValue 'Skipped' $skippedCount Gray
    Write-KeyValue 'Failed' $failedCount $(if ($failedCount) { 'Red' } else { 'Gray' })
    if ($superseded.Count) { Write-KeyValue 'Old versions unpublished' "$unpublishedCount / $($superseded.Count)" Yellow }

    if ($installedCount + $upgradedCount -gt 0) {
        Write-Host ''
        Write-Step 'Non-Microsoft apps now in the container:'
        Show-AppTable @(Get-ContainerApp -ThirdPartyOnly)
    }
}

function Show-ServiceTierEventLog {
    Write-Header 'Service-tier event log'
    if (-not (Confirm-ContainerRunning)) { return }

    Write-Host '  [1] Show recent BC server errors here (default)' -ForegroundColor White
    Write-Host '  [2] Open the full Application log in Event Viewer' -ForegroundColor White
    $mode = Get-SharedValue -Key 'eventlog.mode' -Label 'Option' -Ask { "$(Read-Host 'Option (Enter = 1)')".Trim() }
    if ($mode -eq '2') {
        Write-Step 'Exporting the event log from the container...'
        Get-BcContainerEventLog -containerName $script:ContainerName
        Write-Ok "Opened in Event Viewer (copy kept in $(Join-Path $bcContainerHelperConfig.hostHelperFolder 'EventLogs'))."
        return
    }
    if ($mode -and $mode -ne '1') { Write-Fail "Invalid option '$mode'."; return }

    $count = Get-SharedValue -Key 'eventlog.count' -Label 'Errors to show' -Ask {
        $answer = "$(Read-Host 'Number of errors to show (Enter = 10)')".Trim()
        if (-not $answer) { return 10 }
        if ($answer -notmatch '^\d+$' -or [int]$answer -lt 1 -or [int]$answer -gt 200) { Write-Fail "'$answer' is not a number between 1 and 200."; return 0 }
        [int]$answer
    }
    if (-not $count) { return }

    Write-Step "Reading the last $count BC server errors..."
    # Runs inside the container; returns plain objects so nothing depends on remote event types.
    $events = @(Invoke-ScriptInBcContainer -containerName $script:ContainerName -scriptblock {
        Param([int] $max)
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2 } -MaxEvents 2000 -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -like 'MicrosoftDynamics*' } |
            Select-Object -First $max |
            ForEach-Object { [pscustomobject]@{ Time = $_.TimeCreated; Level = $_.LevelDisplayName; Message = "$($_.Message)" } }
    } -argumentList $count | Where-Object { $_ -and $_ -isnot [string] })

    if ($events.Count -eq 0) { Write-Ok 'No BC server errors in the Application log.'; return }
    Write-Host ''
    # Oldest first, so the newest error ends up right above the prompt.
    foreach ($e in ($events | Sort-Object Time)) {
        Write-Host ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f $e.Time, $e.Level) -ForegroundColor Red
        Format-EventMessage $e.Message | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        Write-Host ''
    }
    Write-Note "$($events.Count) error(s) shown. Use option [2] for full messages and stack traces."
}

function Backup-SelectedDatabase {
    Write-Header 'Back up database'
    if (-not (Confirm-ContainerRunning)) { return }
    $label  = Get-SharedValue -Key 'backup.label' -Label 'Label' -Ask { "$(Read-Host 'Optional label, e.g. before-upgrade (Enter = none)')".Trim() }
    $folder = Invoke-DatabaseBackup -Label $label
    Write-Host ''
    Write-KeyValue 'Backup folder' $folder Cyan
}

function Restore-SelectedDatabase {
    Write-Header 'Restore database from backup' -Color Red
    if (-not (Confirm-ContainerRunning)) { return }

    $root    = Get-BackupRoot
    $backups = @()
    if (Test-Path -LiteralPath $root) {
        # Folder names start with a timestamp, so a name sort is a date sort.
        $backups = @(Get-ChildItem -LiteralPath $root -Directory |
            Where-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.bak' -File } |
            Sort-Object Name -Descending)
    }
    if ($backups.Count -eq 0) { Write-Warn "No backups found for '$script:ContainerName' in $root"; return }

    Write-Host "Backups of '$script:ContainerName' (newest first):" -ForegroundColor Cyan
    Write-Host ''
    for ($i = 0; $i -lt $backups.Count; $i++) {
        $mb = [math]::Round((Get-ChildItem -LiteralPath $backups[$i].FullName -Filter '*.bak' -File | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
        Write-Host ('  [{0,2}] {1} {2,10} MB' -f ($i + 1), (Format-Fit $backups[$i].Name 40), $mb) -ForegroundColor White
    }
    Write-Host ''
    $choice = "$(Read-Host 'Backup to restore # (Enter = cancel)')".Trim()
    if (-not $choice) { Write-Warn 'Restore cancelled.'; return }
    if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $backups.Count) { Write-Fail "'$choice' is not a number from the list."; return }
    $backup = $backups[[int]$choice - 1]

    Write-Host ''
    Write-Host '⚠  The current database is replaced: all data, companies and published/installed apps' -ForegroundColor Red
    Write-Host '   go back to the state of the backup. The service tier is stopped during the restore.' -ForegroundColor Red
    Write-Host ''
    Write-KeyValue 'Container' $script:ContainerName
    Write-KeyValue 'Restore from' $backup.Name
    Write-Host ''
    $safetyBackup = Read-YesNo 'Back up the current database first?' -Default $true
    if (-not (Confirm-Action "Replace the database of '$($script:ContainerName)' with backup '$($backup.Name)'?")) { return }

    Write-Host ''
    if ($safetyBackup) { Invoke-DatabaseBackup -Label 'pre-restore' | Out-Null }
    Write-Step 'Restoring (service tier is stopped and started again)...'
    Restore-DatabasesInBcContainer -containerName $script:ContainerName -bakFolder $backup.FullName
    Remove-BcContainerSession -containerName $script:ContainerName   # cached session predates the restore

    Write-Host ''
    Write-KeyValue 'Database restored' "✓ $($backup.Name)" Green
}

function Copy-SelectedCompany {
    Write-Header 'Copy company'
    if (-not (Confirm-ContainerRunning)) { return }

    Write-Step "Reading companies (tenant '$script:Tenant')..."
    $companies = @(Get-ContainerCompany)
    if ($companies.Count -eq 0) { Write-Warn 'No companies found.'; return }
    Write-Host ''
    $source = Read-CompanyChoice -Companies $companies -Prompt 'Source company #'
    if (-not $source) { Write-Warn 'Copy cancelled.'; return }

    $target = "$(Read-Host 'New company name (max 30 characters, Enter = cancel)')".Trim()
    if (-not $target) { Write-Warn 'Copy cancelled.'; return }
    if ($target.Length -gt 30) { Write-Fail "Name is $($target.Length) characters; Business Central allows 30."; return }
    if ($companies | Where-Object { $_.CompanyName -eq $target }) { Write-Fail "Company '$target' already exists."; return }

    Write-Host ''
    Write-KeyValue 'Container' $script:ContainerName
    Write-KeyValue 'Source company' $source
    Write-KeyValue 'New company' $target Green
    Write-Host ''
    if (-not (Read-YesNo 'Copy the company with all its data now?' -Default $true)) { Write-Warn 'Copy cancelled.'; return }

    Write-Step 'Copying (can take a while for large companies)...'
    Copy-CompanyInBcContainer -containerName $script:ContainerName -tenant $script:Tenant -sourceCompanyName $source -destinationCompanyName $target
    Write-Host ''
    Write-KeyValue 'Company created' "✓ $target" Green
}

function Remove-SelectedCompany {
    Write-Header 'Delete company' -Color Red
    if (-not (Confirm-ContainerRunning)) { return }

    Write-Step "Reading companies (tenant '$script:Tenant')..."
    $companies = @(Get-ContainerCompany)
    if ($companies.Count -le 1) { Write-Warn 'Only one company left - deleting it would leave the tenant unusable. Cancelled.'; return }
    Write-Host ''
    $company = Read-CompanyChoice -Companies $companies -Prompt 'Company to delete #'
    if (-not $company) { Write-Warn 'Delete cancelled.'; return }

    Write-Host ''
    Write-Host '⚠  The company and ALL its data are deleted immediately and cannot be recovered' -ForegroundColor Red
    Write-Host '   without a backup. Make sure nobody is working in this company.' -ForegroundColor Red
    Write-Host ''
    Write-KeyValue 'Container' $script:ContainerName
    Write-KeyValue 'Company' $company Red
    Write-Host ''
    $safetyBackup = Read-YesNo 'Back up the database first (recommended by Microsoft)?' -Default $true
    if (-not (Confirm-Action "Permanently delete company '$company' in '$($script:ContainerName)'?")) { return }

    Write-Host ''
    if ($safetyBackup) { Invoke-DatabaseBackup -Label "before-delete-$company" | Out-Null }
    Write-Step "Deleting company '$company'..."
    Remove-CompanyInBcContainer -containerName $script:ContainerName -tenant $script:Tenant -companyName $company
    Write-Host ''
    Write-KeyValue 'Company deleted' "✓ $company" Green
    Write-KeyValue 'Companies left' ((@(Get-ContainerCompany) | ForEach-Object { $_.CompanyName }) -join ', ')
}

function Show-ApiGuide {
    Write-Header 'API access guide'
    if (-not (Confirm-ContainerRunning)) { return }

    $name = $script:ContainerName
    Write-Step "Reading the server configuration of '$name'..."
    $cfg = Get-BcContainerServerConfiguration -ContainerName $name

    $instance  = "$($cfg.ServerInstance)"
    $apiOn     = "$($cfg.ApiServicesEnabled)" -eq 'true'
    $odataOn   = "$($cfg.ODataServicesEnabled)" -eq 'true'
    $ssl       = "$($cfg.ODataServicesSSLEnabled)" -eq 'true'
    $port      = if ("$($cfg.ODataServicesPort)") { "$($cfg.ODataServicesPort)" } else { '7048' }
    $auth      = "$($cfg.ClientServicesCredentialType)"
    $multi     = "$($cfg.Multitenant)" -eq 'true'
    $protocol  = if ($ssl) { 'https' } else { 'http' }
    $isWindowsAuth = $auth -eq 'Windows'
    $isBasic   = $auth -in 'NavUserPassword', 'UserName'

    if (-not $apiOn) {
        Write-Warn 'API services are disabled in this container (calls return HTTP 405).'
        if (Read-YesNo 'Enable them now? This restarts the container.' -Default $false) {
            Set-BcContainerServerConfiguration -containerName $name -keyName 'ApiServicesEnabled' -keyValue 'true'
            Write-Step 'Restarting the container to apply the setting...'
            Restart-BcContainer -containerName $name
            $apiOn = $true
            Write-Ok 'API services enabled.'
        }
    }

    # The container name only resolves on the Docker host (BcContainerHelper adds a hosts entry).
    $hostName = $name
    $resolves = $false
    try { $resolves = [bool]([System.Net.Dns]::GetHostAddresses($name)) } catch { Write-Verbose "'$name' does not resolve: $($_.Exception.Message)" }
    if (-not $resolves) {
        $ip = Get-BcContainerIpAddress -containerName $name
        if ($ip) { $hostName = "$ip" }
    }

    # Published port = reachable from other machines through this host's name.
    $mapping  = @(docker port $name) | Where-Object { "$_" -like "$port/tcp*" } | Select-Object -First 1
    $external = $null
    if ($mapping) { $external = '{0}://{1}:{2}/{3}' -f $protocol, [System.Net.Dns]::GetHostName(), "$mapping".Split(':')[-1], $instance }

    # Optional live check: proves URL, port and credentials work, and gives real company ids.
    $companies  = @()
    $testResult = 'not run'
    if ($apiOn -and ($isWindowsAuth -or $isBasic)) {
        $question = if ($isWindowsAuth) { 'Run a live API test now (uses your Windows login)?' } else { 'Run a live API test now (asks for the BC user name and password)?' }
        if (Read-YesNo $question -Default $true) {
            $cred = $null
            if (-not $isWindowsAuth) { $cred = Get-Credential -Message "BC user for container '$name'" }
            if ($isWindowsAuth -or $cred) {
                Write-Step 'Calling the companies API...'
                try {
                    $apiParams = @{ containerName = $name; tenant = $script:Tenant; APIVersion = 'v2.0'; Query = 'companies'; silent = $true }
                    if ($cred) { $apiParams.credential = $cred }
                    $companies  = @((Invoke-BcContainerApi @apiParams).value | Where-Object { $_ })
                    $testResult = "OK - $($companies.Count) company/companies returned"
                }
                catch { $testResult = "FAILED - $($_.Exception.Message)" }
            }
        }
    }

    # ── Build the guide (no secrets: credentials are never written into it) ──
    $root      = '{0}://{1}:{2}/{3}' -f $protocol, $hostName, $port, $instance
    $tenantQ   = "?tenant=$($script:Tenant)"
    $apiBase   = "$root/api/v2.0"
    $companyId = if ($companies.Count) { "$($companies[0].id)" } else { '<companyId>' }
    $credArg   = if ($isWindowsAuth) { '' } else { ' -credential $cred' }

    $lines = New-Object System.Collections.Generic.List[object]
    $add    = { param([string] $Kind, [string] $Text = '') $lines.Add([pscustomobject]@{ Kind = $Kind; Text = $Text }) }
    $status = { param([string] $Key, [string] $Value, [string] $Kind = 'Text') & $add $Kind ('{0} {1}' -f $Key.PadRight(24, '.'), $Value) }

    & $add Title "Business Central API access - $name"
    & $add Text  "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by BC Container Admin. Values are read from the container."

    & $add Head 'Status'
    & $status 'Server instance' $instance
    & $status 'API services' $(if ($apiOn) { 'enabled' } else { 'DISABLED - see "Enable API services" below' }) $(if ($apiOn) { 'Ok' } else { 'Warn' })
    & $status 'OData services' $(if ($odataOn) { 'enabled' } else { 'disabled' }) $(if ($odataOn) { 'Ok' } else { 'Warn' })
    & $status 'Authentication' $(switch ($auth) { 'Windows' { 'Windows (your Windows login)' } 'NavUserPassword' { 'NavUserPassword (Basic: BC user + password)' } default { "$auth (token-based)" } })
    & $status 'Protocol / port' "$protocol / $port"
    & $status 'Host name' $(if ($resolves) { "'$name' resolves on this machine" } else { "'$name' does not resolve here - using container IP $hostName" }) $(if ($resolves) { 'Ok' } else { 'Warn' })
    & $status 'Multitenant' $(if ($multi) { "yes - ?tenant=$($script:Tenant) is required" } else { 'no (?tenant= is harmless)' })
    & $status 'From other machines' $(if ($external) { $external } else { "not reachable - port $port not published (New-BcContainer -PublishPorts $port)" })
    & $status 'Live test' $testResult $(if ($testResult -like 'OK*') { 'Ok' } elseif ($testResult -like 'FAILED*') { 'Warn' } else { 'Text' })

    if ($companies.Count) {
        & $add Head 'Companies (from the live test)'
        foreach ($c in $companies) { & $add Text ('{0}  {1}' -f "$($c.id)", "$($c.name)") }
    }

    if (-not $apiOn) {
        & $add Head 'Enable API services'
        & $add Code "Set-BcContainerServerConfiguration -containerName '$name' -keyName ApiServicesEnabled -keyValue true"
        & $add Code "Restart-BcContainer -containerName '$name'"
    }

    & $add Head 'Endpoints'
    & $add Code ('GET {0}/companies{1}' -f $apiBase, $tenantQ)
    & $add Code ('GET {0}/companies({1})/customers{2}' -f $apiBase, $companyId, $tenantQ)
    & $add Code ('GET {0}/api/<publisher>/<group>/<version>/companies({1})/<entitySet>{2}' -f $root, $companyId, $tenantQ)
    & $add Code ('GET {0}/$metadata{1}' -f $apiBase, $tenantQ)
    & $add Code ('GET {0}/ODataV4/Company(''<company name>'')/<publishedServiceName>{1}' -f $root, $tenantQ)

    & $add Head 'PowerShell - BcContainerHelper (simplest: resolves URL, port, SSL and auth)'
    if (-not $isWindowsAuth) { & $add Code '$cred = Get-Credential   # BC user of this container' }
    & $add Code ("Invoke-BcContainerApi -containerName '{0}' -tenant '{1}'{2} -APIVersion 'v2.0' -Query 'companies'" -f $name, $script:Tenant, $credArg)
    & $add Code ("Invoke-BcContainerApi -containerName '{0}' -tenant '{1}'{2} -APIVersion 'v2.0' -CompanyId '{3}' -Query 'customers'" -f $name, $script:Tenant, $credArg, $companyId)
    & $add Code ("Invoke-BcContainerApi -containerName '{0}' -tenant '{1}'{2} -APIPublisher '<publisher>' -APIGroup '<group>' -APIVersion 'v1.0' -CompanyId '{3}' -Query '<entitySet>'" -f $name, $script:Tenant, $credArg, $companyId)

    & $add Head 'PowerShell - plain Invoke-RestMethod (works in 5.1 and 7)'
    $url = '{0}/companies{1}' -f $apiBase, $tenantQ
    if ($isWindowsAuth) {
        & $add Code ("(Invoke-RestMethod -Uri '{0}' -UseDefaultCredentials).value" -f $url)
    }
    else {
        & $add Code '$cred  = Get-Credential'
        & $add Code '$extra = @{}'
        if ($ssl) { & $add Code 'if ($PSVersionTable.PSVersion.Major -ge 6) { $extra.SkipCertificateCheck = $true }            # self-signed container certificate' }
        else      { & $add Code 'if ($PSVersionTable.PSVersion.Major -ge 6) { $extra.AllowUnencryptedAuthentication = $true }  # PS 7 blocks credentials over http otherwise' }
        & $add Code ("(Invoke-RestMethod -Uri '{0}' -Credential `$cred @extra).value" -f $url)
    }

    & $add Head 'curl'
    $k = if ($ssl) { ' -k' } else { '' }
    if ($isWindowsAuth) { & $add Code ('curl.exe --ntlm -u :{0} "{1}"' -f $k, $url) }
    else            { & $add Code ('curl.exe -u <username>{0} "{1}"      # prompts for the password' -f $k, $url) }

    & $add Head 'VS Code REST Client / Postman'
    if ($isBasic) {
        & $add Code "GET $url"
        & $add Code 'Authorization: Basic <username> <password>'
        & $add Text 'Postman: Authorization type "Basic Auth" with the BC user name and password.'
    }
    elseif ($isWindowsAuth) {
        & $add Code "GET $url"
        & $add Text 'Postman: Authorization type "NTLM Authentication" with your Windows account.'
    }
    else {
        & $add Text "This container uses '$auth': requests need an OAuth bearer token (Invoke-BcContainerApi -bcAuthContext)."
    }

    & $add Head 'Troubleshooting'
    & $add Text '405 Method Not Allowed: API services disabled - see Status.'
    & $add Text '401 Unauthorized: wrong user or password; PowerShell 7 over http also needs -AllowUnencryptedAuthentication.'
    & $add Text 'Host not found: the container name resolves only on the Docker host; use the IP, or publish the port.'
    & $add Text 'Certificate errors: container uses SSL with a self-signed certificate - use -SkipCertificateCheck (PS 7) or curl -k.'
    & $add Text 'Standard API returns empty data although it exists: run "API Setup" > "Integrate APIs" in Business Central.'

    # ── Output ──
    Write-Host ''
    Write-Guide -Lines $lines
    Write-Host ''
    $markdown = ConvertTo-GuideMarkdown -Lines $lines
    while ($true) {
        $choice = "$(Read-Host '[C] Copy to clipboard   [O] Open in editor   [Enter] Back')".Trim().ToUpperInvariant()
        switch ($choice) {
            ''  { return }
            'C' { Set-Clipboard -Value $markdown; Write-Ok 'Guide copied to the clipboard (Markdown, no passwords).' }
            'O' {
                $file = Join-Path ([System.IO.Path]::GetTempPath()) "BC-API-$name.md"
                [System.IO.File]::WriteAllText($file, $markdown, (New-Object System.Text.UTF8Encoding($false)))
                try   { Invoke-Item -LiteralPath $file }
                catch { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$file`"" }
                Write-Ok "Opened $file"
            }
            default { Write-Warn "Invalid choice '$choice'." }
        }
    }
}

#endregion

#region ── Menu ────────────────────────────────────────────────────────────────────

# Single source of truth for the menu: add an operation by adding one line here.
# Target = $true -> the operation runs on a container chosen right after the operation.
# Multi  = $true -> it may also run on several containers (never for Danger operations).
$script:MenuItems = @(
    @{ Key = '1'; Group = 'Container Management';    Label = 'Restart container';                           Target = $true; Multi = $true; Action = { Restart-SelectedContainer } }
    @{ Key = '2'; Group = 'Container Management';    Label = 'Stop container';                              Target = $true; Multi = $true; Action = { Stop-SelectedContainer } }
    @{ Key = '3'; Group = 'Container Management';    Label = 'View status & resources (all containers)';                    Action = { Show-ContainerStatus } }
    @{ Key = '4'; Group = 'Container Management';    Label = 'View container logs';                         Target = $true; Multi = $true; Action = { Show-ContainerLog } }
    @{ Key = 'E'; Group = 'Container Management';    Label = 'Service-tier event log (BC errors)';          Target = $true; Multi = $true; Action = { Show-ServiceTierEventLog } }
    @{ Key = 'A'; Group = 'Container Management';    Label = 'API access guide (URLs, auth, snippets)';     Target = $true; Action = { Show-ApiGuide } }
    @{ Key = '5'; Group = 'Configuration & Cleanup'; Label = 'Remove container & clean up cache';           Target = $true; Action = { Remove-SelectedContainer }; Danger = $true }
    @{ Key = '6'; Group = 'Configuration & Cleanup'; Label = 'Import license';                              Target = $true; Multi = $true; Action = { Import-ContainerLicense } }
    @{ Key = 'P'; Group = 'Configuration & Cleanup'; Label = 'Fix BcContainerHelper permissions (AL Test)';                 Action = { Repair-HelperPermission } }
    @{ Key = '7'; Group = 'Application Management';  Label = 'Show non-Microsoft apps';                     Target = $true; Multi = $true; Action = { Show-ThirdPartyApp } }
    @{ Key = '8'; Group = 'Application Management';  Label = 'Uninstall / unpublish non-Microsoft apps';    Target = $true; Action = { Uninstall-ThirdPartyApp }; Danger = $true }
    @{ Key = '9'; Group = 'Application Management';  Label = 'Install / upgrade apps from folder';          Target = $true; Action = { Install-AppFromFolder } }
    @{ Key = 'B'; Group = 'Database & Companies';    Label = 'Back up database';                            Target = $true; Multi = $true; Action = { Backup-SelectedDatabase } }
    @{ Key = 'R'; Group = 'Database & Companies';    Label = 'Restore database from backup';                Target = $true; Action = { Restore-SelectedDatabase }; Danger = $true }
    @{ Key = 'C'; Group = 'Database & Companies';    Label = 'Copy company';                                Target = $true; Action = { Copy-SelectedCompany } }
    @{ Key = 'D'; Group = 'Database & Companies';    Label = 'Delete company';                              Target = $true; Action = { Remove-SelectedCompany }; Danger = $true }
)

# Normalize: every item gets every flag (missing ones = $false), so the menu code never reads
# a key that is not there - safe even if strict mode were enabled.
$script:MenuItems = @($script:MenuItems | ForEach-Object {
        [pscustomobject]@{
            Key    = $_['Key']
            Group  = $_['Group']
            Label  = $_['Label']
            Action = $_['Action']
            Target = [bool]$_['Target']
            Multi  = [bool]$_['Multi']
            Danger = [bool]$_['Danger']
        }
    })

function Show-Menu {
    Write-Banner 'BC Container Admin'

    Write-Host '  Containers' -ForegroundColor Gray
    for ($i = 0; $i -lt $script:Containers.Count; $i++) {
        $c         = $script:Containers[$i]
        $isCurrent = $c.Name -eq $script:ContainerName
        Write-Host ('    #{0,-3}{1} ' -f ($i + 1), (Format-Fit $c.Name 30)) -NoNewline -ForegroundColor $(if ($isCurrent) { 'Cyan' } else { 'White' })
        Write-Host (Format-Fit $(if ($c.State) { $c.State } else { 'unknown' }) 10) -NoNewline -ForegroundColor (Get-StateColor $c.State)
        Write-Host $(if ($isCurrent) { ' ◄ current' } else { '' }) -ForegroundColor Cyan
    }
    Write-Host ''
    Write-Host '  Tenant: ' -NoNewline -ForegroundColor Gray
    Write-Host $script:Tenant -ForegroundColor White
    Write-Host '  * = can run on several containers' -ForegroundColor DarkGray

    $groups = $script:MenuItems | ForEach-Object { $_.Group } | Select-Object -Unique
    foreach ($group in $groups) {
        Write-Host ''
        Write-Host "  $group" -ForegroundColor Gray
        foreach ($item in ($script:MenuItems | Where-Object { $_.Group -eq $group })) {
            $marker = if ($item.Multi) { ' *' } else { '' }
            Write-Host ('    [{0}] {1}{2}' -f $item.Key, $item.Label, $marker) -ForegroundColor $(if ($item.Danger) { 'Red' } else { 'White' })
        }
    }
    Write-Host ''
    Write-Host '    [Q] Quit   (Enter = refresh)' -ForegroundColor Gray
    Write-Host ''
}

function Start-AdminMenu {
    $originalTitle = $null
    try { $originalTitle = $Host.UI.RawUI.WindowTitle } catch { Write-Verbose 'Host has no window title' }

    try {
        if ($script:ContainerName -and -not (Get-ContainerState $script:ContainerName)) {
            Write-Warn "Container '$script:ContainerName' not found - using the first running container instead."
            Wait-Continue
        }

        while ($true) {
            # Re-read on every render so containers created/removed elsewhere show up.
            $script:Containers = @(Get-ContainerList)
            if ($script:Containers.Count -eq 0) {
                Write-Fail 'No Business Central containers found (is Docker running?).'
                break
            }
            if (-not ($script:Containers | Where-Object { $_.Name -eq $script:ContainerName })) {
                # Current container gone (or none yet): default to the first running one.
                $script:ContainerName = (@($script:Containers | Where-Object { $_.State -eq 'running' }) + $script:Containers)[0].Name
            }
            try { $Host.UI.RawUI.WindowTitle = "BC Container Admin - $script:ContainerName" } catch { Write-Verbose 'Host has no window title' }

            Clear-Host
            Show-Menu
            $key = "$(Read-Host 'Select operation')".Trim().ToUpperInvariant()
            if (-not $key) { continue }   # Enter = refresh
            if ($key -eq 'Q') { break }

            $item = $script:MenuItems | Where-Object { $_.Key -eq $key } | Select-Object -First 1
            if (-not $item) {
                Write-Warn "Invalid choice '$key'."
                Wait-Continue
                continue
            }

            $targets = @()
            if ($item.Target) {
                $targets = @(Read-TargetContainer -AllowMultiple:([bool]$item.Multi))
                if ($targets.Count -eq 0) {
                    Write-Warn 'Operation cancelled.'
                    Wait-Continue
                    continue
                }
            }

            # Central error boundary: an operation failure never kills the menu.
            try {
                if ($targets.Count -gt 1) {
                    Invoke-MultiContainerAction -Item $item -Containers $targets | Out-Null
                }
                else {
                    if ($targets.Count -eq 1) { $script:ContainerName = $targets[0] }   # new default for the next operation
                    & $item.Action
                }
            }
            catch {
                Write-Host ''
                Write-Fail "Operation failed: $($_.Exception.Message)"
                Write-Verbose $_.ScriptStackTrace
            }
            Write-Host ''
            Wait-Continue
        }
    }
    finally {
        if ($null -ne $originalTitle) { try { $Host.UI.RawUI.WindowTitle = $originalTitle } catch { Write-Verbose 'Host has no window title' } }
    }

    Write-Banner 'Thank you for using BC Container Admin'
}

#endregion

Start-AdminMenu
