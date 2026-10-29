function Start-DemoDeploymentRun {
    <#
    .SYNOPSIS
    Starts one deploy.ps1 run's experience (Phase 28): keeps the PC awake, writes the progress model and the status
    page and opens it, and prints the start banner with the expected timeline, the person's part, and the notices.

    .DESCRIPTION
    - Keep-awake: Enter-DemoKeepAwake (Windows; deploy.ps1 calls Exit-DemoKeepAwake in its finally block).
    - Progress: out/deploy-progress.json with the steps of every track (Get-DemoProgressCatalog), and
      out/deploy-status.html, rewritten every 10 seconds by a thread job of this process and opened in the default
      browser (Open-DemoProgressPage; in GitHub Codespaces it prints how to preview it). Not in GitHub Actions, and not
      with -NoStatusPage.
    - The banner: Get-DemoDeploymentExpectation and Get-DemoDeploymentNotice, through the redacting console writer.
    Returns ProgressPath, PagePath, Writer, KeepAwake, StartedUtc, Command, Environment, InstallMode, and WaitForT2, for
    Invoke-DemoDeployment and Complete-DemoDeploymentRun.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER ConfigPath
    The configuration file deploy.ps1 read; a path other than config/demo.config.json goes into every command printed.

    .PARAMETER WaitForT2
    Whether this run waits for T2's build and the guided stop.

    .PARAMETER T2WaitMinutes
    How long it waits for them.

    .PARAMETER SkipFabric
    The run skips the Fabric track.

    .PARAMETER NoStatusPage
    Write no progress model or status page.

    .PARAMETER NoBrowser
    Don't open the status page in a browser.

    .PARAMETER OutputDirectory
    Where the model and the page go (default out/).

    .EXAMPLE
    $run = Start-DemoDeploymentRun -Config $config -WaitForT2
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [switch] $WaitForT2,

        [ValidateRange(0, 600)]
        [int] $T2WaitMinutes = 180,

        [switch] $SkipFabric,

        [switch] $NoStatusPage,

        [switch] $NoBrowser,

        [string] $OutputDirectory = ''
    )

    $environment = Get-DemoRunEnvironment
    $installMode = (Get-DemoArcTarget -Config $Config).InstallMode
    $paths = Get-DemoProgressPath -Directory $OutputDirectory
    $command = Get-DemoDeployCommand -ConfigPath $ConfigPath
    $expect = Get-DemoDeploymentExpectation -InstallMode $installMode -WaitForT2:$WaitForT2 -T2WaitMinutes $T2WaitMinutes
    $run = [pscustomobject]@{
        ProgressPath = ''
        PagePath     = ''
        Writer       = $null
        KeepAwake    = $false
        StartedUtc   = [System.DateTime]::UtcNow
        Command      = $command
        Environment  = $environment
        InstallMode  = $installMode
        WaitForT2    = [bool]$WaitForT2
    }
    if (-not $PSCmdlet.ShouldProcess($paths.Model, 'Write the status page and keep this PC awake')) {
        return $run
    }
    $run.KeepAwake = Enter-DemoKeepAwake
    $pageLine = ''
    if (-not $NoStatusPage -and -not $environment.GitHubActions) {
        $catalog = Get-DemoProgressCatalog -InstallMode $installMode -T4Enabled:(Test-DemoT4Enabled -Config $Config) -SkipFabric:$SkipFabric
        $model = New-DemoProgressModel -Catalog $catalog -Environment ([string]$Config['environment']) -ResourceGroup (Get-DemoResourceGroupName -Config $Config) -Command $command -PagePath $paths.Page -Expect @{ text = $expect.Text; humanText = $expect.HumanText; guidedStop = $expect.GuidedStop } -GuidedStop $(if ($expect.GuidedStop) { 'Pending' } else { 'NotSelected' })
        try {
            Initialize-DemoProgress -Path $paths.Model -Model $model -Confirm:$false
            Write-DemoProgressPage -ModelPath $paths.Model -PagePath $paths.Page
            $run.ProgressPath = $paths.Model
            $run.PagePath = $paths.Page
            $run.Writer = Start-DemoProgressPageWriter -ModelPath $paths.Model -PagePath $paths.Page
            $pageLine = Open-DemoProgressPage -PagePath $paths.Page -NoBrowser:($NoBrowser -or $environment.Ci)
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The status page couldn''t be set up, so the console is the only view: {0}' -f $_.Exception.Message)
        }
    }
    $notices = Get-DemoDeploymentNotice -Environment $environment -InstallMode $installMode -WaitForT2:$WaitForT2 -PagePath $run.PagePath
    Write-DemoConsoleBlock -Color 'Cyan' -Line (Get-DemoBannerLine -Title ('deploy.ps1: environment {0}, resource group {1}' -f $Config['environment'], (Get-DemoResourceGroupName -Config $Config)))
    Write-DemoConsoleBlock -Color 'White' -Line $expect.Lines
    $more = @(
        $(if ($run.KeepAwake) { 'This PC stays awake until deploy.ps1 ends.' })
        $pageLine
    ) | Where-Object { $_ }
    Write-DemoConsoleBlock -Color 'Gray' -Line @($more)
    Write-DemoConsoleBlock -Color 'Yellow' -Line $notices
    return $run
}
