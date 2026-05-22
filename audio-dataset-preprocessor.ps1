function Convert-AudioDataset {
    param(
        [string]$SourcePath = ".\*",
        [int]$SampleRate = 48000,
        [int]$TimeoutMs = 150000,
        [int]$BarLength = 30,
        [string[]]$AudioFormats = @("*.wav", "*.mp3", "*.flac", "*.ogg", "*.opus", "*.m4a", "*.mp4", "*.aac", "*.alac", "*.wma", "*.aiff", "*.webm", "*.ac3")
    )

    $startTime = Get-Date

    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        Write-Host "Error: ffmpeg cannot be found." -ForegroundColor Red
        return
    }

    $searchPath = if ((Test-Path $SourcePath -PathType Container)) { Join-Path $SourcePath "*" } else { $SourcePath }
    [array]$files = Get-ChildItem -Path $searchPath -File -Include $AudioFormats | Where-Object { $_.DirectoryName -notmatch "finished\d{3}" }
    $totalCount = $files.Count
    if ($totalCount -eq 0) {
        Write-Host "Error: No files found." -ForegroundColor Red
        return
    }

    $limThreads = [Math]::Max(1, [int]($env:NUMBER_OF_PROCESSORS / 2))
    $n = 1
    do { $folderName = "finished" + $n.ToString("000"); $n++ } while (Test-Path $folderName)
    $null = New-Item -ItemType Directory -Path $folderName
    $format = "0" * [Math]::Max(2, $totalCount.ToString().Length)

    Write-Host " CPU Threads Assigned: $limThreads / $env:NUMBER_OF_PROCESSORS`n" -ForegroundColor Cyan

    # ansi
    $e = [char]27
    $dim = { param($t)"$e[90m$t$e[0m" }
    $barCyan = "$e[96m"
    $barEndAnsi = "$e[0m"
    $fChar = [char]0x2588
    $eChar = [char]0x2591

    $shared = [hashtable]::Synchronized(@{ Errors = [System.Collections.Concurrent.ConcurrentBag[string]]::new() })
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $limThreads)
    $pool.Open()

    $scriptBlock = {
        param($fFull, $fName, $destPath, $sharedState, $sampleRate, $timeoutMs)
        try {
            $sourceFile = Get-Item $fFull
            if ($sourceFile.Length -lt 2000) {
                $sharedState.Errors.Add("[$fName] Skipped: Source file is too small or empty.") | Out-Null
                return
            }

            $process = Start-Process -FilePath "ffmpeg" -ArgumentList @(
                "-y", "-nostdin", "-hide_banner",
                "-analyzeduration", "100M", "-probesize", "100M",
                "-i", "`"$fFull`"", 
                "-ar", $sampleRate, 
                "-acodec", "pcm_s16le", 
                "-ac", "1", 
                "`"$destPath`"", 
                "-loglevel", "error"
            ) -NoNewWindow -PassThru -Wait

            if (Test-Path $destPath) {
                if ((Get-Item $destPath).Length -lt 1000) {
                    $sharedState.Errors.Add("[$fName] Failed: Output is corrupt (1KB). Source may be incomplete.") | Out-Null
                    Remove-Item $destPath -Force # 실패된(1KB) 파일 제거
                }
            } else {
                $sharedState.Errors.Add("[$fName] Failed: No output generated (ExitCode: $($process.ExitCode)).") | Out-Null
            }
        }
        catch {
            $sharedState.Errors.Add("[$fName] Critical: $($_.Exception.Message)") | Out-Null
        }
        finally {
            if ($process) { $process.Dispose() }
        }
    }

    $jobs = New-Object System.Collections.Generic.List[PSCustomObject]
    $idx = 1
    $currentDir = (Get-Location).Path

    foreach ($file in $files) {
        $fileName = "$($idx.ToString($format)).wav"
        $destPath = Join-Path (Join-Path $currentDir $folderName) $fileName
        
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($scriptBlock).
                    AddArgument($file.FullName).
                    AddArgument($file.Name).
                    AddArgument($destPath).
                    AddArgument($shared).
                    AddArgument($SampleRate).
                    AddArgument($TimeoutMs)
                    
        $jobs.Add([PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
        $idx++
    }

    $fStr = [string]$fChar
    $eStr = [string]$eChar

    while ($true) {
        $doneCount = $jobs.Where({ $_.Handle.IsCompleted }).Count
        $percent = $doneCount / $totalCount
        $pctText = [Math]::Round($percent * 100)

        $currentBarLen = [Math]::Min($BarLength, [int]($percent * $BarLength))
        $bar = ($fStr * $currentBarLen).PadRight($BarLength, $eStr)
        Write-Host ("`r Processing: $barCyan$bar$barEndAnsi $barCyan$pctText%$barEndAnsi " + (& $dim "($doneCount/$totalCount)")) -NoNewline

        if ($doneCount -ge $totalCount) { break }
        Start-Sleep -ms 300
    }

    foreach ($j in $jobs) { $null = $j.PS.EndInvoke($j.Handle); $j.PS.Dispose() }
    $pool.Close(); $pool.Dispose()

    Write-Host "`n`n`nOutput Saved to [$folderName]" -ForegroundColor Yellow
    
    $totalTime = (Get-Date) - $startTime
    Write-Host ("Total Processing Time: " + $(if ($totalTime.Hours -gt 0) { "$($totalTime.Hours)h " }) + "$($totalTime.Minutes)m $($totalTime.Seconds)s $($totalTime.Milliseconds)ms") -ForegroundColor Cyan

    if ($shared.Errors.Count -gt 0) {
        Write-Host "`n[Errors: $($shared.Errors.Count)]" -ForegroundColor Red
        foreach ($err in $shared.Errors) {
            $eMsg = " - " + $err
            Write-Host $eMsg -ForegroundColor DarkRed
        }
    }
}

Convert-AudioDataset -SampleRate 48000 -TimeoutMs 150000 -BarLength 30
