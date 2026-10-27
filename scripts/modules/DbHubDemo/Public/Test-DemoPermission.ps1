function Test-DemoPermission {
    <#
    .SYNOPSIS
    Tests whether an action is allowed by the effective permissions that Azure RBAC returns.

    .DESCRIPTION
    Takes the 'value' array from the Microsoft.Authorization/permissions API. Each entry is one role
    assignment's actions and notActions; the action is allowed when any entry allows it and that same
    entry doesn't exclude it. Wildcards follow Azure RBAC: '*' and segment wildcards such as
    'Microsoft.Compute/*'. Deny assignments aren't evaluated.

    .EXAMPLE
    Test-DemoPermission -Permission $permissions.value -Action 'Microsoft.Resources/deployments/write'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Permission,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Action
    )

    foreach ($entry in $Permission) {
        $allowed = @($entry.actions | Where-Object { $Action -like $_ }).Count -gt 0
        $excluded = @($entry.notActions | Where-Object { $Action -like $_ }).Count -gt 0
        if ($allowed -and -not $excluded) {
            return $true
        }
    }

    return $false
}
