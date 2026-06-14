param(
    [string]$ConfigPath = "C:\ProgramData\ProVideTransfer\transfer-config.json"
)

$ErrorActionPreference = "Stop"

function Get-ObjectValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue
    )

    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) {
        return $Object.$Name
    }

    return $DefaultValue
}

function Read-TransferConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $encoding)
}

function Add-AuditEntry {
    param(
        [object]$Config,
        [object]$Job,
        [string]$Message
    )

    $logDir = Join-Path $Config.StateRoot "logs"
    Ensure-Directory $logDir
    $logPath = Join-Path $logDir ("transfer-status-{0}.jsonl" -f (Get-Date -Format "yyyy-MM-dd"))
    $entry = [ordered]@{
        Id = $Job.Id
        Status = $Job.Status
        LocalPath = $Job.LocalPath
        FtpPath = $Job.FtpPath
        UserName = $Job.UserName
        Customer = $Job.Customer
        InputSubfolder = $Job.InputSubfolder
        Timestamp = ([DateTimeOffset]::UtcNow.ToString("o"))
        Message = $Message
    }
    Add-Content -LiteralPath $logPath -Value ($entry | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8
}

function Test-PatternList {
    param(
        [string]$Path,
        [object[]]$Patterns
    )

    $fileName = [System.IO.Path]::GetFileName($Path)
    foreach ($pattern in @($Patterns)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$pattern) -and $fileName -like [string]$pattern) {
            return $true
        }
    }

    return $false
}

