function Invoke-DemoRetailPriceRequest {
    <#
    .SYNOPSIS
    Calls the public Azure Retail Prices API once, with retries. Internal; tests mock it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Uri
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod -Uri $Uri -Method Get -TimeoutSec 60
        }
        catch {
            if ($attempt -ge 4) {
                throw
            }
            Start-Sleep -Seconds ([System.Math]::Pow(2, $attempt))
        }
    }
}
