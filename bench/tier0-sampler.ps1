param([string]$Csv = "C:\Users\mrbla\agentic-setup\bench\tier0-20260624-121215.csv")
$end = (Get-Date).AddMinutes(45)
while ((Get-Date) -lt $end) {
  try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $availMb = [math]::Round($os.FreePhysicalMemory/1024,0)
    $usedMb  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory)/1024,0)
    $ovms = (Get-Process ovms -ErrorAction SilentlyContinue | Measure-Object WorkingSet64 -Sum).Sum
    $ovmsMb = if ($ovms) { [math]::Round($ovms/1MB,0) } else { 0 }
    $py = (Get-Process python,pythonw -ErrorAction SilentlyContinue | Measure-Object WorkingSet64 -Sum).Sum
    $pyMb = if ($py) { [math]::Round($py/1MB,0) } else { 0 }
    $cpu = [math]::Round((Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime,0)
    $ts = Get-Date -Format "HH:mm:ss"
    "$ts,$availMb,$usedMb,$ovmsMb,$pyMb,$cpu" | Out-File $Csv -Append -Encoding ascii
  } catch {}
  Start-Sleep -Seconds 5
}
