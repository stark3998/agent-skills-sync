# Installs the standalone telemetry reporter for the current operating system
# and native architecture.
#
# Exit codes:
#   0 = installed or already present
#   1 = detection, download, extraction, or installation failure
#   2 = usage or argument error

param(
    [string] $Version
)

$toolName = 'ghcfa-telem'
$checksumManifestPath = Join-Path $PSScriptRoot 'telemetry-reporter-checksums.txt'

# Writes an installer failure to the error stream without terminating the script.
function Write-InstallerError {
    param([string] $Message)
    Write-Error -Message $Message -ErrorAction Continue
}

# Detects the native operating system and architecture and returns the matching runtime target.
function Get-TelemetryTarget {
    $runtime = [System.Runtime.InteropServices.RuntimeInformation]
    $platform = [System.Runtime.InteropServices.OSPlatform]

    if ($runtime::IsOSPlatform($platform::Windows)) {
        $operatingSystem = 'win'
    }
    elseif ($runtime::IsOSPlatform($platform::OSX)) {
        $operatingSystem = 'osx'
    }
    elseif ($runtime::IsOSPlatform($platform::Linux)) {
        $operatingSystem = 'linux'
        $isMusl = Test-Path -LiteralPath '/etc/alpine-release' -PathType Leaf

        if (-not $isMusl -and (Test-Path -LiteralPath '/etc/os-release' -PathType Leaf)) {
            try {
                foreach ($line in [System.IO.File]::ReadAllLines('/etc/os-release')) {
                    if ($line -match '^\s*ID\s*=\s*"?alpine"?\s*$') {
                        $isMusl = $true
                        break
                    }
                }
            }
            catch {
                throw "Unable to inspect /etc/os-release: $($_.Exception.Message)"
            }
        }

        if (-not $isMusl -and (Test-Path -LiteralPath '/lib' -PathType Container)) {
            try {
                $isMusl = [System.IO.Directory]::GetFiles('/lib', 'ld-musl-*.so.1').Count -gt 0
            }
            catch {
                throw "Unable to inspect Linux C runtime files: $($_.Exception.Message)"
            }
        }

        if ($isMusl) {
            $operatingSystem = 'linux-musl'
        }
    }
    else {
        throw "Unsupported operating system: $($runtime::OSDescription)"
    }

    $architecture = switch ($runtime::OSArchitecture.ToString()) {
        'X64' { 'x64' }
        'Arm64' { 'arm64' }
        default { throw "Unsupported native architecture: $($runtime::OSArchitecture)" }
    }

    [pscustomobject]@{
        OperatingSystem = $operatingSystem
        Architecture = $architecture
        RuntimeIdentifier = "$operatingSystem-$architecture"
        BinaryName = $(if ($operatingSystem -eq 'win') { "${toolName}.exe" } else { $toolName })
    }
}

# Resolves the platform-specific root directory used to cache installed reporter versions.
function Get-TelemetryCacheRoot {
    param([string] $OperatingSystem)

    if ($OperatingSystem -eq 'win') {
        $localAppData = $env:LOCALAPPDATA
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        }
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            throw 'LOCALAPPDATA is required to install the telemetry reporter on Windows.'
        }
        return Join-Path $localAppData 'GitHubCopilotForAzure\telemetry'
    }

    if (-not [string]::IsNullOrWhiteSpace($env:XDG_CACHE_HOME)) {
        return Join-Path $env:XDG_CACHE_HOME 'github-copilot-for-azure/telemetry'
    }
    if ([string]::IsNullOrWhiteSpace($env:HOME)) {
        throw 'HOME or XDG_CACHE_HOME is required to install the telemetry reporter.'
    }
    return Join-Path $env:HOME '.cache/github-copilot-for-azure/telemetry'
}

