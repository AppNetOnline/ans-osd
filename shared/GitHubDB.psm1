#Requires -Version 5.1
<#
.SYNOPSIS
    GitHubDB - Use a GitHub JSON file as a lightweight database table.
.DESCRIPTION
    CRUD operations against a JSON file stored in a GitHub repository,
    using the GitHub Contents API. Every write is a commit — full history included.
.NOTES
    Requirements : PowerShell 5.1+, a GitHub PAT with repo scope
    Concurrent writes are NOT safe — last write wins on sha conflict.
    Connection hashtable keys: Owner, Repo, Path, Token, Branch (optional, defaults to main)
.EXAMPLE
    $conn = @{
        Owner  = 'myorg'
        Repo   = 'my-db-repo'
        Path   = 'data/deployments.json'
        Token  = $pat
        Branch = 'main'
    }

    Add-GHDBRow    -Connection $conn -Row @{ Hostname = 'PC01'; Status = 'Running' }
    Update-GHDBRow -Connection $conn -Id 1 -Updates @{ Status = 'Complete' }
    Get-GHDBRows   -Connection $conn
    Find-GHDBRows  -Connection $conn -Filter { $_.Status -eq 'Complete' }
    Remove-GHDBRow -Connection $conn -Id 1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Private Helpers ────────────────────────────────────────────────────

Function _Headers {
    param([hashtable]$Connection)
    @{
        Authorization          = "Bearer $($Connection.Token)"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

Function _BaseUri {
    param([hashtable]$Connection)
    $branch = if ($Connection.Branch) { $Connection.Branch } else { 'main' }
    "https://api.github.com/repos/$($Connection.Owner)/$($Connection.Repo)/contents/$($Connection.Path)?ref=$branch"
}

Function _GetFileState {
    param([hashtable]$Connection)
    $uri     = _BaseUri  -Connection $Connection
    $headers = _Headers  -Connection $Connection
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET
        $json     = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($response.content -replace '\s'))
        $rows     = $json | ConvertFrom-Json
        if ($null -eq $rows) { $rows = @() }
        if ($rows -isnot [System.Collections.IEnumerable] -or $rows -is [string]) { $rows = @($rows) }
        Return @{ Rows = @($rows); Sha = $response.sha }
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            Write-Verbose 'GitHubDB: file not found — will create on first write.'
            Return @{ Rows = @(); Sha = $null }
        }
        throw
    }
}

Function _PutFileState {
    param(
        [hashtable] $Connection,
        [object[]]  $Rows,
        [string]    $Sha,
        [string]    $CommitMessage
    )
    $branch  = if ($Connection.Branch) { $Connection.Branch } else { 'main' }
    $uri     = "https://api.github.com/repos/$($Connection.Owner)/$($Connection.Repo)/contents/$($Connection.Path)"
    $headers = _Headers -Connection $Connection
    $json    = $Rows | ConvertTo-Json -Depth 10 -Compress:$false
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
    $body    = @{ message = $CommitMessage; content = $encoded; branch = $branch }
    if ($Sha) { $body.sha = $Sha }
    Invoke-RestMethod -Uri $uri -Headers $headers -Method PUT `
        -Body ($body | ConvertTo-Json -Depth 5) -ContentType 'application/json' | Out-Null
}

Function _NextId {
    param([object[]]$Rows)
    if ($Rows.Count -eq 0) { Return 1 }
    ($Rows | ForEach-Object { [int]($_.id) } | Measure-Object -Maximum).Maximum + 1
}

#endregion

#region ── Public Functions ───────────────────────────────────────────────────

Function Get-GHDBRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Connection)
    (_GetFileState -Connection $Connection).Rows
}

Function Find-GHDBRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]  $Connection,
        [Parameter(Mandatory)][scriptblock]$Filter
    )
    (_GetFileState -Connection $Connection).Rows | Where-Object $Filter
}

Function Add-GHDBRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][hashtable]$Row
    )
    $state  = _GetFileState -Connection $Connection
    $newRow = [ordered]@{ id = (_NextId -Rows $state.Rows) }
    foreach ($k in $Row.Keys) { $newRow[$k] = $Row[$k] }
    $newRow['_created'] = (Get-Date -Format 'o')
    $state.Rows += [pscustomobject]$newRow
    _PutFileState -Connection $Connection -Rows $state.Rows -Sha $state.Sha `
        -CommitMessage "db: add row id=$($newRow.id)"
    Return [pscustomobject]$newRow
}

Function Update-GHDBRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][int]      $Id,
        [Parameter(Mandatory)][hashtable]$Updates
    )
    $state  = _GetFileState -Connection $Connection
    $target = $state.Rows | Where-Object { [int]$_.id -eq $Id }
    if (-not $target) { throw "GitHubDB: no row with id=$Id." }
    foreach ($k in $Updates.Keys) {
        $target | Add-Member -MemberType NoteProperty -Name $k -Value $Updates[$k] -Force
    }
    $target | Add-Member -MemberType NoteProperty -Name '_updated' -Value (Get-Date -Format 'o') -Force
    _PutFileState -Connection $Connection -Rows $state.Rows -Sha $state.Sha `
        -CommitMessage "db: update row id=$Id"
    Return $target
}

Function Remove-GHDBRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][int]      $Id
    )
    $state  = _GetFileState -Connection $Connection
    $before = $state.Rows.Count
    $state.Rows = @($state.Rows | Where-Object { [int]$_.id -ne $Id })
    if ($state.Rows.Count -eq $before) { throw "GitHubDB: no row with id=$Id." }
    _PutFileState -Connection $Connection -Rows $state.Rows -Sha $state.Sha `
        -CommitMessage "db: remove row id=$Id"
}

Function Clear-GHDBTable {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][hashtable]$Connection)
    if ($PSCmdlet.ShouldProcess("$($Connection.Owner)/$($Connection.Repo)/$($Connection.Path)", 'Clear all rows')) {
        $state = _GetFileState -Connection $Connection
        _PutFileState -Connection $Connection -Rows @() -Sha $state.Sha `
            -CommitMessage 'db: clear table'
    }
}

#endregion

Export-ModuleMember -Function Get-GHDBRows, Find-GHDBRows, Add-GHDBRow, Update-GHDBRow, Remove-GHDBRow, Clear-GHDBTable
