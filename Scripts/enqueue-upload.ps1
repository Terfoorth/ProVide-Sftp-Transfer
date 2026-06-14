param(
    [Parameter(Mandatory = $true)]
    [string]$LocalPath,

    [string]$FtpPath = "",
    [string]$UserName = "",
    [string]$ClientIp = "",
    [string]$EventName = "OnUploadEnd",
    [string]$ConfigPath = "C:\ProgramData\ProVideTransfer\transfer-config.json"
)

$ErrorActionPreference = "Stop"

function Read-TransferConfig {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }

    return [pscustomobject]@{
        StateRoot = "C:\ProgramData\ProVideTransfer"
    }
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

    $json = $Value | ConvertTo-Json -Depth 8
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $encoding)
}

function Add-AuditEntry {
    param(
        [string]$StateRoot,
        [object]$Entry
    )

    $logDir = Join-Path $StateRoot "logs"
    Ensure-Directory $logDir
    $logPath = Join-Path $logDir ("transfer-status-{0}.jsonl" -f (Get-Date -Format "yyyy-MM-dd"))
    $line = ($Entry | ConvertTo-Json -Depth 8 -Compress)
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

try {
    $config = Read-TransferConfig -Path $ConfigPath
    $stateRoot = [string]$config.StateRoot
    if ([string]::IsNullOrWhiteSpace($stateRoot)) {
        $stateRoot = "C:\ProgramData\ProVideTransfer"
    }

    $queueDir = Join-Path $stateRoot "queue"
    Ensure-Directory $queueDir
    Ensure-Directory (Join-Path $stateRoot "logs")

    $now = [DateTimeOffset]::UtcNow
    $id = [guid]::NewGuid().ToString("N")
    $fullLocalPath = [System.IO.Path]::GetFullPath($LocalPath)
    $customer = if ([string]::IsNullOrWhiteSpace($UserName)) { "Unknown" } else { $UserName.Trim() }

    $job = [ordered]@{
        Id = $id
        Status = "Queued"
        LocalPath = $fullLocalPath
        FtpPath = $FtpPath
        UserName = $UserName
        Customer = $customer
        ClientIp = $ClientIp
        EventName = $EventName
        CreatedAt = $now.ToString("o")
        UpdatedAt = $now.ToString("o")
        AttemptCount = 0
        Source = "OnUploadEnd"
        LastError = ""
        DestinationPath = ""
        ArchivePath = ""
        SourceLength = $null
        DestinationLength = $null
        SourceHash = ""
        DestinationHash = ""
    }

    $fileName = "{0}_{1}.json" -f (Get-Date -Format "yyyyMMddHHmmssfff"), $id
    $tmpPath = Join-Path $queueDir ($fileName + ".tmp")
    $jobPath = Join-Path $queueDir $fileName
    Write-JsonFile -Path $tmpPath -Value $job
    Move-Item -LiteralPath $tmpPath -Destination $jobPath

    Add-AuditEntry -StateRoot $stateRoot -Entry ([ordered]@{
        Id = $id
        Status = "Queued"
        LocalPath = $fullLocalPath
        FtpPath = $FtpPath
        UserName = $UserName
        Customer = $customer
        EventName = $EventName
        Timestamp = $now.ToString("o")
        Message = "Upload job queued from ProVide event."
    })

    exit 0
}
catch {
    try {
        $fallbackRoot = "C:\ProgramData\ProVideTransfer"
        Ensure-Directory (Join-Path $fallbackRoot "logs")
        $message = "{0} enqueue-upload failed: {1}" -f ([DateTimeOffset]::UtcNow.ToString("o")), $_.Exception.Message
        Add-Content -LiteralPath (Join-Path $fallbackRoot "logs\enqueue-errors.log") -Value $message -Encoding UTF8
    }
    catch {
    }

    exit 0
}