# Resolves the one pinned release digest for a telemetry reporter version and runtime.
function Get-ExpectedTelemetryArchiveHash {
    param(
        [string] $ManifestPath,
        [string] $ReporterVersion,
        [string] $RuntimeIdentifier
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Telemetry checksum manifest not found: $ManifestPath"
    }

    $matchingHashes = @()
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($ManifestPath)) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        $parts = @($trimmed -split '\s+')
        if ($parts.Count -ne 3 -or
            $parts[0] -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$' -or
            $parts[1] -notmatch '^(win|osx|linux|linux-musl)-(x64|arm64)$' -or
            $parts[2] -notmatch '^[0-9a-fA-F]{64}$') {
            throw "Telemetry checksum manifest has a malformed entry on line $lineNumber."
        }
        if ($parts[0] -eq $ReporterVersion -and $parts[1] -eq $RuntimeIdentifier) {
            $matchingHashes += $parts[2].ToLowerInvariant()
        }
    }

    if ($matchingHashes.Count -eq 0) {
        throw "Telemetry checksum manifest has no entry for version $ReporterVersion and runtime $RuntimeIdentifier."
    }
    if ($matchingHashes.Count -gt 1) {
        throw "Telemetry checksum manifest has multiple entries for version $ReporterVersion and runtime $RuntimeIdentifier."
    }

    return $matchingHashes[0]
}

# Computes a lowercase SHA-256 digest without depending on module auto-loading.
function Get-TelemetryArchiveHash {
    param([string] $ArchivePath)

    $stream = [System.IO.File]::OpenRead($ArchivePath)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $algorithm.ComputeHash($stream)
        return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    Write-InstallerError 'The -Version parameter is required.'
    exit 2
}
if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$') {
    Write-InstallerError "Invalid telemetry reporter version: $Version"
    exit 2
}

$temporaryDirectory = $null
$stagedBinary = $null