function Get-InboundPathInfo {
    param(
        [string]$Path,
        [object]$Config
    )

    $inboundRoot = [string](Get-ObjectValue -Object $Config -Name "InboundRoot" -DefaultValue "C:\Users\Public\sftp_file_upload_root")
    $inboundFolder = [string](Get-ObjectValue -Object $Config -Name "InboundFolderName" -DefaultValue "in")
    $outboundFolder = [string](Get-ObjectValue -Object $Config -Name "OutboundFolderName" -DefaultValue "out")
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($inboundRoot).TrimEnd('\')

    if (-not $fullPath.StartsWith($fullRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ IsInbound = $false; Customer = ""; InputSubfolder = ""; Reason = "Source path is outside InboundRoot." }
    }

    $relative = $fullPath.Substring($fullRoot.Length + 1)
    $parts = $relative -split "[\\/]"
    if ($parts.Count -lt 3) {
        return [pscustomobject]@{ IsInbound = $false; Customer = ""; InputSubfolder = ""; Reason = "Source path is not under a customer inbound folder." }
    }

    if ($parts[1].Equals($outboundFolder, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ IsInbound = $false; Customer = $parts[0]; InputSubfolder = ""; Reason = "Outbound folder is not processed." }
    }

    if (-not $parts[1].Equals($inboundFolder, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ IsInbound = $false; Customer = $parts[0]; InputSubfolder = ""; Reason = "Source path is not under the inbound folder." }
    }

    $inputSubfolder = ""
    if ($parts.Count -gt 3) {
        $inputSubfolder = [string]::Join("\", $parts[2..($parts.Count - 2)])
    }

    return [pscustomobject]@{ IsInbound = $true; Customer = $parts[0]; InputSubfolder = $inputSubfolder; Reason = "" }
}

function Test-CandidatePath {
    param(
        [object]$Config,
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    if (Test-PatternList -Path $Path -Patterns @(Get-ObjectValue -Object $Config -Name "IgnoredPatterns" -DefaultValue @("*.filepart", "*.partial", "*.tmp"))) {
        return $false
    }

    if (-not (Test-PatternList -Path $Path -Patterns @(Get-ObjectValue -Object $Config -Name "AllowedPatterns" -DefaultValue @("*.csv", "*.xls", "*.xlsx", "*.pdf")))) {
        return $false
    }

    $info = Get-InboundPathInfo -Path $Path -Config $Config
    return [bool]$info.IsInbound
}

function Get-KnownLocalPaths {
    param([object]$Config)

    $paths = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    foreach ($bucket in @("queue", "processing", "failed")) {
        $dir = Join-Path $Config.StateRoot $bucket
        if (-not (Test-Path -LiteralPath $dir)) {
            continue
        }

        Get-ChildItem -LiteralPath $dir -Filter "*.json" -File | ForEach-Object {
            try {
                $job = Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace([string]$job.LocalPath)) {
                    [void]$paths.Add([System.IO.Path]::GetFullPath([string]$job.LocalPath))
                }
            }
            catch {
            }
        }
    }

    return ,$paths
}

function New-TransferJob {
    param(
        [object]$Config,
        [string]$LocalPath,
        [string]$FtpPath,
        [string]$UserName,
        [string]$Source
    )

    $now = [DateTimeOffset]::UtcNow
    $id = [guid]::NewGuid().ToString("N")
    $fullLocalPath = [System.IO.Path]::GetFullPath($LocalPath)
    $pathInfo = Get-InboundPathInfo -Path $fullLocalPath -Config $Config
    $customer = if ([string]::IsNullOrWhiteSpace($UserName)) { [string]$pathInfo.Customer } else { $UserName.Trim() }
    $job = [ordered]@{
        Id = $id
        Status = "Queued"
        LocalPath = $fullLocalPath
        FtpPath = $FtpPath
        UserName = $customer
        Customer = $customer
        ClientIp = ""
        EventName = ""
        CreatedAt = $now.ToString("o")
        UpdatedAt = $now.ToString("o")
        NextAttemptAt = $now.ToString("o")
        AttemptCount = 0
        Source = $Source
        LastError = ""
        ErrorCategory = ""
        LockedSince = ""
        CompletedAt = ""
        InputSubfolder = [string]$pathInfo.InputSubfolder
        RouteName = ""
        DestinationPath = ""
        PartialPath = ""
        ArchivePath = ""
        SourceLength = $null
        DestinationLength = $null
        SourceHash = ""
        DestinationHash = ""
    }

    $queueDir = Join-Path $Config.StateRoot "queue"
    Ensure-Directory $queueDir
    $fileName = "{0}_{1}.json" -f (Get-Date -Format "yyyyMMddHHmmssfff"), $id
    $tmpPath = Join-Path $queueDir ($fileName + ".tmp")
    $jobPath = Join-Path $queueDir $fileName
    Write-JsonFile -Path $tmpPath -Value $job
    Move-Item -LiteralPath $tmpPath -Destination $jobPath
    Add-AuditEntry -Config $Config -Job ([pscustomobject]$job) -Message "Upload job queued by reconciliation."
}

function Add-SourceRootJobs {
    param(
        [object]$Config,
        [System.Collections.Generic.HashSet[string]]$KnownPaths
    )

    $inboundRoot = [string](Get-ObjectValue -Object $Config -Name "InboundRoot" -DefaultValue "C:\Users\Public\sftp_file_upload_root")
    $inboundFolder = [string](Get-ObjectValue -Object $Config -Name "InboundFolderName" -DefaultValue "in")
    if (-not (Test-Path -LiteralPath $inboundRoot)) {
        return
    }

    Get-ChildItem -LiteralPath $inboundRoot -Directory | ForEach-Object {
        $inboundDir = Join-Path $_.FullName $inboundFolder
        if (-not (Test-Path -LiteralPath $inboundDir -PathType Container)) {
            return
        }

        Get-ChildItem -LiteralPath $inboundDir -File -Recurse | ForEach-Object {
            $fullPath = [System.IO.Path]::GetFullPath($_.FullName)
            if ($KnownPaths.Contains($fullPath)) {
                return
            }

            if (-not (Test-CandidatePath -Config $Config -Path $fullPath)) {
                return
            }

            $pathInfo = Get-InboundPathInfo -Path $fullPath -Config $Config
            New-TransferJob -Config $Config -LocalPath $fullPath -FtpPath "" -UserName ([string]$pathInfo.Customer) -Source "SourceRootScan"
            [void]$KnownPaths.Add($fullPath)
        }
    }
}

function Add-ProVideStorJobs {
    param(
        [object]$Config,
        [System.Collections.Generic.HashSet[string]]$KnownPaths
    )

    $logRoot = [string](Get-ObjectValue -Object $Config -Name "ProVideLogRoot" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($logRoot) -or -not (Test-Path -LiteralPath $logRoot)) {
        return
    }

    Get-ChildItem -LiteralPath $logRoot -Filter "stor-*.log" -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 14 | ForEach-Object {
        Get-Content -LiteralPath $_.FullName | ForEach-Object {
            $parts = $_ -split "\|"
            if ($parts.Count -lt 4) {
                return
            }

            $localPath = [System.IO.Path]::GetFullPath($parts[0])
            if ($KnownPaths.Contains($localPath)) {
                return
            }

            if (-not (Test-CandidatePath -Config $Config -Path $localPath)) {
                return
            }

            $pathInfo = Get-InboundPathInfo -Path $localPath -Config $Config
            New-TransferJob -Config $Config -LocalPath $localPath -FtpPath "" -UserName ([string]$pathInfo.Customer) -Source "ProVideStorLog"
            [void]$KnownPaths.Add($localPath)
        }
    }
}

$config = Read-TransferConfig -Path $ConfigPath
foreach ($name in @("queue", "processing", "done", "failed", "logs", "locks")) {
    Ensure-Directory (Join-Path $config.StateRoot $name)
}

$lockPath = Join-Path (Join-Path $config.StateRoot "locks") "reconcile-transfer-state.lock"
$lockStream = $null
try {
    $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
}
catch {
    exit 0
}

try {
    $knownPaths = Get-KnownLocalPaths -Config $config
    Add-SourceRootJobs -Config $config -KnownPaths $knownPaths
    Add-ProVideStorJobs -Config $config -KnownPaths $knownPaths
}
finally {
    if ($lockStream) {
        $lockStream.Dispose()
    }
}
