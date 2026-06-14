$script:ScriptRoot = "C:\ProgramData\ProVideTransfer\Scripts"

Describe "ProVide transfer production behavior" {
    BeforeEach {
        $script:TestRoot = Join-Path $env:TEMP ("ProVideTransferTests-" + [guid]::NewGuid().ToString("N"))
        $script:StateRoot = Join-Path $script:TestRoot "state"
        $script:InboundRoot = Join-Path $script:TestRoot "sftp_file_upload_root"
        $script:DestinationRoot = Join-Path $script:TestRoot "target"
        $script:ArchiveRoot = Join-Path $script:TestRoot "archive"
        $script:LogRoot = Join-Path $script:TestRoot "provide-log"
        $script:ConfigPath = Join-Path $script:TestRoot "transfer-config.json"

        foreach ($path in @($script:StateRoot, $script:InboundRoot, $script:DestinationRoot, $script:ArchiveRoot, $script:LogRoot)) {
            New-Item -ItemType Directory -Force -Path $path | Out-Null
        }

        $config = [ordered]@{
            StateRoot = $script:StateRoot
            InboundRoot = $script:InboundRoot
            InboundFolderName = "in"
            OutboundFolderName = "out"
            SourceRoots = @($script:InboundRoot)
            DestinationRoot = $script:DestinationRoot
            ArchiveRoot = $script:ArchiveRoot
            AllowedPatterns = @("*.csv", "*.xls", "*.xlsx", "*.pdf")
            IgnoredPatterns = @("*.filepart", "*.partial", "*.tmp")
            RouteRules = @(
                [ordered]@{ Name = "CsvRoute"; Pattern = "*.csv"; DestinationRoot = $script:DestinationRoot; AppendCustomer = $true },
                [ordered]@{ Name = "PdfRoute"; Pattern = "*.pdf"; DestinationRoot = $script:DestinationRoot; AppendCustomer = $true }
            )
            StaleAfterMinutes = 1
            EnableHashVerification = $true
            FileStabilitySeconds = 1
            MaxAttempts = 2
            DefaultRetryDelaySeconds = 1
            ChangingRetryDelaySeconds = 1
            LockedRetryDelaySeconds = 1
            MaxLockedMinutes = 60
            ProVideLogRoot = $script:LogRoot
        }

        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($script:ConfigPath, ($config | ConvertTo-Json -Depth 10), $encoding)
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TestRoot) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
        }
    }

    It "queues and processes only files below the customer in folder" {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:InboundRoot "DE00001\in") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:InboundRoot "DE00001\out") | Out-Null
        Set-Content -LiteralPath (Join-Path $script:InboundRoot "DE00001\in\ready.csv") -Value "csv" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:InboundRoot "DE00001\out\return.csv") -Value "out" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:InboundRoot "DE00001\root.csv") -Value "root" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:InboundRoot "DE00001\in\ready.pdf.filepart") -Value "tmp" -NoNewline

        & (Join-Path $script:ScriptRoot "reconcile-transfer-state.ps1") -ConfigPath $script:ConfigPath
        @(Get-ChildItem -LiteralPath (Join-Path $script:StateRoot "queue") -Filter "*.json" -File).Count | Should Be 1

        & (Join-Path $script:ScriptRoot "process-transfer-queue.ps1") -RunOnce -ConfigPath $script:ConfigPath
        Test-Path -LiteralPath (Join-Path $script:DestinationRoot "DE00001\ready.csv") | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:InboundRoot "DE00001\in\ready.csv") | Should Be $false
        @(Get-ChildItem -LiteralPath (Join-Path $script:StateRoot "done") -Filter "*.json" -File).Count | Should Be 1
    }

    It "requeues locked files as WaitingLocked and completes after the lock is released" {
        $inDir = Join-Path $script:InboundRoot "DE00002\in"
        New-Item -ItemType Directory -Force -Path $inDir | Out-Null
        $source = Join-Path $inDir "locked.pdf"
        Set-Content -LiteralPath $source -Value "pdf" -NoNewline

        & (Join-Path $script:ScriptRoot "reconcile-transfer-state.ps1") -ConfigPath $script:ConfigPath
        $stream = [System.IO.File]::Open($source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            & (Join-Path $script:ScriptRoot "process-transfer-queue.ps1") -RunOnce -ConfigPath $script:ConfigPath
            $job = Get-ChildItem -LiteralPath (Join-Path $script:StateRoot "queue") -Filter "*.json" -File | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
            $job.Status | Should Be "WaitingLocked"
            $job.ErrorCategory | Should Be "Locked"
        }
        finally {
            $stream.Dispose()
        }

        Start-Sleep -Seconds 2
        & (Join-Path $script:ScriptRoot "process-transfer-queue.ps1") -RunOnce -ConfigPath $script:ConfigPath
        Test-Path -LiteralPath (Join-Path $script:DestinationRoot "DE00002\locked.pdf") | Should Be $true
        @(Get-ChildItem -LiteralPath (Join-Path $script:StateRoot "done") -Filter "*.json" -File).Count | Should Be 1
    }

    It "normalizes customer UAC resources and creates in/out folders" {
        $accountsRoot = Join-Path $script:TestRoot "accounts"
        New-Item -ItemType Directory -Force -Path $accountsRoot | Out-Null
        $uacPath = Join-Path $accountsRoot "acc[DE00999].uac"
        Set-Content -LiteralPath $uacPath -Value @(
            "Username=DE00999",
            "Password.e1=redacted",
            "Realname=Test",
            "/DE00999||",
            "/DE00999|$script:InboundRoot\DE00999|,AF,DF,LD,RF,WF",
            "{Files Uploaded: NODE=0"
        )

        & (Join-Path $script:ScriptRoot "sync-provide-uac-structure.ps1") -ConfigPath $script:ConfigPath -AccountsRoot $accountsRoot

        Test-Path -LiteralPath (Join-Path $script:InboundRoot "DE00999\in") | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:InboundRoot "DE00999\out") | Should Be $true
        $uac = Get-Content -LiteralPath $uacPath
        ($uac -contains "/DE00999/in|$script:InboundRoot\DE00999\in|,AF,DF,LD,RF,WF") | Should Be $true
        ($uac -contains "/DE00999/out|$script:InboundRoot\DE00999\out|,AF,DF,LD,RF,WF") | Should Be $true
    }
}
