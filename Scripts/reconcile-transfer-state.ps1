param(
    [string]$ConfigPath = "C:\ProgramData\ProVideTransfer\transfer-config.json"
)

$ErrorActionPreference = "Stop"

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

    $json = $Value | ConvertTo-Json -Depth 10
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
        Timestamp = ([DateTimeOffset]::UtcNow.ToString("o"))
        Message = $Message
    }
    Add-Content -LiteralPath $logPath -Value ($entry | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8
}

function Test-AllowedPattern {
    param(
        [string]$Path,
        [object[]]$Patterns
    )

    $fileName = [System.IO.Path]::GetFileName($Path)
    foreach ($pattern in $Patterns) {
        if ($fileName -like [string]$pattern) {
            return $true
        }
    }

    return $false
}

function Test-PathUnderRoot {
    param(
        [string]$Path,
        [object[]]$Roots
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace([string]$root)) {
            continue
        }

        $fullRoot = [System.IO.Path]::GetFullPath([string]$root).TrimEnd('\')
        if ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        if ($fullPath.StartsWith($fullRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-CustomerFromPath {
    param(
        [string]$Path,
        [object]$Config
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    foreach ($root in $Config.SourceRoots) {
        $fullRoot = [System.IO.Path]::GetFullPath([string]$root).TrimEnd('\')
        if ($fullPath.StartsWith($fullRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $fullPath.Substring($fullRoot.Length + 1)
            $parts = $relative -split "[\\/]"
            if ($parts.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($parts[0])) {
                return $parts[0]
            }
        }
    }

    return "Unknown"
}

function Get-KnownLocalPaths {
    param([object]$Config)

    $paths = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    foreach ($bucket in @("queue", "processing", "done", "failed")) {
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
    $customer = if ([string]::IsNullOrWhiteSpace($UserName)) { Get-CustomerFromPath -Path $fullLocalPath -Config $Config } else { $UserName.Trim() }
    $job = [ordered]@{
        Id = $id
        Status = "Queued"
        LocalPath = $fullLocalPath
        FtpPath = $FtpPath
        UserName = $UserName
        Customer = $customer
        ClientIp = ""
        EventName = ""
        CreatedAt = $now.ToString("o")
        UpdatedAt = $now.ToString("o")
        AttemptCount = 0
        Source = $Source
        LastError = ""
        DestinationPath = ""
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
    Add-AuditEntry -Config $Config -Job $job -Message "Upload job queued by reconciliation."
}

function Add-SourceRootJobs {
    param(
        [object]$Config,
        [System.Collections.Generic.HashSet[string]]$KnownPaths
    )

    foreach ($root in $Config.SourceRoots) {
        if (-not (Test-Path -LiteralPath ([string]$root))) {
            continue
        }

        Get-ChildItem -LiteralPath ([string]$root) -File -Recurse | ForEach-Object {
            $fullPath = [System.IO.Path]::GetFullPath($_.FullName)
            if ($KnownPaths.Contains($fullPath)) {
                return
            }

            if (-not (Test-AllowedPattern -Path $fullPath -Patterns $Config.AllowedPatterns)) {
                return
            }

            $customer = Get-CustomerFromPath -Path $fullPath -Config $Config
            New-TransferJob -Config $Config -LocalPath $fullPath -FtpPath "" -UserName $customer -Source "SourceRootScan"
            [void]$KnownPaths.Add($fullPath)
        }
    }
}

function Add-ProVideStorJobs {
    param(
        [object]$Config,
        [System.Collections.Generic.HashSet[string]]$KnownPaths
    )

    $logRoot = [string]$Config.ProVideLogRoot
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

            if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
                return
            }

            if (-not (Test-PathUnderRoot -Path $localPath -Roots $Config.SourceRoots)) {
                return
            }

            if (-not (Test-AllowedPattern -Path $localPath -Patterns $Config.AllowedPatterns)) {
                return
            }

            $userName = (($parts[3] -split " ")[0]).Trim()
            if ([string]::IsNullOrWhiteSpace($userName)) {
                $userName = Get-CustomerFromPath -Path $localPath -Config $Config
            }

            New-TransferJob -Config $Config -LocalPath $localPath -FtpPath "" -UserName $userName -Source "ProVideStorLog"
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
