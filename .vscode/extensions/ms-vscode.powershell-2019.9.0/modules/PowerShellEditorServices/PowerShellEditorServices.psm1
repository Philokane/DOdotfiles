#
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#

if (!$PSVersionTable.PSEdition -or $PSVersionTable.PSEdition -eq "Desktop") {
    Microsoft.PowerShell.Utility\Add-Type -Path "$PSScriptRoot/bin/Desktop/Microsoft.PowerShell.EditorServices.dll"
    Microsoft.PowerShell.Utility\Add-Type -Path "$PSScriptRoot/bin/Desktop/Microsoft.PowerShell.EditorServices.Host.dll"
}
else {
    Microsoft.PowerShell.Utility\Add-Type -Path "$PSScriptRoot/bin/Core/Microsoft.PowerShell.EditorServices.dll"
    Microsoft.PowerShell.Utility\Add-Type -Path "$PSScriptRoot/bin/Core/Microsoft.PowerShell.EditorServices.Protocol.dll"
    Microsoft.PowerShell.Utility\Add-Type -Path "$PSScriptRoot/bin/Core/Microsoft.PowerShell.EditorServices.Host.dll"
}

function Start-EditorServicesHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $HostName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $HostProfileId,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $HostVersion,

        [Parameter(ParameterSetName="Stdio",Mandatory=$true)]
        [switch]
        $Stdio,

        [Parameter(ParameterSetName="NamedPipe",Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $LanguageServiceNamedPipe,

        [Parameter(ParameterSetName="NamedPipe")]
        [string]
        $DebugServiceNamedPipe,

        [Parameter(ParameterSetName="NamedPipeSimplex",Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $LanguageServiceInNamedPipe,

        [Parameter(ParameterSetName="NamedPipeSimplex",Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $LanguageServiceOutNamedPipe,

        [Parameter(ParameterSetName="NamedPipeSimplex")]
        [string]
        $DebugServiceInNamedPipe,

        [Parameter(ParameterSetName="NamedPipeSimplex")]
        [string]
        $DebugServiceOutNamedPipe,

        [ValidateNotNullOrEmpty()]
        [string]
        $BundledModulesPath,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $LogPath,

        [ValidateSet("Normal", "Verbose", "Error", "Diagnostic")]
        $LogLevel = "Normal",

        [switch]
        $EnableConsoleRepl,

        [switch]
        $DebugServiceOnly,

        [string[]]
        $AdditionalModules = @(),

        [string[]]
        [ValidateNotNull()]
        $FeatureFlags = @(),

        [switch]
        $WaitForDebugger
    )

    $editorServicesHost = $null
    $hostDetails =
        Microsoft.PowerShell.Utility\New-Object Microsoft.PowerShell.EditorServices.Session.HostDetails @(
            $HostName,
            $HostProfileId,
            (Microsoft.PowerShell.Utility\New-Object System.Version @($HostVersion)))

    $editorServicesHost =
        Microsoft.PowerShell.Utility\New-Object Microsoft.PowerShell.EditorServices.Host.EditorServicesHost @(
            $hostDetails,
            $BundledModulesPath,
            $EnableConsoleRepl.IsPresent,
            $WaitForDebugger.IsPresent,
            $AdditionalModules,
            $FeatureFlags)

    # Build the profile paths using the root paths of the current $profile variable
    $profilePaths =
        Microsoft.PowerShell.Utility\New-Object Microsoft.PowerShell.EditorServices.Session.ProfilePaths @(
            $hostDetails.ProfileId,
            [System.IO.Path]::GetDirectoryName($profile.AllUsersAllHosts),
            [System.IO.Path]::GetDirectoryName($profile.CurrentUserAllHosts))

    $editorServicesHost.StartLogging($LogPath, $LogLevel);

    $languageServiceConfig =
        Microsoft.PowerShell.Utility\New-Object Microsoft.PowerShell.EditorServices.Host.EditorServiceTransportConfig

    $debugServiceConfig =
        Microsoft.PowerShell.Utility\New-Object Microsoft.PowerShell.EditorServices.Host.EditorServiceTransportConfig

    switch ($PSCmdlet.ParameterSetName) {
        "Stdio" {
            $languageServiceConfig.TransportType = [Microsoft.PowerShell.EditorServices.Host.EditorServiceTransportType]::Stdio
            $debugServiceConfig.TransportType    = [Microsoft.PowerShell.EditorServices.Host.EditorServiceTransportType]::Stdio
            break
        }
        "NamedPipe" {
            $languageServiceConfig.TransportType = [Microsoft.PowerShell.EditorServices.Host.EditorServiceTransportType]::NamedPipe
            $languageServiceConfig.InOutPipeName = "$LanguageServiceNamedPipe"
            if ($DebugServiceNamedPipe) {
                $debugServiceConfig.TransportType = [Microsoft.PowerShell.EditorServices.Host.EditorServiceTransportType]::NamedPipe
                $debugServiceConfig.InOutPipeName = "$DebugServiceNamedPipe"
            }
            break
        }
        "NamedPipeSimplex" {
            $languageServiceConfig.TransportType = [Microsoft.PowerShell.EditorServices.Host.EditorServiceTransportType]::NamedPipe
            $languageServiceConfig.InPipeName = $LanguageServiceInNamedPipe
            $languageServiceConfig.OutPipeName = $LanguageServiceOutNamedPipe
            if ($DebugServiceInNamedPipe -and $DebugServiceOutNamedPipe) {
                $debugServiceConfig.TransportType = [Microsoft.PowerShell.EditorServices.Host.EditorServiceTransportType]::NamedPipe
                $debugServiceConfig.InPipeName = $DebugServiceInNamedPipe
                $debugServiceConfig.OutPipeName = $DebugServiceOutNamedPipe
            }
            break
        }
    }

    if ($DebugServiceOnly.IsPresent) {
        $editorServicesHost.StartDebugService($debugServiceConfig, $profilePaths, $false);
    } elseif($Stdio.IsPresent) {
        $editorServicesHost.StartLanguageService($languageServiceConfig, $profilePaths);
    } else {
        $editorServicesHost.StartLanguageService($languageServiceConfig, $profilePaths);
        $editorServicesHost.StartDebugService($debugServiceConfig, $profilePaths, $true);
    }

    return $editorServicesHost
}

function Compress-LogDir {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$true, Position=0, HelpMessage="Literal path to a log directory.")]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path
    )

    begin {
        function LegacyZipFolder($Path, $ZipPath) {
            if (!(Microsoft.PowerShell.Management\Test-Path($ZipPath))) {
                $zipMagicHeader = "PK" + [char]5 + [char]6 + ("$([char]0)" * 18)
                Microsoft.PowerShell.Management\Set-Content -LiteralPath $ZipPath -Value $zipMagicHeader
                (Microsoft.PowerShell.Management\Get-Item $ZipPath).IsReadOnly = $false
            }

            $shellApplication = Microsoft.PowerShell.Utility\New-Object -ComObject Shell.Application
            $zipPackage = $shellApplication.NameSpace($ZipPath)

            foreach ($file in (Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $Path)) {
                $zipPackage.CopyHere($file.FullName)
                Start-Sleep -MilliSeconds 500
            }
        }
    }

    end {
        $zipPath = ((Microsoft.PowerShell.Management\Convert-Path $Path) -replace '(\\|/)$','') + ".zip"

        if (Get-Command Microsoft.PowerShell.Archive\Compress-Archive) {
            if ($PSCmdlet.ShouldProcess($zipPath, "Create ZIP")) {
                Microsoft.PowerShell.Archive\Compress-Archive -LiteralPath $Path -DestinationPath $zipPath -Force -CompressionLevel Optimal
                $zipPath
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess($zipPath, "Create Legacy ZIP")) {
                LegacyZipFolder $Path $zipPath
                $zipPath
            }
        }
    }
}

function Get-PowerShellEditorServicesVersion {
    $nl = [System.Environment]::NewLine

    $versionInfo = "PSES module version: $($MyInvocation.MyCommand.Module.Version)$nl"

    $versionInfo += "PSVersion:           $($PSVersionTable.PSVersion)$nl"
    if ($PSVersionTable.PSEdition) {
        $versionInfo += "PSEdition:           $($PSVersionTable.PSEdition)$nl"
    }
    $versionInfo += "PSBuildVersion:      $($PSVersionTable.BuildVersion)$nl"
    $versionInfo += "CLRVersion:          $($PSVersionTable.CLRVersion)$nl"

    $versionInfo += "Operating system:    "
    if ($IsLinux) {
        $versionInfo += "Linux $(lsb_release -d -s)$nl"
    }
    elseif ($IsOSX) {
        $versionInfo += "macOS $(lsb_release -d -s)$nl"
    }
    else {
        $osInfo = CimCmdlets\Get-CimInstance Win32_OperatingSystem
        $versionInfo += "Windows $($osInfo.OSArchitecture) $($osInfo.Version)$nl"
    }

    $versionInfo
}

# SIG # Begin signature block
# MIIjhgYJKoZIhvcNAQcCoIIjdzCCI3MCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDR1REVu3GXc3N3
# qzJDWZcPVRVtL7olbpu/BbLfDfMIHqCCDYEwggX/MIID56ADAgECAhMzAAABUZ6N
# j0Bxow5BAAAAAAFRMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMTkwNTAyMjEzNzQ2WhcNMjAwNTAyMjEzNzQ2WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQCVWsaGaUcdNB7xVcNmdfZiVBhYFGcn8KMqxgNIvOZWNH9JYQLuhHhmJ5RWISy1
# oey3zTuxqLbkHAdmbeU8NFMo49Pv71MgIS9IG/EtqwOH7upan+lIq6NOcw5fO6Os
# +12R0Q28MzGn+3y7F2mKDnopVu0sEufy453gxz16M8bAw4+QXuv7+fR9WzRJ2CpU
# 62wQKYiFQMfew6Vh5fuPoXloN3k6+Qlz7zgcT4YRmxzx7jMVpP/uvK6sZcBxQ3Wg
# B/WkyXHgxaY19IAzLq2QiPiX2YryiR5EsYBq35BP7U15DlZtpSs2wIYTkkDBxhPJ
# IDJgowZu5GyhHdqrst3OjkSRAgMBAAGjggF+MIIBejAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUV4Iarkq57esagu6FUBb270Zijc8w
# UAYDVR0RBEkwR6RFMEMxKTAnBgNVBAsTIE1pY3Jvc29mdCBPcGVyYXRpb25zIFB1
# ZXJ0byBSaWNvMRYwFAYDVQQFEw0yMzAwMTIrNDU0MTM1MB8GA1UdIwQYMBaAFEhu
# ZOVQBdOCqhc3NyK1bajKdQKVMFQGA1UdHwRNMEswSaBHoEWGQ2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY0NvZFNpZ1BDQTIwMTFfMjAxMS0w
# Ny0wOC5jcmwwYQYIKwYBBQUHAQEEVTBTMFEGCCsGAQUFBzAChkVodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY0NvZFNpZ1BDQTIwMTFfMjAx
# MS0wNy0wOC5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAgEAWg+A
# rS4Anq7KrogslIQnoMHSXUPr/RqOIhJX+32ObuY3MFvdlRElbSsSJxrRy/OCCZdS
# se+f2AqQ+F/2aYwBDmUQbeMB8n0pYLZnOPifqe78RBH2fVZsvXxyfizbHubWWoUf
# NW/FJlZlLXwJmF3BoL8E2p09K3hagwz/otcKtQ1+Q4+DaOYXWleqJrJUsnHs9UiL
# crVF0leL/Q1V5bshob2OTlZq0qzSdrMDLWdhyrUOxnZ+ojZ7UdTY4VnCuogbZ9Zs
# 9syJbg7ZUS9SVgYkowRsWv5jV4lbqTD+tG4FzhOwcRQwdb6A8zp2Nnd+s7VdCuYF
# sGgI41ucD8oxVfcAMjF9YX5N2s4mltkqnUe3/htVrnxKKDAwSYliaux2L7gKw+bD
# 1kEZ/5ozLRnJ3jjDkomTrPctokY/KaZ1qub0NUnmOKH+3xUK/plWJK8BOQYuU7gK
# YH7Yy9WSKNlP7pKj6i417+3Na/frInjnBkKRCJ/eYTvBH+s5guezpfQWtU4bNo/j
# 8Qw2vpTQ9w7flhH78Rmwd319+YTmhv7TcxDbWlyteaj4RK2wk3pY1oSz2JPE5PNu
# Nmd9Gmf6oePZgy7Ii9JLLq8SnULV7b+IP0UXRY9q+GdRjM2AEX6msZvvPCIoG0aY
# HQu9wZsKEK2jqvWi8/xdeeeSI9FN6K1w4oVQM4Mwggd6MIIFYqADAgECAgphDpDS
# AAAAAAADMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMTAeFw0xMTA3MDgyMDU5MDlaFw0yNjA3MDgyMTA5MDla
# MH4xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMT
# H01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQCr8PpyEBwurdhuqoIQTTS68rZYIZ9CGypr6VpQqrgG
# OBoESbp/wwwe3TdrxhLYC/A4wpkGsMg51QEUMULTiQ15ZId+lGAkbK+eSZzpaF7S
# 35tTsgosw6/ZqSuuegmv15ZZymAaBelmdugyUiYSL+erCFDPs0S3XdjELgN1q2jz
# y23zOlyhFvRGuuA4ZKxuZDV4pqBjDy3TQJP4494HDdVceaVJKecNvqATd76UPe/7
# 4ytaEB9NViiienLgEjq3SV7Y7e1DkYPZe7J7hhvZPrGMXeiJT4Qa8qEvWeSQOy2u
# M1jFtz7+MtOzAz2xsq+SOH7SnYAs9U5WkSE1JcM5bmR/U7qcD60ZI4TL9LoDho33
# X/DQUr+MlIe8wCF0JV8YKLbMJyg4JZg5SjbPfLGSrhwjp6lm7GEfauEoSZ1fiOIl
# XdMhSz5SxLVXPyQD8NF6Wy/VI+NwXQ9RRnez+ADhvKwCgl/bwBWzvRvUVUvnOaEP
# 6SNJvBi4RHxF5MHDcnrgcuck379GmcXvwhxX24ON7E1JMKerjt/sW5+v/N2wZuLB
# l4F77dbtS+dJKacTKKanfWeA5opieF+yL4TXV5xcv3coKPHtbcMojyyPQDdPweGF
# RInECUzF1KVDL3SV9274eCBYLBNdYJWaPk8zhNqwiBfenk70lrC8RqBsmNLg1oiM
# CwIDAQABo4IB7TCCAekwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFEhuZOVQ
# BdOCqhc3NyK1bajKdQKVMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1Ud
# DwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFHItOgIxkEO5FAVO
# 4eqnxzHRI4k0MFoGA1UdHwRTMFEwT6BNoEuGSWh0dHA6Ly9jcmwubWljcm9zb2Z0
# LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcmwwXgYIKwYBBQUHAQEEUjBQME4GCCsGAQUFBzAChkJodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcnQwgZ8GA1UdIASBlzCBlDCBkQYJKwYBBAGCNy4DMIGDMD8GCCsGAQUFBwIB
# FjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2RvY3MvcHJpbWFyeWNw
# cy5odG0wQAYIKwYBBQUHAgIwNB4yIB0ATABlAGcAYQBsAF8AcABvAGwAaQBjAHkA
# XwBzAHQAYQB0AGUAbQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIBAGfyhqWY
# 4FR5Gi7T2HRnIpsLlhHhY5KZQpZ90nkMkMFlXy4sPvjDctFtg/6+P+gKyju/R6mj
# 82nbY78iNaWXXWWEkH2LRlBV2AySfNIaSxzzPEKLUtCw/WvjPgcuKZvmPRul1LUd
# d5Q54ulkyUQ9eHoj8xN9ppB0g430yyYCRirCihC7pKkFDJvtaPpoLpWgKj8qa1hJ
# Yx8JaW5amJbkg/TAj/NGK978O9C9Ne9uJa7lryft0N3zDq+ZKJeYTQ49C/IIidYf
# wzIY4vDFLc5bnrRJOQrGCsLGra7lstnbFYhRRVg4MnEnGn+x9Cf43iw6IGmYslmJ
# aG5vp7d0w0AFBqYBKig+gj8TTWYLwLNN9eGPfxxvFX1Fp3blQCplo8NdUmKGwx1j
# NpeG39rz+PIWoZon4c2ll9DuXWNB41sHnIc+BncG0QaxdR8UvmFhtfDcxhsEvt9B
# xw4o7t5lL+yX9qFcltgA1qFGvVnzl6UJS0gQmYAf0AApxbGbpT9Fdx41xtKiop96
# eiL6SJUfq/tHI4D1nvi/a7dLl+LrdXga7Oo3mXkYS//WsyNodeav+vyL6wuA6mk7
# r/ww7QRMjt/fdW1jkT3RnVZOT7+AVyKheBEyIXrvQQqxP/uozKRdwaGIm1dxVk5I
# RcBCyZt2WwqASGv9eZ/BvW1taslScxMNelDNMYIVWzCCFVcCAQEwgZUwfjELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9z
# b2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMQITMwAAAVGejY9AcaMOQQAAAAABUTAN
# BglghkgBZQMEAgEFAKCBrjAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgksZP/XUZ
# FMDDDur12Fwp+oGSJi2ub5mxEJXrPZqwPNYwQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQAgBrmA0g5WgSKYtHFTvgl1+oVWSp7bX2ibCpu7/HUn
# BUjqNGJ69IILBdHeTjJopQdR3tu0JSab4+L0BgaeL8iIbsBVnrM2ngiSI0YHOLpb
# RB9lpYaH4DQ65IBqaYR6poz6nwUvcCOEnOeLHJ6m12R6yWDRxmo6q69TcMj6jFk5
# sV+qJmZ20sTGLWdSJVP8NdTBVj+vwCnKdrlTb9DmjgyQ4OK5MA1O886G2YfrBLJT
# 0SUeNojiJrPNEXgJREgIA/t5MceVxNU7dyqs1Sdp31itwtQR6ZzpuOz332xBRgAo
# XI/a1hB+7kuT87egVy3R21OrFfa5QfBBlAV9UmJ1sVfkoYIS5TCCEuEGCisGAQQB
# gjcDAwExghLRMIISzQYJKoZIhvcNAQcCoIISvjCCEroCAQMxDzANBglghkgBZQME
# AgEFADCCAVEGCyqGSIb3DQEJEAEEoIIBQASCATwwggE4AgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEICRTJGD0RtQzsNf1CjkSEBfar4dlYVgkOO7/dUhS
# M52fAgZdb8hBR8YYEzIwMTkwOTIwMjM0MTM0LjA1OFowBIACAfSggdCkgc0wgcox
# CzAJBgNVBAYTAlVTMQswCQYDVQQIEwJXQTEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQg
# SXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJjAkBgNVBAsTHVRoYWxlcyBUU1Mg
# RVNOOkUwNDEtNEJFRS1GQTdFMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFt
# cCBzZXJ2aWNloIIOPDCCBPEwggPZoAMCAQICEzMAAADWnmWBjg0YozsAAAAAANYw
# DQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcN
# MTgwODIzMjAyNjQ5WhcNMTkxMTIzMjAyNjQ5WjCByjELMAkGA1UEBhMCVVMxCzAJ
# BgNVBAgTAldBMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlv
# bnMgTGltaXRlZDEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046RTA0MS00QkVFLUZB
# N0UxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIHNlcnZpY2UwggEiMA0G
# CSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDVz8BehZsCB+9oaa8v+wngEIhQqe02
# mIA57mmFSeE0+4I8xANhOj4MBzV9y0lpOp2zgQEeeIFP3lGbp9rV6OzcCw+TvFRs
# GSPGYLU8AzuDdQRo8sNbwJl+a/HwDRS+Q5QG5aSq+qMWtVrBRf+EZuYlILaWOOym
# uLMmaBJ+NadMeR0CP7KGJV5hwB6E04yynVHpy2mFEPAT4p+P2wBqsDePEdU6Mbtb
# FC8gFcOBhJ7NBQS1fzRT8ecxMuL60PdbQIC99fvaM5+lCn19SDwmHxaIbOWXTaw2
# GJyYzeBXgriQ8JpM1WNnKHyRzKLvrk593cgklSDc0PGg8gYAONY6NNuJAgMBAAGj
# ggEbMIIBFzAdBgNVHQ4EFgQUZ1Qwk+BJMRp+9k4XHKcRODePiPgwHwYDVR0jBBgw
# FoAU1WM6XIoxkPNDe3xGG8UzaFqFbVUwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDov
# L2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljVGltU3RhUENB
# XzIwMTAtMDctMDEuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNUaW1TdGFQQ0FfMjAx
# MC0wNy0wMS5jcnQwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEFBQcDCDAN
# BgkqhkiG9w0BAQsFAAOCAQEAT9KFgImb5aXD4JG1xS3+Zrf6ufSuWIQ9cbZwHDd9
# oxmNolN+zdL1Y/DyNWxiCBUG717EYmKBaKZbFj/0NH6nbW0H5fAbyJNB+LAAJYqI
# saMO7gN/CFfni//IIBVOwCL5vEWiVuK9HTrt/PQ0fC5kC5up23hrcrb4CGfxywAm
# YXOQX5zy0tOAoW6K3TOmcEghlzn3U06grq9hKf4F7Su2AmGN4V6JkHaGkegK8O3r
# Z7JcsmzokiV4o1cRwaE2OkyVPpsbn6vZVe/HQSxxNNoBVjCgTovzdUCA0BoSH+T7
# XO6bwhtU3J6zkjf+3hY9RYXHxHoyN+L7a5Yp0IZAj7wmvzCCBnEwggRZoAMCAQIC
# CmEJgSoAAAAAAAIwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRp
# ZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTEwMDcwMTIxMzY1NVoXDTI1MDcwMTIx
# NDY1NVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwggEiMA0GCSqGSIb3
# DQEBAQUAA4IBDwAwggEKAoIBAQCpHQ28dxGKOiDs/BOX9fp/aZRrdFQQ1aUKAIKF
# ++18aEssX8XD5WHCdrc+Zitb8BVTJwQxH0EbGpUdzgkTjnxhMFmxMEQP8WCIhFRD
# DNdNuDgIs0Ldk6zWczBXJoKjRQ3Q6vVHgc2/JGAyWGBG8lhHhjKEHnRhZ5FfgVSx
# z5NMksHEpl3RYRNuKMYa+YaAu99h/EbBJx0kZxJyGiGKr0tkiVBisV39dx898Fd1
# rL2KQk1AUdEPnAY+Z3/1ZsADlkR+79BL/W7lmsqxqPJ6Kgox8NpOBpG2iAg16Hgc
# sOmZzTznL0S6p/TcZL2kAcEgCZN4zfy8wMlEXV4WnAEFTyJNAgMBAAGjggHmMIIB
# 4jAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQU1WM6XIoxkPNDe3xGG8UzaFqF
# bVUwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMA8GA1Ud
# EwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186aGMQwVgYD
# VR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwv
# cHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsGAQUFBwEB
# BE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9j
# ZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwgaAGA1UdIAEB/wSBlTCB
# kjCBjwYJKwYBBAGCNy4DMIGBMD0GCCsGAQUFBwIBFjFodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vUEtJL2RvY3MvQ1BTL2RlZmF1bHQuaHRtMEAGCCsGAQUFBwICMDQe
# MiAdAEwAZQBnAGEAbABfAFAAbwBsAGkAYwB5AF8AUwB0AGEAdABlAG0AZQBuAHQA
# LiAdMA0GCSqGSIb3DQEBCwUAA4ICAQAH5ohRDeLG4Jg/gXEDPZ2joSFvs+umzPUx
# vs8F4qn++ldtGTCzwsVmyWrf9efweL3HqJ4l4/m87WtUVwgrUYJEEvu5U4zM9GAS
# inbMQEBBm9xcF/9c+V4XNZgkVkt070IQyK+/f8Z/8jd9Wj8c8pl5SpFSAK84Dxf1
# L3mBZdmptWvkx872ynoAb0swRCQiPM/tA6WWj1kpvLb9BOFwnzJKJ/1Vry/+tuWO
# M7tiX5rbV0Dp8c6ZZpCM/2pif93FSguRJuI57BlKcWOdeyFtw5yjojz6f32WapB4
# pm3S4Zz5Hfw42JT0xqUKloakvZ4argRCg7i1gJsiOCC1JeVk7Pf0v35jWSUPei45
# V3aicaoGig+JFrphpxHLmtgOR5qAxdDNp9DvfYPw4TtxCd9ddJgiCGHasFAeb73x
# 4QDf5zEHpJM692VHeOj4qEir995yfmFrb3epgcunCaw5u+zGy9iCtHLNHfS4hQEe
# gPsbiSpUObJb2sgNVZl6h3M7COaYLeqN4DMuEin1wC9UJyH3yKxO2ii4sanblrKn
# QqLJzxlBTeCG+SqaoxFmMNO7dDJL32N79ZmKLxvHIa9Zta7cRDyXUHHXodLFVeNp
# 3lfB0d4wwP3M5k37Db9dT+mdHhk4L7zPWAUu7w2gUDXa7wknHNWzfjUeCLraNtvT
# X4/edIhJEqGCAs4wggI3AgEBMIH4oYHQpIHNMIHKMQswCQYDVQQGEwJVUzELMAkG
# A1UECBMCV0ExEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEtMCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9u
# cyBMaW1pdGVkMSYwJAYDVQQLEx1UaGFsZXMgVFNTIEVTTjpFMDQxLTRCRUUtRkE3
# RTElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgc2VydmljZaIjCgEBMAcG
# BSsOAwIaAxUAD1RfSr8v62EwlfSujM+3vZAgFdGggYMwgYCkfjB8MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQg
# VGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQUFAAIFAOEvXnEwIhgPMjAx
# OTA5MjAyMjE5MjlaGA8yMDE5MDkyMTIyMTkyOVowdzA9BgorBgEEAYRZCgQBMS8w
# LTAKAgUA4S9ecQIBADAKAgEAAgIOOQIB/zAHAgEAAgIRkTAKAgUA4TCv8QIBADA2
# BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIB
# AAIDAYagMA0GCSqGSIb3DQEBBQUAA4GBAB0zJBZ9xECOEjFPFPy52omKzZPUZp0V
# EgDOBqC+5QW5BsdCJN4aT3jjkwqFTCNwaRzgiOxETBPQti6hQnyieCeINPawoXgA
# JXt7ljgP6iAx3hHLWKGlv/25/Hrv/mUs9msmMpw9TPcWJGSSjfoactMrCqwxUNjY
# OsoheAuV6CghMYIDDTCCAwkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENB
# IDIwMTACEzMAAADWnmWBjg0YozsAAAAAANYwDQYJYIZIAWUDBAIBBQCgggFKMBoG
# CSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgDLi0lBpe
# WPXogvHpNsOUf2y7OZYcGQlXwl7aG+ZNdN8wgfoGCyqGSIb3DQEJEAIvMYHqMIHn
# MIHkMIG9BCAMpxcbLzk+qbGa3mRFNyw6oaNx47F25Vv+0ZgnLpRIzjCBmDCBgKR+
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAAA1p5lgY4NGKM7AAAA
# AADWMCIEIGVSBCZLkdpRzaB+pbu29xpqOSFu0n94CBvhi2r8qXqhMA0GCSqGSIb3
# DQEBCwUABIIBAFRSNuOw/G8w9SoSIOm5Apf4UQDdD8ebXbEe2QdxH48Z90o07m+Z
# cBoym2IOcmPFRvp7XiApuKP3iwZs5pHQj6V8ANL7nDl2qepvVO/6yJggieTJc/ty
# 8c3tIjcbzIOqT2TYl7qFebFwXNOK7Yy88Ke4mhFJWOoTjB7Kd1yYnss/b7fIPvAl
# J3C4t3nmhIsXkhHteuHrq3Yn2SYAftfot2FUgjv+MB6KO+GBtx+GixAEDCDawBlA
# FwAny2xn/5dRPqfDZKNwSC6txDiR4aHz7C0GW0OXnDmdYYq+nTZ+akICaBL8wY2F
# uKsYjtJUqqkef0vS3wlyMoHhlJOLbrT4KCY=
# SIG # End signature block
