[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Prune
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

$mappings = @(
    @{ Source = Join-Path $HOME '.claude\agents'; Destination = Join-Path $repoRoot 'claude\agents' },
    @{ Source = Join-Path $HOME '.claude\skills'; Destination = Join-Path $repoRoot 'claude\skills' },
    @{ Source = Join-Path $HOME '.agents\skills'; Destination = Join-Path $repoRoot 'agents\skills' },
    @{ Source = Join-Path $HOME '.agents\hooks'; Destination = Join-Path $repoRoot 'agents\hooks' },
    @{ Source = Join-Path $env:APPDATA 'Code\User\prompts'; Destination = Join-Path $repoRoot 'vscode-user\prompts' }
)

$excludeDirectoryNames = @(
    '.git',
    'backups',
    'downloads',
    'file-history',
    'ide',
    'plans',
    'projects',
    'session-env',
    'sessions',
    'shell-snapshots',
    'telemetry'
)

$excludeFilePatterns = @(
    '.credentials.json',
    'credentials.json',
    '*.token',
    '*.secret',
    '*.key',
    '.env',
    '.env.*',
    '*.pem',
    '*.pfx',
    '*.p12',
    '*.log',
    '*.tmp'
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

    if ($excludeDirectoryNames.Count -gt 0) {
        $robocopyArgs += '/XD'
        $robocopyArgs += $excludeDirectoryNames
    }

    if ($excludeFilePatterns.Count -gt 0) {
        $robocopyArgs += '/XF'
        $robocopyArgs += $excludeFilePatterns
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

Write-Host 'Export complete. Review with: git status --short'