try {
    $target = Get-TelemetryTarget
    $cacheRoot = Get-TelemetryCacheRoot -OperatingSystem $target.OperatingSystem
    $installDirectory = Join-Path (Join-Path $cacheRoot $Version) $target.RuntimeIdentifier
    $binaryPath = Join-Path $installDirectory $target.BinaryName

    if (Test-Path -LiteralPath $binaryPath -PathType Leaf) {
        Write-Output $binaryPath
        exit 0
    }

    $temporaryDirectory = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        "${toolName}-$([guid]::NewGuid().ToString('N'))"
    $extractDirectory = Join-Path $temporaryDirectory 'extracted'
    $assetName = "${toolName}-$Version-$($target.RuntimeIdentifier).zip"
    $archivePath = Join-Path $temporaryDirectory $assetName

    New-Item -ItemType Directory -Path $extractDirectory -Force -ErrorAction Stop | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_SKILLS_TELEMETRY_ZIP_PATH)) {
        if (-not (Test-Path -LiteralPath $env:AZURE_SKILLS_TELEMETRY_ZIP_PATH -PathType Leaf)) {
            throw "Telemetry ZIP not found: $($env:AZURE_SKILLS_TELEMETRY_ZIP_PATH)"
        }
        Copy-Item `
            -LiteralPath $env:AZURE_SKILLS_TELEMETRY_ZIP_PATH `
            -Destination $archivePath `
            -ErrorAction Stop
    }
    else {
        $downloadUrl = "https://github.com/microsoft/GitHub-Copilot-for-Azure/releases/download/${toolName}-$Version/$assetName"
        $expectedArchiveHash = Get-ExpectedTelemetryArchiveHash `
            -ManifestPath $checksumManifestPath `
            -ReporterVersion $Version `
            -RuntimeIdentifier $target.RuntimeIdentifier
        Invoke-WebRequest `
            -Uri $downloadUrl `
            -OutFile $archivePath `
            -UseBasicParsing `
            -ErrorAction Stop
        $actualArchiveHash = Get-TelemetryArchiveHash -ArchivePath $archivePath
        if ($actualArchiveHash -ne $expectedArchiveHash) {
            throw "SHA-256 validation failed for telemetry reporter asset $assetName."
        }
    }

    Expand-Archive `
        -LiteralPath $archivePath `
        -DestinationPath $extractDirectory `
        -ErrorAction Stop

    $extractedBinaries = @(
        Get-ChildItem `
            -LiteralPath $extractDirectory `
            -Filter $target.BinaryName `
            -File `
            -Recurse `
            -ErrorAction Stop
    )
    if ($extractedBinaries.Count -eq 0) {
        throw "The telemetry ZIP does not contain $($target.BinaryName)."
    }
    if ($extractedBinaries.Count -gt 1) {
        throw "The telemetry ZIP contains multiple files named $($target.BinaryName)."
    }

    New-Item -ItemType Directory -Path $installDirectory -Force -ErrorAction Stop | Out-Null
    $stagedBinary = Join-Path `
        $installDirectory `
        ".$($target.BinaryName).$([guid]::NewGuid().ToString('N')).tmp"
    Copy-Item `
        -LiteralPath $extractedBinaries[0].FullName `
        -Destination $stagedBinary `
        -ErrorAction Stop

    if ($target.OperatingSystem -ne 'win') {
        & chmod 0755 $stagedBinary
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to make the telemetry executable runnable; chmod exited with $LASTEXITCODE."
        }
    }

    try {
        Move-Item -LiteralPath $stagedBinary -Destination $binaryPath -ErrorAction Stop
        $stagedBinary = $null
    }
    catch {
        if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
            throw
        }
    }

    Write-Output $binaryPath
    exit 0
}
catch {
    Write-InstallerError $_.Exception.Message
    exit 1
}
finally {
    if ($stagedBinary -and (Test-Path -LiteralPath $stagedBinary -PathType Leaf)) {
        Remove-Item -LiteralPath $stagedBinary -Force -ErrorAction SilentlyContinue
    }
    if ($temporaryDirectory -and (Test-Path -LiteralPath $temporaryDirectory -PathType Container)) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAGFvV2JKmemqD/
# WcovB51t1GsIiW4KYmBk0mQ8fbeeUaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
# yE7XD1dIAAAAAAIdMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQzWhcNMjcwNDE1MTg1
# OTQzWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDQvewXxx9gZZFC6Ys1WBay8BJ8kGA4JQnH5CMafqOASlTpK9H8
# o5ZXTXt0caVQTNMUPt445wXYD+dFtaKWTwDn1I52oUSrC9vJin1Gsqt+zyKJL5Dg
# 3eQXbQNR61DmMy20GLTIO3SFed9Rfi/ophgCLGFLDR3r0KvHjwMb/jYWS0celV/4
# Lz27LfAekm8v9E5IXaeiXbAUYZKK090n4CVl3JBtbN+9DtI9SNu/yjvozW52/u7R
# X/Ttpa/KDlpuokZ+Zcbvmtd9ur9gFLvZzh41o9MsE/clQtdaFWGvuo6Jua/ntpgk
# ey3E5/vBFe+MJPG6phdnuo6r57ZudCudiI1bAgMBAAGjggGbMIIBlzAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFH6QuMwqcPG0hQlQ6c5jCtTTLrVeMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDAxMis1MDc1NTkw
# HwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEwYAYDVR0fBFkwVzBVoFOg
# UYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNybDBtBggrBgEFBQcBAQRh
# MF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBKTbYOjzwTG/DXGaz9
# s6+fQeaTtDcFmMY+5UyVFCyj7Pv+5i37qfX8lSL/tBIfYQfWsMuBQlfZurJD6r4H
# VJ2CeH+1fgiq8dcHdVKoZ3Sa2qXoX3cq9iS8cVb06B7+5/XJ7I0OxHH9fDsvJ3T3
# w5V/ZtAIFmLrl+P0CtG+92uzRsn0nTbdFjOkLMLWPLAU3THohKRlSEMgFJpPkm5n
# 5UAZ35xX6FWCrDLsSKb555bTifwa8mJBwdlof0bmfYidH+dxZ1FdDxvLnNl9zeKs
# A4kejaaIqqIPguhwAti5Ql7BlTNoJNwxCvBmqW2MQLnCkYN/VVUsR3V2x/rcTNzo
# Bf/Z/SpROvdaA2ZOOd1uioXJt3tdLQ7vHpqpib0KfWr/FWXW10q38VxfCnRQBqzb
# SuztR7nEMuzX7Ck+B/XaPDXd1qh72+QYyB0Z2VzWmO9zsnb9Uq/dwu8LGeQqnyu6
# 7SDGACvnXii2fb9+US492VTnXSnFKyqwgzUyFMtZK1/sHYTv6bG4TtQUygQxTN+Z
# V+aJIlKO2MqZ7bKrAnOzS9m6NgoTdWOq11bTOZwKlIEV/EhV9SWkDmdpR/hPPT2v
# 6TEj4F8PT/zHjRezIU5c/DGlt/VhY/pK0XkJtEyMmmS1BMtjU/rqBZVMIm3dnxQs
# /TBByr+Cf8Z1r7aifQVQ+WSqzjCCBr0wggSloAMCAQICEzMAAAA5O7Y3Gb8GHWcA
# AAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoXDTM2MDMyMjIyMTMwNFow
# VzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEo
# MCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeqlRYHNa265v4IY9fH8TKh
# emHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo0dtS/EW6I/yEL/bLSY8h
# KpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATvQVL4tcf03aTycsz8QeCd
# M0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a1uv1zerOYMnsneRRwCbp
# yW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1FyQfK0fVkaya8SmVHQ/t
# Of23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfOGSWHIIV4YrTJTT6PNty5
# REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7ttOu1bVnXfHaqPYl2rPs
# 20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJuz2MXMCt7iw7lFPG9LXK
# Gjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxSCwyoGIq0PhaA7Y+VPct5
# pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOmVQop36wUVUYklUy++vDW
# eEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3SkE/xIkgpfl22MM1itkZ
# 35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPXLQaUEggxMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# ci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAFJQfOChP7onn6fLI
# MKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D5W4wMwYeLystcEqfkjz4
# NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBYnbu0+THSuVHTe0VTTPVh
# ily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSIvgn0JksVBVMYVI5QFu/q
# hnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6aR9y34aiM1qmxaxBi6OU
# nyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4wPKC5OmHm1DQIt/MNokbb
# H3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7RTX8AdBPo0I6OEojf39z
# uFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK/fg8B2qjW88MT/WF5V5u
# vZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSKYBv0VisCzfxgeU+dquXW
# 9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkwYTu/9dLeH2pDqeJZAABV
# DWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVTQl0v4q8J/AUmQN5W4n10
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnlMIIZ4QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEINUPkA9v
# Zgi5dQWiO84EObcjW1zDubOkUx4LlhtSaiUNMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAHy9Mqk2+4lq4eSewBkbSlAm5uhNJfHdxSZ8dUdmr
# EtCDuV+kXpVx5bK1eMLOjbG0j1lqYa4E7xJlxG+B58kaNxWN7IKTMHAb5JllQPgo
# IdV7Vck7K01TwkuRgGjSREuziWwLt5wRx1CGW62/EYh0ZdGoX30ngt0HHh3sA1n7
# Jd3itiTE8/Ne6aEFxaDR74AWLSrmEHDooj69QzCHWRsM+ITw5rOgSWKAlEeaXgDr
# kCDa+QKX6uPuP16cM7177ru76YaojrmfNjrsVnA5TvKv7AXsD4N3Stjt2LB1iY4Y
# x9d/clEdlpMUGYHpSTNsvVoRoWwhPUSMZk4DSWxeVVenm6GCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCCsOFthDbODfXtp3OyWhO2703ccm0gt6HE0xWgQ
# opIMZgIGaqqQuLadGBMyMDI2MTEwMTAwMDY1NC45MjRaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046RjAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiAk4ebgF7m0jgABAAAC
# IDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTJaFw0yNzA1MTcxOTM5NTJaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046RjAwMi0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDRYY7yr7ijW6CR178uKveIMufu
# tWOicxgJwKOce/2GOQceus6ZWfX14i3jNg3JOP7MGJMkOAucwWBwiA8URp+ZYkGj
# pVoVkGZsV27WjqLwpf2AwqBsJ/TzqwE7JFFaxup3Ldxj8GjdJymDFRrdVN/pYHoB
# FrjD1IkIDu8b1CWn8tgomiKRSY+STvJq99mVkdphMBIUGOegQny8qRd24VME0xi8
# Oomks9Zq9EjDeKHGpvAbXUEQ6m3cROoEPhTE/miweQH9TqJt3IOsqPv3L8urojB7
# 47XBC2y0CDIHlKLcLl3ZG8D7JXKnWTFen3msMPJpcvrQ3zUBVJrH/mI3RxHmCh9p
# pDP0uG1+PJwk6H/x+sfoG9hW64xoXkpx6DEfNZNfcXdKbXF28XEXdLNnzo3SLNVy
# meQJhNqOSKhnU84QnKmrjEk541JiurlDCkCWO9lUBUMb9x0nyfXUbNRPVLgP+PTM
# RdXOowJdYCzCQfN2ZqL0s4YI28F1Dbn7Bgw2E4P1E9unsvMzJHtzhS2Th3TpCfBb
# OGalIlF9x/DJZ/ssm/yyzT9YtIFeqmfNxBPTE3aOuh6HxmTICzfYAATvWNhBbo19
# QwsjPeA9JvhqTLC2KUNgrXroGy4eDZo0n7jFYjZkUih1Ty+8E6qEvV2Na6Z5gUyD
# 5a+tHGDmq69CmUiHfwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFNvInOCIhxGA8mY7
# l1g07UHvyNgzMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQCtKGBto1BSvm4WFI+J
# 0NSyVhU1LHL7F3fbjZ2d7F5Kn/FCTBZXpzrDVl63FLRNcIFpnJy4/nlg43r7T5sJ
# Pdo4Ms8ADSHQEJnHSu3x9UpjCzREBPi9+nHhvDgRx/1WmBD6gQUZJLOhcN2TxW4K
# JyhinMtiBFtkNRZ2vmZ1MAdNXTm5d0Lwk3wzj+/f7VCCTWCXJSoqNa3VU/6sACHI
# 97Evbnzg8bd3hxrfz6CcCVuf77egvRHinthJuwSRePP7aVmcevb1nWUIAICdBebH
# QOrzNIeWBIQwvcFaS3SFc+49rqrwQOMFDR4FYBzS7b0QeBVxFuLL2iVu4KAHMNUh
# LLSD4iKLDFBNTOtTzTlhGvMgG77A1cjeQrDMHa6oReMDeUDqHUrxv8g7IRdIh+h0
# gDLkzN0xIuzli0Bv7JtybGJbV6JxaDF4CzSCIMRpK59nI6iKo4LgnbQBZJW7+6ak
# YsKG/pXPlfxNv2InpD10tSCkCvw9kr6W1+NRN+EuZczRgAwWlcK9XJZ3uu/v/oxH
# tO7/kmVIs51F9qV6Y2QNXd6tU46YPrK98m2QDys+lvLNimK0e1xZ7Z1GawKohKGv
# lLALWDlZQqgHfJ31CB0LlIDI7iLyYTpd2iyKjqskbQiyMtICH+RmH/oCg7JOK0ZA
# 3XIMba9aSWgBF3QZ6pG3EGeQqjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
# AAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVow
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX
# 9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1q
# UoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8d
# q6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byN
# pOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2k
# rnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4d
# Pf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgS
# Uei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8
# QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6Cm
# gyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzF
# ER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQID
# AQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQU
# KqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1
# GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0
# bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMA
# QTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbL
# j+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1p
# Y3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0w
# Ni0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIz
# LmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwU
# tj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN
# 3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU
# 5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5
# KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGy
# qVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB6
# 2FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltE
# AY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFp
# AUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcd
# FYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRb
# atGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQd
# VTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkYwMDItMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQCTGA9vpsJ6glqCLmI0rggGx4YEEqCBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7pBaHDAiGA8y
# MDI2MTAzMTEyMTQyMFoYDzIwMjYxMTAxMTIxNDIwWjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDukFocAgEAMAoCAQACAgUgAgH/MAcCAQACAhUEMAoCBQDukaucAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAEbV+xYNBGZIZqDw/E1fHVrZfIZu
# LI9dwP9yL520w8m1n/GOlHjMPP0jVKVF4pG1fMRdZw48nOkIUqd6GqSLssHyKcqS
# ko3AfmJiNKBCkmaY+9FOZU+cZyUFslVeIDnWkK8XPAB82Ifjt7O7YB2KQshK1GCu
# SHrDxc0ce03ByChK32zS+bweYfsDH7p48rwulxT/jvk2CnkR7B8sTTIaaYnmXxDa
# UvrwK8FBasOdLoEydspsz9SdrN3LAOpE6bTC67c5bLkLNFyCIPMAmPzAMqg3uooA
# TKi+CFnlP1gCnOhQxccdp0qH5u6Qg7nMD/gKlU34wY16Oc0S21u9/r+xxSsxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiAk
# 4ebgF7m0jgABAAACIDANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCaHqptVk6ewY9ykACuyse1vBY7
# 1fifaU3/yZZTr4m55TCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EION7vyOl
# PA1VqlEp0QIVGlNd8S5YWBnKj97LuTWHSO2vMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIgJOHm4Be5tI4AAQAAAiAwIgQg/Ec4lgHD
# 70u6fWo3UgfALef47bdmdw+Pm2qSr7Ka230wDQYJKoZIhvcNAQELBQAEggIANGAw
# ZoyJAdeoDJDN1fQIyYApWig2jmdyuy84GTPxWHWPHxFI48FfIA7XiezMO71pj4hm
# HCCVryZYO5eA+KTtfo/0Nu+1bNgldW8XR2SlGx96YjeYbGq2JczZdNVKWxd4bKJ/
# G9id007KCHvq7UDxV+/28xHJKekx84q4ywueMEh4HckVjdU0WkZDQAO/N4oY5aEV
# LIvHXME2/wXkfoTGSdH8FxqFMG4oRWjO5gjWG4Wt3jY3J3dfzL9yd2qCwqNi4lWH
# xzieaipEXkQLrAUaOhhqdhuISzFJ1HX3faa5yog+1Rmo5OTWxQOLa7++EUVAmw7l
# XIjLmgqvwQenVn096dlUzk4hiXes7ZQXFCmFLhU1zMAhiRapDjDFjK6dnVkYj5nu
# CskWqF8L61x2trW1+287UihdkX2BWAw5fLNecLKP2/KUlFD7m1lmSBP/izYDbwEG
# IjIX6KzYsBaEU9hDgw6t81Vjf0rBwx1gO+ZMcNg4ihO5WRHSR731ohWIrw22ODBN
# vtajgfYSIztKLUGz6HVfHwCEk0nU/UIxBUf1suTwiGMcXqEhB7ODuyYzmCrT63QX
# uNmOTYB2otOCfQSw5y4Bhs7nPQKaiay79b9dyVz9BbJuLGEqN1hd9BVAeYfzzim+
# LDFZ3pkwkr+9MP3FqMSdldA5g3mJGzLfm5O0m1w=
# SIG # End signature block
