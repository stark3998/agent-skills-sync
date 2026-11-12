# Telemetry tracking hook for Azure Copilot Skills
# Reads JSON input from stdin, tracks relevant events, and publishes telemetry
# Exit codes: 0 = hook continues, including telemetry failures
#
# === Client Format Reference ===
#
# Copilot CLI:
#   - Field names:    camelCase (toolName, sessionId, toolArgs)
#   - Tool names:     lowercase (skill, view)
#   - MCP prefix:     azure-<command>  (e.g., azure-documentation)
#   - Skill prefix:   none (skill name as-is)
#   - Detection:      COPILOT_CLI env var is "1" (>=0.0.421); fallback: "toolArgs" without "hook_event_name" (<0.0.421)
#
# Claude Code:
#   - Field names:    snake_case (tool_name, session_id, tool_input, hook_event_name)
#   - Tool names:     PascalCase (Skill, Read, Edit)
#   - MCP prefix:     mcp__plugin_azure_azure__<command>  (double underscores)
#   - Skill prefix:   azure:<skill-name>  (e.g., azure:azure-prepare)
#   - Detection:      has "hook_event_name", tool_use_id does NOT contain "__vscode"
#
# Cursor:
#   - Field names:    snake_case (tool_name, session_id, tool_input, hook_event_name)
#   - Tool names:     PascalCase for file reads (Read); raw MCP tool name from afterMCPExecution
#   - Skill paths:    .cursor/plugins/cache/<catalog>/azure/<revision>/skills/<name>/SKILL.md
#   - Detection:      has "hook_event_name" and "cursor_version"
#   - MCP detection:  afterMCPExecution event with mcp_server_name "azure"
#
# VS Code:
#   - Field names:    snake_case (tool_name, session_id, tool_input, hook_event_name)
#   - Tool names:     snake_case (read_file, replace_string_in_file)
#   - MCP prefix:     mcp_azure_mcp_<command>  (e.g., mcp_azure_mcp_documentation)
#   - Skill paths:    .vscode/agent-plugins/github.com/microsoft/azure-skills/.github/plugins/azure-skills/skills/<name>/SKILL.md          (VS Code)
#                     .vscode-insiders/agent-plugins/github.com/microsoft/azure-skills/.github/plugins/azure-skills/skills/<name>/SKILL.md (VS Code Insiders)
#                     .agents/skills/<name>/SKILL.md
#   - Detection:      has "hook_event_name", tool_use_id contains "__vscode"
#                     or transcript_path contains "Code"
#   - Client name:    "Visual Studio Code" (stable) or "Visual Studio Code - Insiders"
#                     derived from transcript_path (e.g., .../Code - Insiders/User/...)
#   - Note:           Skills under .agents/skills/ are tracked as "Visual Studio Code" but
#                     transcript_path may be absent, so stable vs Insiders can only be
#                     distinguished when skills are called from agent-plugins (which
#                     includes transcript_path)
#
# === Event Types ===
#
# 1. skill_invocation
#    - Triggered when: the "skill"/"Skill" tool is called with a skill name,
#      OR a SKILL.md file is read from a recognized azure-skills path
#    - Tracked fields: --skill-name <name>, --skill-version <version>
#
# 2. tool_invocation
#    - Triggered when: a tool matching an Azure MCP prefix is called
#      (azure-*, mcp__plugin_azure_azure__*, mcp_azure_mcp_*), or when Cursor
#      sends afterMCPExecution with mcp_server_name "azure"
#    - Tracked field: --tool-name <toolName>
#
# 3. reference_file_read
#    - Triggered when: a file read tool (view/Read/read_file) targets a file
#      inside a recognized azure-skills path that is NOT a SKILL.md
#    - These are the reference/instruction files that skills bundle alongside
#      SKILL.md (e.g., recipes, templates, requirement docs)
#    - Tracked fields: --file-reference <relative-path-after-skills/>,
#      --skill-version <version>
#
# 4. session_start
#    - Triggered when: a client starts or resumes an agent session
#    - Tracked fields: --plugin-name <name>, --plugin-version <version>,
#      --client-name <client>, and --session-id <id>
#
# === Plugin and Skill Versions ===
#
# The plugin name and version are read from the active client's plugin.json:
#   - Copilot CLI / VS Code: .plugin/plugin.json
#   - Claude Code:           .claude-plugin/plugin.json
#   - Cursor:                .cursor-plugin/plugin.json
#
# The skill version is read from the SKILL.md frontmatter (metadata.version),
# which the build stamps at package time. It is resolved as follows:
#   - skill/Skill tool call: locate SKILL.md relative to this script's plugin
#     root ("<plugin-root>/skills/<name>/SKILL.md")
#   - SKILL.md read:          read the version from the SKILL.md being read
#   - reference_file_read:    read the version from the sibling SKILL.md at the
#                             root of the skill folder the reference lives in
#    - Example: azure-validate/references/recipes/azd/README.md
#
# === Plugin Identity ===
#
# Every tracked event includes the plugin name and version read from the
# installed copy's .plugin/plugin.json manifest. This lets the existing
# telemetry receiver attribute sibling-plugin events without adding fields.
#
# === Reference File Detection ===
#
# When a file read tool is invoked (Copilot CLI: "view", Claude Code/Cursor:
# "Read", VS Code: "read_file"), the script extracts the file path from the tool input
# and checks if it falls within a recognized azure-skills folder:
#
#   Path field lookup order:
#     - toolArgs.path / toolArgs.filePath       (Copilot CLI)
#     - tool_input.filePath / tool_input.file_path / tool_input.path  (Claude Code / VS Code)
#
#   Recognized install paths (one set per plugin, see $pathPatterns below):
#     azure-skills:
#     - .copilot/installed-plugins/<catalog-name>/azure/skills/...
#       (<catalog-name> is the marketplace/catalog folder the plugin was
#       installed under, e.g. "awesome-copilot" — it does not necessarily
#       match the plugin's own name, "azure")
#     - .claude/plugins/cache/azure-skills/azure/<version>/skills/...
#     - .claude/plugins/cache/claude-plugins-official/azure/<version>/skills/...
#     - .cursor/plugins/cache/<catalog-name>/azure/<revision>/skills/...
#     - .vscode/agent-plugins/github.com/microsoft/azure-skills/.github/plugins/azure-skills/skills/...
#     azure-kusto-graph-skills:
#     - .copilot/installed-plugins/<catalog-name>/azure-kusto-graph-skills/skills/...
#     - .claude/plugins/cache/azure-skills/azure-kusto-graph-skills/<version>/skills/...
#     - .cursor/plugins/cache/<catalog-name>/azure-kusto-graph-skills/<revision>/skills/...
#     - .vscode/agent-plugins/github.com/microsoft/azure-skills/.github/plugins/azure-kusto-graph-skills/skills/...
#     aks-skills:
#     - .copilot/installed-plugins/<catalog-name>/aks-skills/skills/...
#     - .claude/plugins/cache/azure-skills/aks-skills/<version>/skills/...
#     - .cursor/plugins/cache/<catalog-name>/aks-skills/<revision>/skills/...
#     - .vscode/agent-plugins/github.com/microsoft/azure-skills/.github/plugins/aks-skills/skills/...
#     azure-local-skills:
#     - .copilot/installed-plugins/<catalog-name>/azure-local-skills/skills/...
#     - .claude/plugins/cache/azure-skills/azure-local-skills/<version>/skills/...
#     - .cursor/plugins/cache/<catalog-name>/azure-local-skills/<revision>/skills/...
#     - .vscode/agent-plugins/github.com/microsoft/azure-skills/.github/plugins/azure-local-skills/skills/...
#     shared:
#     - .agents/skills/...
#
#   If the path matches AND is not a SKILL.md file, the relative path after
#   "skills/" is extracted and emitted as a reference_file_read event.
#   SKILL.md reads are tracked as skill_invocation instead (not double-counted).
#
# === Debugging ===
#
# If the AZURE_SKILLS_TELEMETRY_LOG_DIR env var is set, the script will create
# a "raw-input" subdirectory and write each raw JSON input to a timestamped file
# for debugging. It will also append a "telemetry.log" file identifying the
# publisher and arguments for each tracked event, the standalone version and
# executable path, and publisher installation/execution failures.
#
# When using `--plugin-dir` to load a local plugin the AZURE_SKILLS_PLUGIN_ROOT
# env var should be set so that the script can detect local skill paths for
# reference_file_read events.

