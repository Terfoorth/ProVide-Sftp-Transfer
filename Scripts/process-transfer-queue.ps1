param(
    [switch]$RunOnce,
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
        [string]$Status,
        [string]$Message
    )

    $logDir = Join-Path $Config.StateRoot "logs"
    Ensure-Directory $logDir
    $logPath = Join-Path $logDir ("transfer-status-{0}.jsonl" -f (Get-Date -Format "yyyy-MM-dd"))
    $entry = [ordered]@{
        Id = $Job.Id
        Status = $Status
        LocalPath = $Job.LocalPath
        FtpPath = $Job.FtpPath
        UserName = $Job.UserName
        Customer = $Job.Customer
        DestinationPath = $Job.DestinationPath
        ArchivePath = $Job.ArchivePath
        AttemptCount = $Job.AttemptCount
        Timestamp = ([DateTimeOffset]::UtcNow.ToString("o"))
        Message = $Message
        LastError = $Job.LastError
    }
    Add-Content -LiteralPath $logPath -Value ($entry | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8
}

function Update-Job {
    param(
        [object]$Job,
        [string]$Status,
        [string]$Message = ""
    )

    $Job.Status = $Status
    $Job.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("o")
    if ($Message) {
        $Job.LastError = $Message
    }
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

function Get-StableFileInfo {
    param(
        [string]$Path,
        [int]$StabilitySeconds
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Source file not found: $Path"
    }

    $first = Get-Item -LiteralPath $Path
    Start-Sleep -Seconds $StabilitySeconds
    $second = Get-Item -LiteralPath $Path

    if ($first.Length -ne $second.Length -or $first.LastWriteTimeUtc -ne $second.LastWriteTimeUtc) {
        return $null
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
    }

    return $second
}

function Get-FileHashValue {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-UniquePath {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $Path
    }

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [System.IO.Path]::GetExtension($Path)
    $stamp = Get-Date -Format "yyyyMMddHHmmssfff"
    return Join-Path $directory ("{0}_{1}_{2}{3}" -f $name, $stamp, ([guid]::NewGuid().ToString("N").Substring(0, 8)), $extension)
}

function Resolve-Customer {
    param(
        [object]$Job,
        [object]$Config
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Job.Customer) -and [string]$Job.Customer -ne "Unknown") {
        return [string]$Job.Customer
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Job.UserName)) {
        return [string]$Job.UserName
    }

    $fullPath = [System.IO.Path]::GetFullPath([string]$Job.LocalPath)
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

function Complete-Job {
    param(
        [object]$Config,
        [string]$ProcessingPath,
        [object]$Job,
        [string]$Status,
        [string]$Message,
        [string]$Bucket
    )

    Update-Job -Job $Job -Status $Status
    $destinationDir = Join-Path $Config.StateRoot $Bucket
    Ensure-Directory $destinationDir
    $destinationPath = Join-Path $destinationDir ([System.IO.Path]::GetFileName($ProcessingPath))
    Write-JsonFile -Path $ProcessingPath -Value $Job
    Move-Item -LiteralPath $ProcessingPath -Destination $destinationPath -Force
    Add-AuditEntry -Config $Config -Job $Job -Status $Status -Message $Message
}

function Requeue-Job {
    param(
        [object]$Config,
        [string]$ProcessingPath,
        [object]$Job,
        [string]$Status,
        [string]$Message
    )

    Update-Job -Job $Job -Status $Status -Message $Message
    $queueDir = Join-Path $Config.StateRoot "queue"
    Ensure-Directory $queueDir
    $destinationPath = Join-Path $queueDir ([System.IO.Path]::GetFileName($ProcessingPath))
    Write-JsonFile -Path $ProcessingPath -Value $Job
    Move-Item -LiteralPath $ProcessingPath -Destination $destinationPath -Force
    Add-AuditEntry -Config $Config -Job $Job -Status $Status -Message $Message
}

