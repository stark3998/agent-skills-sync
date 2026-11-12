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
    @{ Source = Join-Path $repoRoot 'copilot\agents'; Destination = Join-Path $HOME '.copilot\agents' },
    @{ Source = Join-Path $repoRoot 'copilot\instructions'; Destination = Join-Path $HOME '.copilot\instructions' },
    @{ Source = Join-Path $repoRoot 'copilot\skills'; Destination = Join-Path $HOME '.copilot\skills' },
    @{ Source = Join-Path $repoRoot 'copilot\hooks'; Destination = Join-Path $HOME '.copilot\hooks' },
    @{ Source = Join-Path $repoRoot 'github\hooks'; Destination = Join-Path $HOME '.github\hooks' },
    @{ Source = Join-Path $repoRoot 'vscode-user\prompts'; Destination = Join-Path $env:APPDATA 'Code\User\prompts' }
)

$fileMappings = @(
    @{ Source = Join-Path $repoRoot 'copilot\copilot-instructions.md'; Destination = Join-Path $HOME '.copilot\copilot-instructions.md' },
    @{ Source = Join-Path $repoRoot 'copilot\mcp-config.json'; Destination = Join-Path $HOME '.copilot\mcp-config.json' },
    @{ Source = Join-Path $repoRoot 'vscode-user\mcp.json'; Destination = Join-Path $env:APPDATA 'Code\User\mcp.json' }
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

function Copy-MappedFile {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        Write-Warning "Skipping missing source: $Source"
        return
    }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }

    if ($PSCmdlet.ShouldProcess($Destination, "Copy from $Source")) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
}

foreach ($mapping in $mappings) {
    Copy-MappedTree -Source $mapping.Source -Destination $mapping.Destination
}

foreach ($mapping in $fileMappings) {
    Copy-MappedFile -Source $mapping.Source -Destination $mapping.Destination
}

Write-Host 'Import complete.'
