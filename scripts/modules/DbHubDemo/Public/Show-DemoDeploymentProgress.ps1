function Show-DemoDeploymentProgress {
    <#
    .SYNOPSIS
    Shows deploy.ps1's live status in the console, from the same progress model as the status page (Phase 28, brief
    item 11): the banner (Deploying, no action needed; Waiting for you; Done; or Stopped, not done), then each track's
    steps with their state, elapsed time, and message. status.ps1 -Watch calls it.

    .DESCRIPTION
    Reads out/deploy-progress.json, which deploy.ps1 and its track processes update at each step. With -Watch it draws
    the view again every -IntervalSeconds until the run is Done or Stopped (deploy.ps1 ended, or stopped updating the
    model: its window closed, or the PC slept or restarted), or Ctrl+C. It reads only the local file, so it works
    anywhere deploy.ps1 runs, GitHub Codespaces included, and calls nothing in Azure. Every line comes from the model,
    which holds no secrets, and is redacted again before it's written.

    Returns the banner's kind when it stops (Deploying, Waiting, Done, or Stopped), or None when there's no model on
    this machine: status.ps1 then reads Azure instead.

    .PARAMETER Path
    The progress model (default out/deploy-progress.json).

    .PARAMETER Watch
    Keep drawing until the run is Done or Stopped.

    .PARAMETER IntervalSeconds
    How often -Watch draws again (default 5).

    .PARAMETER MaxRefresh
    Stop -Watch after this many views (0, the default: no limit).

    .EXAMPLE
    Show-DemoDeploymentProgress -Watch
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'An operator console view; every line comes from the redacted progress model and is redacted again.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Path = '',

        [switch] $Watch,

        [ValidateRange(2, 60)]
        [int] $IntervalSeconds = 5,

        [ValidateRange(0, 1000000)]
        [int] $MaxRefresh = 0
    )

    $Path = Resolve-DemoUserPath -Path $Path
    if (-not $Path) {
        $Path = (Get-DemoProgressPath).Model
    }
    $count = 0
    while ($true) {
        $model = Read-DemoProgress -Path $Path
        if ($null -eq $model) {
            return 'None'
        }
        $width = 120
        try {
            if (-not [System.Console]::IsOutputRedirected -and [System.Console]::WindowWidth -gt 0) {
                $width = [System.Math]::Max(60, [System.Math]::Min(200, [System.Console]::WindowWidth - 1))
            }
        }
        catch {
            $width = 120
        }
        $banner = Get-DemoProgressBanner -Model $model
        $lines = @(Format-DemoProgressConsole -Model $model -Width $width)
        if ($Watch -and $count -gt 0) {
            try {
                if (-not [System.Console]::IsOutputRedirected) {
                    Clear-Host
                }
            }
            catch {
                Write-Debug -Message 'The console couldn''t be cleared.'
            }
        }
        $color = switch ($banner.Kind) { 'Waiting' { 'Yellow' } 'Done' { 'Green' } 'Stopped' { 'Red' } default { 'Cyan' } }
        # The banner is everything up to the second rule line; the steps follow in the default color.
        $rules = 0
        foreach ($line in $lines) {
            $lineColor = if ($rules -lt 2) { $color } else { 'White' }
            if ($line -match '^=+$') {
                $rules++
            }
            Write-DemoConsoleBlock -Color $lineColor -Line @($line)
        }
        $count++
        if (-not $Watch -or $banner.Kind -in 'Done', 'Stopped' -or ($MaxRefresh -gt 0 -and $count -ge $MaxRefresh)) {
            return [string]$banner.Kind
        }
        Write-DemoConsoleBlock -Color 'Gray' -Line @(('Refreshing every {0} seconds; Ctrl+C stops watching (deploy.ps1 keeps running).' -f $IntervalSeconds))
        Start-Sleep -Seconds $IntervalSeconds
    }
}