$ErrorActionPreference = "SilentlyContinue"

$telemetryReporterVersion = "0.1.11-gce94fceee1"

# Dumps raw input to a file in the AZURE_SKILLS_TELEMETRY_LOG_DIR/raw-input/
# directory for debugging if the env var is set.
function Write-RawInputToFile {
    param([string]$RawInput)
    if ($env:AZURE_SKILLS_TELEMETRY_LOG_DIR) {
        $logDir = $env:AZURE_SKILLS_TELEMETRY_LOG_DIR
        $rawInputDir = Join-Path $logDir 'raw-input'
        if (-not (Test-Path -LiteralPath $rawInputDir)) {
            New-Item -ItemType Directory -Path $rawInputDir -Force | Out-Null
        }
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
        $rawInputFile = Join-Path $rawInputDir "$timestamp.json"
        try {
            $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($rawInputFile, $RawInput, $utf8WithoutBom)
        } catch { }
    }
}

# Writes a debug log entry to the AZURE_SKILLS_TELEMETRY_LOG_DIR/telemetry.log file
# if the env var is set.
function Write-TelemetryDebugLog {
    param([string]$Content)

    if ($env:AZURE_SKILLS_TELEMETRY_LOG_DIR) {
        $logDir = $env:AZURE_SKILLS_TELEMETRY_LOG_DIR
        $logFile = Join-Path $logDir 'telemetry.log'
        $logEntry = "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') | $Content"
        try {
            Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
        } catch { }
    }
}

# Formats native arguments for diagnostics while preserving visible argument boundaries.
function Format-TelemetryArguments {
    param([string[]]$Arguments)

    return (($Arguments | ForEach-Object {
        if ($_ -match '[\s"\\]') {
            ConvertTo-Json -Compress -InputObject $_
        } else {
            $_
        }
    }) -join ' ')
}

# Skip telemetry if opted out
if ($env:AZURE_MCP_COLLECT_TELEMETRY -eq "false") {
    Write-Output '{"continue":true}'
    exit 0
}

# Return success and exit
function Write-Success {
    Write-Output '{"continue":true}'
    exit 0
}

# Removes UTF-8 BOM markers and the common Windows mojibake forms that can
# precede Cursor hook JSON after stdin passes through Windows PowerShell.
function Remove-LeadingUtf8BomArtifacts {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return $Value }

    $bomArtifacts = @(
        [string][char]0xFEFF,
        (-join ([char[]]@(0x00EF, 0x00BB, 0x00BF))),
        (-join ([char[]]@(0x2229, 0x2557, 0x2510)))
    )

    do {
        $removedArtifact = $false
        foreach ($artifact in $bomArtifacts) {
            if ($Value.StartsWith($artifact, [System.StringComparison]::Ordinal)) {
                $Value = $Value.Substring($artifact.Length)
                $removedArtifact = $true
                break
            }
        }
    } while ($removedArtifact)

    return $Value
}