function Invoke-TransferJob {
    param(
        [object]$Config,
        [string]$ProcessingPath,
        [object]$Job
    )

    $Job.AttemptCount = [int]$Job.AttemptCount + 1
    $Job.Customer = Resolve-Customer -Job $Job -Config $Config
    Update-Job -Job $Job -Status "Processing"
    Add-AuditEntry -Config $Config -Job $Job -Status "Processing" -Message "Transfer job started."

    if (-not (Test-PathUnderRoot -Path ([string]$Job.LocalPath) -Roots $Config.SourceRoots)) {
        Complete-Job -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Status "Ignored" -Message "Source path is outside configured SourceRoots." -Bucket "done"
        return
    }

    if (-not (Test-AllowedPattern -Path ([string]$Job.LocalPath) -Patterns $Config.AllowedPatterns)) {
        Complete-Job -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Status "Ignored" -Message "File extension does not match AllowedPatterns." -Bucket "done"
        return
    }

    $stabilitySeconds = [int]$Config.FileStabilitySeconds
    if ($stabilitySeconds -lt 1) {
        $stabilitySeconds = 5
    }

    $sourceInfo = Get-StableFileInfo -Path ([string]$Job.LocalPath) -StabilitySeconds $stabilitySeconds
    if ($null -eq $sourceInfo) {
        $Job.AttemptCount = [Math]::Max(0, [int]$Job.AttemptCount - 1)
        Requeue-Job -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Status "Waiting" -Message "Source file is still changing."
        return
    }

    $fileName = [System.IO.Path]::GetFileName([string]$Job.LocalPath)
    $destinationDir = Join-Path ([string]$Config.DestinationRoot) ([string]$Job.Customer)
    Ensure-Directory $destinationDir
    $destinationPath = Join-Path $destinationDir $fileName
    $destinationPath = Get-UniquePath -Path $destinationPath
    $partialPath = $destinationPath + ".partial"

    $sourceHash = ""
    if ([bool]$Config.EnableHashVerification) {
        $sourceHash = Get-FileHashValue -Path ([string]$Job.LocalPath)
    }

    [System.IO.File]::Copy([string]$Job.LocalPath, $partialPath, $true)
    $partialInfo = Get-Item -LiteralPath $partialPath

    if ($sourceInfo.Length -ne $partialInfo.Length) {
        throw "Copied file size mismatch. Source=$($sourceInfo.Length), Destination=$($partialInfo.Length)"
    }

    $destinationHash = ""
    if ([bool]$Config.EnableHashVerification) {
        $destinationHash = Get-FileHashValue -Path $partialPath
        if ($sourceHash -ne $destinationHash) {
            throw "Copied file hash mismatch."
        }
    }

    Move-Item -LiteralPath $partialPath -Destination $destinationPath

    $archiveDir = Join-Path (Join-Path ([string]$Config.ArchiveRoot) ([string]$Job.Customer)) (Get-Date -Format "yyyyMMdd")
    Ensure-Directory $archiveDir
    $archivePath = Get-UniquePath -Path (Join-Path $archiveDir $fileName)
    Move-Item -LiteralPath ([string]$Job.LocalPath) -Destination $archivePath

    $Job.SourceLength = $sourceInfo.Length
    $Job.DestinationLength = (Get-Item -LiteralPath $destinationPath).Length
    $Job.SourceHash = $sourceHash
    $Job.DestinationHash = $destinationHash
    $Job.DestinationPath = $destinationPath
    $Job.ArchivePath = $archivePath
    $Job.LastError = ""

    Complete-Job -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Status "Archived" -Message "File copied, verified, and source archived." -Bucket "done"
}

function Invoke-QueuePass {
    param([object]$Config)

    foreach ($name in @("queue", "processing", "done", "failed", "logs", "locks")) {
        Ensure-Directory (Join-Path $Config.StateRoot $name)
    }

    $queueDir = Join-Path $Config.StateRoot "queue"
    $processingDir = Join-Path $Config.StateRoot "processing"
    $jobs = Get-ChildItem -LiteralPath $queueDir -Filter "*.json" -File | Sort-Object LastWriteTimeUtc

    foreach ($jobFile in $jobs) {
        $processingPath = Join-Path $processingDir $jobFile.Name

        try {
            Move-Item -LiteralPath $jobFile.FullName -Destination $processingPath
        }
        catch {
            continue
        }

        $job = $null
        try {
            $job = Get-Content -Raw -LiteralPath $processingPath | ConvertFrom-Json
            Invoke-TransferJob -Config $Config -ProcessingPath $processingPath -Job $job
        }
        catch {
            if ($null -eq $job) {
                $job = [pscustomobject]@{
                    Id = [guid]::NewGuid().ToString("N")
                    Status = "Failed"
                    LocalPath = ""
                    FtpPath = ""
                    UserName = ""
                    Customer = "Unknown"
                    DestinationPath = ""
                    ArchivePath = ""
                    AttemptCount = 1
                    CreatedAt = [DateTimeOffset]::UtcNow.ToString("o")
                    UpdatedAt = [DateTimeOffset]::UtcNow.ToString("o")
                    LastError = $_.Exception.Message
                }
            }

            $maxAttempts = [int]$Config.MaxAttempts
            if ($maxAttempts -lt 1) {
                $maxAttempts = 5
            }

            if ([int]$job.AttemptCount -lt $maxAttempts) {
                Requeue-Job -Config $Config -ProcessingPath $processingPath -Job $job -Status "Retry" -Message $_.Exception.Message
            }
            else {
                Complete-Job -Config $Config -ProcessingPath $processingPath -Job $job -Status "Failed" -Message $_.Exception.Message -Bucket "failed"
            }
        }
    }
}

$config = Read-TransferConfig -Path $ConfigPath
if ([string]::IsNullOrWhiteSpace([string]$config.StateRoot)) {
    throw "StateRoot is required."
}

foreach ($name in @("queue", "processing", "done", "failed", "logs", "locks")) {
    Ensure-Directory (Join-Path $config.StateRoot $name)
}

$lockPath = Join-Path (Join-Path $config.StateRoot "locks") "process-transfer-queue.lock"
$lockStream = $null
try {
    $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
}
catch {
    exit 0
}

try {
    do {
        Invoke-QueuePass -Config $config
        if (-not $RunOnce) {
            Start-Sleep -Seconds 30
        }
    } while (-not $RunOnce)
}
finally {
    if ($lockStream) {
        $lockStream.Dispose()
    }
}
