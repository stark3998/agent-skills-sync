[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Prune
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$mappings = @(
    @{ Source = Join-Path $repoRoot 'claude\agents'; Destination = Join-Path $HOME '.claude\agents' },
    @{ Source = Join-Path $repoRoot 'claude\skills'; Destination = Join-Path $HOME '.claude\skills' },
    @{ Source = Join-Path $repoRoot 'agents\skills'; Destination = Join-Path $HOME '.agents\skills' },
    @{ Source = Join-Path $repoRoot 'agents\hooks'; Destination = Join-Path $HOME '.agents\hooks' },
    @{ Source = Join-Path $repoRoot 'vscode-user\prompts'; Destination = Join-Path $env:APPDATA 'Code\User\prompts' }
)

function Copy-MappedTree {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Warning "Skipping missing source: $Source"
        return
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination | Out-Null
    }

    $robocopyArgs = @(
        $Source,
        $Destination,
        '/E',
        '/R:2',
        '/W:1',
        '/NFL',
        '/NDL',
        '/NP'
    )

    if ($Prune) {
        $robocopyArgs += '/MIR'
    }

    if ($PSCmdlet.ShouldProcess($Destination, "Copy from $Source")) {
        & robocopy @robocopyArgs | Out-Host
        $exitCode = $LASTEXITCODE
        if ($exitCode -gt 7) {
            throw "robocopy failed with exit code $exitCode while copying $Source"
        }
    }
}

foreach ($mapping in $mappings) {
    Copy-MappedTree -Source $mapping.Source -Destination $mapping.Destination
}

Write-Host 'Import complete.'
