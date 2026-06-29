$ErrorActionPreference = "Stop"

$exePath = Join-Path $PSScriptRoot "CineViet.exe"
if (-not (Test-Path $exePath)) {
  Write-Error "Không tìm thấy CineViet.exe trong thư mục hiện tại. Hãy chạy file này trong thư mục đã giải nén app Windows."
}

$scheme = "cineviet"
$base = "HKCU:\Software\Classes\$scheme"
New-Item -Path $base -Force | Out-Null
Set-ItemProperty -Path $base -Name "(default)" -Value "URL:CineViet Protocol"
Set-ItemProperty -Path $base -Name "URL Protocol" -Value ""
New-Item -Path "$base\DefaultIcon" -Force | Out-Null
Set-ItemProperty -Path "$base\DefaultIcon" -Name "(default)" -Value "`"$exePath`",0"
New-Item -Path "$base\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$base\shell\open\command" -Name "(default)" -Value "`"$exePath`" `"%1`""

Write-Host "Đã đăng ký đăng nhập Google cho CineViet Windows."
Write-Host "Protocol: $scheme://"
Write-Host "App: $exePath"