# Resolve this script's directory, the extension-owned hook support directory,
# and the shared skills directory installed at the same global/workspace scope.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$pluginRoot = Split-Path -Parent $scriptDir
$installRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $pluginRoot))
$skillsDir = Join-Path $installRoot '.agents/skills'
$pluginPathAllowPattern = Join-Path $scriptDir 'pluginPathAllowPattern.ps1'

# Return true only when a target belongs to this hook's plugin. Since this hook
# is copied into every plugin, comparing through the skills directory prevents
# each installed copy from reporting the same skill or reference event.
function Test-OwnedSkillPath {
    # targetPath is either path to the SKILL.md or to a reference file
    param([string]$TargetPath)
    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return $false }
    $skillsRootNorm = (($skillsDir -replace '\\', '/') -replace '/+', '/').TrimEnd('/')
    $targetPathNorm = ($TargetPath -replace '\\', '/') -replace '/+', '/'
    return $targetPathNorm.StartsWith("$skillsRootNorm/", [System.StringComparison]::OrdinalIgnoreCase)
}

# Extract the skill version from a SKILL.md frontmatter (metadata.version).
# Returns $null if the file or version cannot be read.
function Get-SkillVersion {
    param([string]$SkillMdPath)
    if (-not $SkillMdPath) { return $null }
    $SkillMdPath = $SkillMdPath -replace '\\', '/'
    if (-not (Test-Path -LiteralPath $SkillMdPath)) { return $null }
    try {
        $lines = Get-Content -LiteralPath $SkillMdPath -ErrorAction SilentlyContinue
    } catch { return $null }
    $inFrontmatter = $false
    foreach ($line in $lines) {
        if ($line -match '^---\s*$') {
            if (-not $inFrontmatter) { $inFrontmatter = $true; continue }
            else { break }
        }
        if ($inFrontmatter -and $line -match '^\s*version:\s*(.+?)\s*$') {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $null
}

# Read the plugin manifest for the active client.
# Returns $null if the file or expected JSON value cannot be read.
function Get-PluginManifest {
    param([string]$ClientName)

    $manifestDir = '.plugin'
    if ($ClientName -eq 'cursor') {
        $manifestDir = '.cursor-plugin'
    } elseif ($ClientName -eq 'claude-code') {
        $manifestDir = '.claude-plugin'
    }

    $pluginManifestPath = Join-Path $pluginRoot "$manifestDir/plugin.json"
    if (-not (Test-Path -LiteralPath $pluginManifestPath)) { return $null }
    try {
        $manifest = Get-Content -LiteralPath $pluginManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return $manifest
    } catch { }
    return $null
}

# Return true unless this hook's plugin ships a .mcp.json that does not
# configure the named server. A plugin with an empty .mcp.json (for example
# aks-skills) must not report MCP calls owned by a co-installed plugin; a
# plugin with no .mcp.json at all keeps the pre-existing behavior.
function Test-OwnsMcpServer {
    param([string]$ServerName)
    if ([string]::IsNullOrWhiteSpace($ServerName)) { return $false }
    $mcpConfigPath = Join-Path $pluginRoot '.mcp.json'
    if (-not (Test-Path -LiteralPath $mcpConfigPath)) { return $true }
    try {
        $config = Get-Content -LiteralPath $mcpConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return $config.mcpServers -and ($config.mcpServers.PSObject.Properties.Name -contains $ServerName)
    } catch { }
    return $false
}

# === Main Processing ===

# Read stdin as bytes and decode it as UTF-8. Reading through Console.In and
# re-encoding with Console.InputEncoding can introduce code-page mojibake.
try {
    $stdinStream = [Console]::OpenStandardInput()
    $inputBuffer = New-Object System.IO.MemoryStream
    $stdinStream.CopyTo($inputBuffer)
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    $rawInput = $utf8WithoutBom.GetString($inputBuffer.ToArray())
} catch {
    Write-Success
} finally {
    if ($inputBuffer) { $inputBuffer.Dispose() }
}

# Some clients prefix the JSON stream with a UTF-8 BOM. Cursor on Windows can
# surface an additional mojibake copy of that marker after stdin decoding.
$rawInput = Remove-LeadingUtf8BomArtifacts -Value $rawInput

# Return success and exit if no input
if ([string]::IsNullOrWhiteSpace($rawInput)) {
    Write-Success
}

Write-RawInputToFile -RawInput $rawInput

# === STEP 1: Read and parse input ===

# Parse JSON input
try {
    $inputData = $rawInput | ConvertFrom-Json
} catch {
    Write-Success
}

# Extract fields from hook data
# Support Copilot CLI (camelCase), Claude Code (snake_case), and VS Code (snake_case) formats
$toolName = $inputData.toolName
if (-not $toolName) {
    $toolName = $inputData.tool_name
}

$sessionId = $inputData.sessionId
if (-not $sessionId) {
    $sessionId = $inputData.session_id
}
$hookEventName = $inputData.hook_event_name
$mcpServerName = $inputData.mcp_server_name

# Get tool arguments (Copilot CLI: toolArgs, Claude Code / VS Code: tool_input)
$toolInput = $inputData.toolArgs
if (-not $toolInput) {
    $toolInput = $inputData.tool_input
}

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$isSessionStart = $hookEventName -eq "SessionStart" -or $hookEventName -eq "sessionStart"

# Detect client name based on input format
# Copilot CLI (>=0.0.421): COPILOT_CLI env var is "1" — primary signal, checked first
# Copilot CLI (<0.0.421):  has "toolArgs" field without "hook_event_name" — backward compat fallback
# Cursor: has hook_event_name AND a "cursor_version" field
# VS Code: has hook_event_name AND tool_use_id contains "__vscode" or transcript_path contains "Code"
# Claude Code: has hook_event_name, tool_use_id does NOT contain "__vscode"
$hasHookEventName = $inputData.PSObject.Properties.Name -contains "hook_event_name"
$hasToolArgs = $inputData.PSObject.Properties.Name -contains "toolArgs"
$toolUseId = $inputData.tool_use_id
$transcriptPath = $inputData.transcript_path
$cursorVersion = $inputData.cursor_version
$isVscodeToolUseId = $toolUseId -and ($toolUseId -match '__vscode')
# Match path separators around "Code" or "Code - Insiders" to avoid matching "Claude Code"
$isVscodeTranscript = $transcriptPath -and ($transcriptPath -match '[/\\]Code( - Insiders)?[/\\]')

# Prefer an explicit hook client family over inherited client environment variables.
if ($hasHookEventName -and ($env:AZURE_SKILLS_HOOK_CLIENT_FAMILY -eq "copilot-vscode" -or $isVscodeToolUseId -or $isVscodeTranscript)) {
    # Detect VS Code variant from transcript_path
    # Insiders: ...AppData\Roaming\Code - Insiders\User\...
    # Stable:   ...AppData\Roaming\Code\User\...
    if ($transcriptPath -match '[/\\]Code - Insiders[/\\]') {
        $clientName = "Visual Studio Code - Insiders"
    } else {
        $clientName = "Visual Studio Code"
    }
} elseif ($env:COPILOT_CLI -eq "1") {
    $clientName = "copilot-cli"
} elseif ($hasHookEventName -and $cursorVersion) {
    $clientName = "cursor"
} elseif ($hasHookEventName) {
    $clientName = "claude-code"
} elseif ($hasToolArgs) {
    # Backward compat: old Copilot CLI (<0.0.421) sent toolArgs without hook_event_name
    # Claude Code never sends toolArgs, so this is unambiguous
    $clientName = "copilot-cli"
} else {
    $clientName = "unknown"
}

# Skip if no tool name found in any format and this is not a lifecycle event.
if (-not $toolName -and -not $isSessionStart) {
    Write-Success
}

# Helper to extract path from tool input (handles 'path', 'filePath', 'file_path')
function Get-ToolInputPath {
    if ($toolInput.path) { return $toolInput.path }
    if ($toolInput.filePath) { return $toolInput.filePath }
    if ($toolInput.file_path) { return $toolInput.file_path }
    return $null
}

# === STEP 2: Determine what to track for azmcp ===

# Plugin-local path patterns per client (used for SKILL.md and file-reference
# matching). The build packages this script with the owning plugin's patterns.

. $pluginPathAllowPattern

# --- shared across all plugins ---
$pathPatternAgentsSkills = '\.agents/skills/'

# Put the path patterns into an array for easier iteration
$pathPatterns = @($pluginPathPatterns) + @($pathPatternAgentsSkills)

# If $env:AZURE_SKILLS_PLUGIN_ROOT is set, add it to the path patterns for local skill development
if ($env:AZURE_SKILLS_PLUGIN_ROOT) {
    $localSkillsPath = [regex]::Escape($env:AZURE_SKILLS_PLUGIN_ROOT) + '/skills/'
    $localSkillsPath = $localSkillsPath -replace '\\', '/' -replace '/+', '/'
    $pathPatterns += $localSkillsPath
}

$shouldTrack = $false
$eventType = $null
$skillName = $null
$skillVersion = $null
$azureToolName = $null
$filePath = $null

# Report every session_start invocation, including resumed sessions.
if ($isSessionStart) {
    $eventType = "session_start"
    $shouldTrack = $true
}

# Check for skill invocation via 'skill'/'Skill' tool
if ($toolName -eq "skill" -or $toolName -eq "Skill") {
    $requestedSkillName = $toolInput.skill
    $ownManifest = Get-PluginManifest -ClientName $clientName
    $pluginName = if ($ownManifest) { $ownManifest.name } else { $null }
    $skillName = $requestedSkillName
    # Native plugin invocations use "<plugin-name>:<skill-name>". Strip only
    # this hook copy's own namespace so another plugin cannot claim the call.
    if ($requestedSkillName -and $requestedSkillName.Contains(":")) {
        $skillParts = $requestedSkillName -split ':', 2
        if ($pluginName -and $skillParts[0] -eq $pluginName) {
            $skillName = $skillParts[1]
        } else {
            $skillName = $null
        }
    }
    if ($skillName) {
        $skillMdPath = Join-Path $skillsDir (Join-Path $skillName 'SKILL.md')
        if ((Test-Path -LiteralPath $skillMdPath) -and (Test-OwnedSkillPath $skillMdPath)) {
            $eventType = "skill_invocation"
            $shouldTrack = $true
            $skillVersion = Get-SkillVersion $skillMdPath
        }
    }
}

# Check for skill invocation (reading SKILL.md files)
# Copilot CLI: "view", Claude Code: "Read", VS Code: "read_file"
if ($toolName -eq "view" -or $toolName -eq "Read" -or $toolName -eq "read_file") {
    $pathToCheck = Get-ToolInputPath
    if ($pathToCheck) {
        # Normalize path: convert to lowercase, replace backslashes, and squeeze consecutive slashes
        $pathLower = $pathToCheck.ToLower() -replace '\\', '/' -replace '/+', '/'

        # Check for SKILL.md pattern — only match azure-skills paths (see pathPatterns above)
        $isAzureSkillMd = $false
        foreach ($pattern in $pathPatterns) {
            if ($pathLower -match "${pattern}[^/]+/skill\.md") {
                $isAzureSkillMd = $true
                break
            }
        }

        if ($isAzureSkillMd -and (Test-OwnedSkillPath $pathToCheck)) {
            $pathNormalized = $pathToCheck -replace '\\', '/' -replace '/+', '/'
            if ($pathNormalized -match '/skills/([^/]+)/SKILL\.md$') {
                $skillName = $Matches[1]
                $eventType = "skill_invocation"
                $shouldTrack = $true
                $skillVersion = Get-SkillVersion $pathToCheck
            }
        }
    }
}

# Check for Azure MCP tool invocation
# Copilot CLI:  "azure-*" prefix (e.g., azure-documentation)
# Claude Code:  "mcp__plugin_azure_azure__*" prefix (e.g., mcp__plugin_azure_azure__documentation)
# Cursor:       afterMCPExecution with mcp_server_name "azure"; remove Cursor's
#               optional display prefix (e.g., MCP:get_azure_bestpractices)
# VS Code:      "mcp_azure_mcp_*" prefix (e.g., mcp_azure_mcp_documentation)
if ($toolName -and (Test-OwnsMcpServer -ServerName "azure")) {
    if ($clientName -eq "cursor" -and $hookEventName -eq "afterMCPExecution" -and $mcpServerName -eq "azure") {
        $azureToolName = $toolName
        if ($azureToolName.StartsWith("MCP:", [System.StringComparison]::Ordinal)) {
            $azureToolName = $azureToolName.Substring(4)
        }
        $eventType = "tool_invocation"
        $shouldTrack = $true
    } elseif ($toolName.StartsWith("azure-") -or $toolName.StartsWith("mcp__plugin_azure_azure__") -or $toolName.StartsWith("mcp_azure_mcp_")) {
        $azureToolName = $toolName
        $eventType = "tool_invocation"
        $shouldTrack = $true
    }
}

# Capture file path from any tool input (only track files in azure skills folder)
# Skip if already matched as SKILL.md skill_invocation — SKILL.md is not a valid file-reference
if (-not $filePath -and -not $skillName) {
    $pathToCheck = Get-ToolInputPath
    if ($pathToCheck) {
        # Normalize path for matching: replace backslashes and squeeze consecutive slashes
        $pathLower = $pathToCheck.ToLower() -replace '\\', '/' -replace '/+', '/'

        $matchesPattern = $false
        foreach ($pattern in $pathPatterns) {
            if ($pathLower -match $pattern) {
                $matchesPattern = $true
                break
            }
        }
        if ($matchesPattern -and (Test-OwnedSkillPath $pathToCheck)) {
            # Extract relative path after 'skills/'
            $pathNormalized = $pathToCheck -replace '\\', '/' -replace '/+', '/'

            if ($pathNormalized -match '.*/skills/(.+)$') {
                $filePath = $Matches[1]

                if (-not $shouldTrack) {
                    $shouldTrack = $true
                    $eventType = "reference_file_read"
                    # Resolve the version from the sibling SKILL.md at the root
                    # of the skill folder this reference lives in.
                    $skillNameSeg = ($filePath -split '/')[0]
                    $skillRootAbs = $pathNormalized.Substring(0, $pathNormalized.Length - $filePath.Length)
                    $skillVersion = Get-SkillVersion ("$skillRootAbs$skillNameSeg/SKILL.md")
                }
            }
        }
    }
}

# === STEP 3: Publish event ===

if ($shouldTrack) {
    # The plugin-telemetry command requires a session ID for session_start events.
    if ($eventType -eq "session_start" -and [string]::IsNullOrWhiteSpace($sessionId)) {
        Write-Success
    }

    $pluginManifest = Get-PluginManifest -ClientName $clientName
    $pluginName = $pluginManifest.name
    $pluginVersion = $pluginManifest.version

    # Session telemetry must identify the plugin.
    if ($eventType -eq "session_start" -and
        ([string]::IsNullOrWhiteSpace($pluginName) -or [string]::IsNullOrWhiteSpace($pluginVersion))) {
        Write-Success
    }

    # Build reporter arguments
    $reporterArguments = @()

    if ($pluginName) { $reporterArguments += "--plugin-name"; $reporterArguments += $pluginName }
    if ($pluginVersion) { $reporterArguments += "--plugin-version"; $reporterArguments += $pluginVersion }
    $reporterArguments += "--client-name"; $reporterArguments += $clientName
    $reporterArguments += "--timestamp"; $reporterArguments += $timestamp
    if ($eventType) { $reporterArguments += "--event-type"; $reporterArguments += $eventType }
    if ($sessionId) { $reporterArguments += "--session-id"; $reporterArguments += $sessionId }
    if ($skillName) { $reporterArguments += "--skill-name"; $reporterArguments += $skillName }
    if ($skillVersion) { $reporterArguments += "--skill-version"; $reporterArguments += $skillVersion }
    if ($azureToolName) { $reporterArguments += "--tool-name"; $reporterArguments += $azureToolName }
    # Convert forward slashes to backslashes for azmcp allowlist compatibility
    if ($filePath) { $reporterArguments += "--file-reference"; $reporterArguments += ($filePath -replace '/', '\') }

    $publisher = "Standalone ghcfa-telem (version $telemetryReporterVersion)"
    $formattedReporterArguments = Format-TelemetryArguments -Arguments $reporterArguments
    Write-TelemetryDebugLog -Content "Publisher: $publisher | Args: $formattedReporterArguments"
    $installerPath = Join-Path $scriptDir 'install-telemetry.ps1'
    $powerShellExecutable = (Get-Process -Id $PID).Path
    $installerArguments = @(
        '-NoProfile',
        '-NonInteractive'
    )
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        $installerArguments += '-ExecutionPolicy'
        $installerArguments += 'Bypass'
    }
    $installerArguments += '-File'
    $installerArguments += $installerPath
    $installerArguments += '-Version'
    $installerArguments += $telemetryReporterVersion

    # Capture installer stderr without changing the hook's fail-open error preference.
    $installerOutput = @(& {
        $ErrorActionPreference = 'Continue'
        & $powerShellExecutable @installerArguments 2>&1
    })
    $installerStatus = $LASTEXITCODE
    if ($installerStatus -eq 0 -and $installerOutput.Count -gt 0 -and
        -not [string]::IsNullOrWhiteSpace([string]$installerOutput[-1])) {
        $reporterPath = [string]$installerOutput[-1]
        Write-TelemetryDebugLog -Content "Publisher: $publisher | Executable: $reporterPath"
        try {
            & $reporterPath @reporterArguments 2>&1 | Out-Null
            $reporterStatus = $LASTEXITCODE
            if ($reporterStatus -ne 0) {
                Write-TelemetryDebugLog -Content "Publisher: $publisher | Execution failed with status $reporterStatus."
            }
        } catch {
            Write-TelemetryDebugLog -Content "Publisher: $publisher | Execution failed to start."
        }
    }
    elseif ($installerStatus -eq 0) {
        Write-TelemetryDebugLog -Content "Publisher: $publisher | Installation failed: installer returned no executable path."
    }
    else {
        Write-TelemetryDebugLog -Content "Publisher: $publisher | Installation failed with status ${installerStatus}: $($installerOutput -join ' ')"
    }
}

# Output success to stdout (required by hooks)
Write-Success

# SIG # Begin signature block
# MIIncQYJKoZIhvcNAQcCoIInYjCCJ14CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA+cH32FzUliSgX
# 4qUZSOj2K2nX/f+kFT6RtUfEuuBk/aCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
# xZvoL37EAAAAAAIcMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQxWhcNMjcwNDE1MTg1
# OTQxWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDVsZfgOKmM31HPfoWOoNEiw0SlCiIxUMC0I9NMWbucKOw/e9lP
# oAoehQVu6SG65V4EPzrYsnBnFPNoi4/HoOdjhz1qkrEt4I6tEcxXU6oOeY9zGveC
# /3iBeuhLYxM3M/PkcUoebF+Nednm8OkdSPoDu8imViHPQq/8CQUu0WRR4rE+dMRf
# rpVqfmNi2qWCX94T4MsepijGVkwE//tJg0ryAiYdHT34LSnlG/RSBZmQRGWZ5g8j
# qnKjRParSqMft1gvjuUTVgtWNZfgcLFSK5Wa0myrq8OPcgTGGsRgun+tnSS+IxDT
# xVsAPH1OzvPjwomguByhUe/OcvUN0D5Wmp7xAgMBAAGjggGqMIIBpjAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFNoH7a2YDjOSwpkp6DHcmUS7J+0yMFQGA1UdEQRNMEukSTBHMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxFjAUBgNVBAUT
# DTIzMDAxMis1MDc1NjkwHwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEw
# YAYDVR0fBFkwVzBVoFOgUYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# bDBtBggrBgEFBQcBAQRhMF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmcl
# MjBQQ0ElMjAyMDI0LmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IC
# AQAUnEqhaRXe0T3hIJjvdQErEkrA/7bByjn6t5IArODkkRjzkYwtKMc2yYj2quaN
# rLutWw2YZcngKPy1b71YyDJQTy4NDRwaSh9Tw5thrk3NmcPrAHia5vtcBJ1CgtKK
# 7mQbIcQ22d/N3813ayCDDFewu1+jsZmX+r/aTEqaOM4TVxVtRSkuCy8nAXKuChOK
# Li/zA4XuH8iEYqIsj2YoNaeSxVmeGiERXpKdo3dDmYi0kO5w2D8VS4c3+9h6gElY
# BaAAg/dYErBg27qT3vv0zRDJhJufvCNylA8S7/+8H5E/PV5cng6na9VV/w9OV3qu
# uND6zdGa2EX38Glp50F9AIQk3p2xXmcvorDeM4XJ7UlWYBi6g80J1SSOQnInCYFE
# msfUNn3+1AaTJKSJL83quKArTac2pKhu0Yzzzrzo6HrsRiQKzpnRBb1/dMa6P3hz
# 75XbMRBctNsFhZC07WCmjExdLg2eHW5uV0TY8D5+6wozJf7vF3+WHkYPO85Z+BC6
# U4FkNbYNycZ9cE4j1tXRdyDCfml6c0HWPHjNVDObrv9lKt3qUqFpX38VCqVCyNOO
# 1UcXfQiVjJw32U2WUKZjt/neJKHEBsm9kFsLuWzkQ53+qcaSaytmsCnk2gOglrlD
# 5d3kKyvvAw+rzm0lT8K38P6PLxfZQHhu4W8dV7Av8N2ZmDCCBr0wggSloAMCAQIC
# EzMAAAA5O7Y3Gb8GHWcAAAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoX
# DTM2MDMyMjIyMTMwNFowVzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeq
# lRYHNa265v4IY9fH8TKhemHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo
# 0dtS/EW6I/yEL/bLSY8hKpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATv
# QVL4tcf03aTycsz8QeCdM0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a
# 1uv1zerOYMnsneRRwCbpyW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1
# FyQfK0fVkaya8SmVHQ/tOf23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfO
# GSWHIIV4YrTJTT6PNty5REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7
# ttOu1bVnXfHaqPYl2rPs20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJ
# uz2MXMCt7iw7lFPG9LXKGjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxS
# CwyoGIq0PhaA7Y+VPct5pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOm
# VQop36wUVUYklUy++vDWeEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3
# SkE/xIkgpfl22MM1itkZ35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPX
# LQaUEggxMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBP
# oE2gS4ZJaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAw
# TgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOC
# AgEAFJQfOChP7onn6fLIMKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D
# 5W4wMwYeLystcEqfkjz4NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBY
# nbu0+THSuVHTe0VTTPVhily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSI
# vgn0JksVBVMYVI5QFu/qhnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6
# aR9y34aiM1qmxaxBi6OUnyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4w
# PKC5OmHm1DQIt/MNokbbH3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7
# RTX8AdBPo0I6OEojf39zuFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK
# /fg8B2qjW88MT/WF5V5uvZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSK
# YBv0VisCzfxgeU+dquXW9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkw
# YTu/9dLeH2pDqeJZAABVDWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVT
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghn+MIIZ+gIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZI
# hvcNAQkEMSIEID0NqXqTIeskPnOKTJYjGVJMQrgAG5FfNpJmqRt/zP0/MEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEASy4MmTYHV9+9JnTS2elI
# Tx6fLJKUx3PdBFcliHAbjJtK2F7HVsPCRKaD+L5htP814P4AoBWmEiajwsGpLXQY
# S0w58mQYU3Uy2MLqAk7vTL0WabH48ddjO/R9irES7ynt//KffcRL2LPd7n47nJeW
# gZtVS7nKJ1RZxXal//5IIcfunWEYG9cdClW+aHVLT9Y11azNSUUBQqg808fxmnZ2
# fTslweVdTPuRFvlUiA7VX1q9q3P3VHwm0DnonoXK8liess6zS6+qGc3CGe8RGyvS
# 06Gc1QjqKMtHiCYyId8CqBleh7QWwj4ss17qYDoUl1GscZyRfaz23rnvLRNpHQSg
# 06GCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheF
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDvPy389ee+l+wkTaU+
# skSPoNkdyZ21qaArDWIUUW00EAIGatvwsCFpGBMyMDI2MTEwMTAwMDY1Ni4zODFa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyRDFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIFEKAD
# AgECAhMzAAACEtEIBjzKGE+qAAEAAAISMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxNVoXDTI2MTExMzE4
# NDgxNVowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjJEMUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAr0zToDkpWQtsZekS0cV0quDdKSTGkovvBaZH0OAIEi0O3CcO
# 77JiX8c4Epq9uibHVZZ1W/LoufE172vkRXO+QYNtWWorECJ2AcZQ10bpAltkhZNi
# XlVJ8L3QzhKgrXrmMkm2J+/g81U23JPcO4wXHEftonT3wpd//936rjmwxMm7Nkbs
# ygbJf+4AVBMNr4aMPQhBd76od0KMB6WrvyEGOOU0893OFufS5EDey4n44WgaxJE0
# Vnv3/OOvuOw5Kp1KPqjjYJ+L9ywLuBMtcDfLpNQO/h1eFEoMrbiEM67TOfNlXfxb
# Dz4MlsYvLioxgd2Xzey1QxrV1+i+JyVDJMiSe9gKOuzpiQQFE19DUPgsidyjLTzX
# EhSVLBlRor0eCVf7gC6Rfk8NY3rO2sggOL79vU5FuDKTh/sIOtcUHeHC42jBGB+t
# fdKC1KOBR+UlN9aOzg8mpUNI2FgqQvirVP9ppbeMUfvp2wA9voyTiRWvDgzCxo8x
# lJ1nscYTHIQrmkF9j/Ca0IDmt8fvOn64nnlJOGUYZYHMC1l0xtgkYTE1ESUqqkaw
# Kk7iqbxdnLyycS+dR+zaxPudMDLrQFz8lgfy9obk0D8HC2dzhWpYNn5hdkoPEzgC
# qQUOp8v3Qj/sd4anyupe5KoCkjABOP3yhSQ4W9Z+DrJnhM/rbsXC7oTv26cCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBRSBblSxb5cYKYOwvd/VfoXOfu33jAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAXnSAkmX79Rc7lxS1wOozXJ7V0ou5DntVcOJplIkD
# jvEN8BIQph4U+gSOLZuVReP/z9YdUiUkcPwL1PM245/kEX1EegpxNc8HDA6hKCHg
# 0ALNEcuxnGOlgKLokXfUer1D5hiW8PABM9R+neiteTgPaaRlJFvGTYvotc0uqGiE
# S5hMQhL8RNFhpS9RcIWHtnQGEnrdOUvCAhs4FeViawcmLTKv+1870c/MeTHi0QDd
# eR+7/Wg4qhkJ2k1iEHJdmYf8rIV0NRBZcdRTTdHee35SXP5neNCfAkjDIuZycRud
# 6jzPLCNLiNYzGXBswzJygj4EeSORT7wMvaFuKeRAXoXC3wwYvgIsI1zn3DGY625Y
# +yZSi8UNSNHuri36Zv9a+Q4vJwDpYK36S0TB2pf7xLiiH32nk7YK73Rg98W6fZ2I
# NuzYzZ7Ghgvfffkj4EUXg1E0EffY1pEqkbpDTP7h/DBqtzoPXsyw2MUh+7yvWcq2
# BGZSuca6CY6X4ioMuc5PWpsmvOOli7ARNA7Ab8kKdCc2gNDLacglsweZEc9/VQB6
# hls/b6Kk32nkwuHExKlaeoSVrKB5U9xlp1+c8J/7GJj4Rw7AiQ8tcp+WmfyD8KxX
# 2QlKbDi4SUjnglv4617R8+a/cDWJyaMt8279Wn7f2yMedN7kfGIQ5SZj66RdhdlZ
# Oq8wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
# CwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYD
# VQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAe
# Fw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA5OGm
# TOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/XE/H
# ZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1hlDc
# wUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7M62A
# W36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3KNi1w
# jjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy1cCG
# MFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF803RKJ
# 1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQcNIIP
# 8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahhaYQFz
# ymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkLiWHz
# NgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV2xo3
# xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIGCSsG
# AQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUpzxD/
# LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBTMFEG
# DCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYB
# BQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMA8G
# A1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186aGMQw
# VgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9j
# cmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsGAQUF
# BwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcNAQEL
# BQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1OdfC
# cTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYAA7AF
# vonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbzaN9l
# 9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6LGYnn
# 8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3mSj5m
# O0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0SCyx
# TkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxkoJLo4
# S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFmPWn9
# y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC4822rpM
# +Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7vzhw
# RNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDWTCCAkEC
# AQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoyRDFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUA5VHBr4h00EN7jUdQ33SE+qbk/8CggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO6Q+kEwIhgPMjAyNjEwMzEy
# MzM3MzdaGA8yMDI2MTEwMTIzMzczN1owdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA
# 7pD6QQIBADAKAgEAAgINTAIB/zAHAgEAAgIUCDAKAgUA7pJLwQIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQBJPq830J+GzJAiWC9nUGmPF/NjfLKMBgLbjg0h
# m9JcrxoIVvwtQv9Y3PdMeuufoABPQ3Yfp6gQNvSK0WijLopGr7gArCslDkU2YbbU
# qVJ4JdsdCSTDfocFjWj7v7/F4vYo8WTZn3Upxvs2e1JMHyhuYbdjQnuJJVH493XV
# XXkoNtpdc/qSvCVERgg5uRhSULhAPrFjCxNf0RxwBQUwl9ncX+gyuD36vbdvcamc
# uwGrsjr5LnWV8pvCCTbsxGJJto07xWPeJdG4grMzzvMy4YKF8wn4sg7a/cfgrpsk
# 6HEmrXOWr8n2/lls9sKFaNkRBtHZzTdzH0hr75Ek9aquWCXqMYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIS0QgGPMoYT6oA
# AQAAAhIwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgz7KVyqXMe5hGKvrA5KmP/G4PA8q/YBxqCc9y
# WUmEM7wwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBz+X5GvO7WngknH4BZ
# eYU+BzBL1Jy5oJ8wVlTNIxfYgzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACEtEIBjzKGE+qAAEAAAISMCIEIOMK12s6cxuUE5454lg8
# 1ah+zSzJ1Yff8H4wuCLV5FLUMA0GCSqGSIb3DQEBCwUABIICAIMYRaXKb437U78l
# 0G5zPRPPo6cf7MDO34nWkQYXQZsXjzdkyH3AK4HI76T8WbqQvdG9I+THnCuuOXUI
# 5as4qb3NcnWig5zCrXCVneWeKB5JeNbj3InMJPiwscDUDonk2Q2BDe8YrAvzStui
# 6XVh+bPOwCoknlGJlXsk/YLFL8bTRcgQxSJcFzZThgJJTspWNFyLralgNnl+ZL1e
# 0W559+ejamRHLAEVhucWlE1zt42+IEPT8O6vCj2+0bDTm5M++3LWw6hQqPhZSBko
# tg6B8WNZp0r4+ju7JhfHA+ib09GYnuntCLsTrLqaV8RaXGvpftnaXH7M8R4ZkiIL
# crnxRJOB2c8jZovacgESgH52UGeY2jStlk8zF3hQMld2MS+A/+wDYUr2XVw75EFB
# 3AlC5fqcKnDNuxlt8u1nNXAWbjLCUNX6pr8qzjzoGOMzZzS5Wv8gobv+xJNILhcj
# g1foaosW6auL6vIEMGwZbD9Z+eYhR8JfTs8VuPVgiv51UzXxkCxesjAr98FDdwHx
# 4+rQdNC/eAkGK3Hj/77Nw7ZrHNuo2bpG65vYjPbN4RdsiN6PIDEWVs+HeJ+RTIDN
# IDSyWQbMUo5H8eUWLoNAOqpuXSHDNKObeTDRkPwUWdJvh40OheFfflYem2mTTJLH
# M9cQopgR/P3/qWYvMjgSxRkXt5QZ
# SIG # End signature block
