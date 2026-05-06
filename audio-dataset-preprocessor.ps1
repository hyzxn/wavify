& {
    $Start_Time = Get-Date

    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        Write-Host "Error: ffmpeg cannot be found." -ForegroundColor Red
        return
    }

    $audio_format = "*.wav", "*.mp3", "*.flac", "*.ogg", "*.opus", "*.m4a", "*.mp4", "*.aac", "*.alac", "*.wma", "*.aiff", "*.webm", "*.ac3"
    $files = Get-ChildItem -Path .\* -File -Include $audio_format | Where-Object { $_.DirectoryName -notmatch "finished\d{3}" }
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
    $bar_cyan = "$e[96m"
    $bar_endansi = "$e[0m"
    $fChar = [char]0x2588
    $eChar = [char]0x2591

    $shared = [hashtable]::Synchronized(@{ Errors = [System.Collections.Concurrent.ConcurrentBag[string]]::new() })
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $limThreads)
    $pool.Open()

    $scriptBlock = {
        param($fFull, $fName, $dest, $shared)
        try {
            $p = New-Object System.Diagnostics.Process
            $p.StartInfo.FileName = "ffmpeg"
            $p.StartInfo.Arguments = "-y -nostdin -threads 1 -i `"$fFull`" -ar 48000 -acodec pcm_s16le -ac 1 `"$dest`" -loglevel error"
            $p.StartInfo.UseShellExecute = $false
            $p.StartInfo.CreateNoWindow = $true
            $p.StartInfo.RedirectStandardError = $true
            $null = $p.Start()
            
            $errTask = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit(150000)) {
                $p.Kill()
                $p.WaitForExit(5000) | Out-Null
                $shared.Errors.Add("[$fName] Timeout") | Out-Null
            }
            elseif ($p.ExitCode -ne 0) {
                $shared.Errors.Add("[$fName] FFmpeg Error: $($errTask.Result.Trim())") | Out-Null
            }
        }
        catch {
            $shared.Errors.Add("[$fName] Critical: $($_.Exception.Message)") | Out-Null
        }
        finally {
            if ($p) { $p.Dispose() }
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
        $null = $ps.AddScript($scriptBlock).AddArgument($file.FullName).AddArgument($file.Name).AddArgument($destPath).AddArgument($shared)
        $jobs.Add([PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
        $idx++
    }

    $fStr = [string]$fChar
    $eStr = [string]$eChar

    while ($true) {
        $doneCount = ($jobs | Where-Object { $_.Handle.IsCompleted }).Count
        $percent = $doneCount / $totalCount
        $padLen = [int]($percent * 30)
        $pctText = ([Math]::Round($percent * 100)).ToString().PadLeft(3)
    
        $detail_info = & $dim " ($doneCount/$totalCount)"
        $ui_msg = "`r Processing: " + $bar_cyan + ($fStr * $padLen) + $bar_endansi + ($eStr * (30 - $padLen)) + " " + $bar_cyan + $pctText + "%" + $bar_endansi + $detail_info
    
        Write-Host $ui_msg -NoNewline

        if ($doneCount -ge $totalCount) { break }
        Start-Sleep -Milliseconds 300
    }

    foreach ($j in $jobs) { $null = $j.PS.EndInvoke($j.Handle); $j.PS.Dispose() }
    $pool.Close(); $pool.Dispose()

    Write-Host "`n`n`nOutput Saved to [$folderName]" -ForegroundColor Yellow
    $Total_Time = (Get-Date) - $Start_Time
    Write-Host ("Total Processing Time: " + $(if ($Total_Time.Hours -gt 0) { "$($Total_Time.Hours)h " }) + "$($Total_Time.Minutes)m $($Total_Time.Seconds)s $($Total_Time.Milliseconds)ms") -ForegroundColor Cyan

    if ($shared.Errors.Count -gt 0) {
        Write-Host "`n[Errors: $($shared.Errors.Count)]" -ForegroundColor Red
        foreach ($err in $shared.Errors) {
            $eMsg = " - " + $err
            Write-Host $eMsg -ForegroundColor DarkRed
        }
    }
}
