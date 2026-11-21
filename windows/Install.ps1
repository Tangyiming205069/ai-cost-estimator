$ErrorActionPreference = 'Stop'
$source = Split-Path $PSScriptRoot -Parent
$destination = Join-Path $env:LOCALAPPDATA 'Programs\AI Cost Estimator'
& py -3.14 -c 'import tkinter; from compression import zstd'
if ($LASTEXITCODE -ne 0) { throw 'Install Python 3.14 from python.org, including Tcl/Tk and the Python launcher.' }
if (Test-Path $destination) { throw 'Destination exists. Quit the existing tool and choose how to update it; nothing was overwritten.' }
New-Item -ItemType Directory -Path $destination | Out-Null
Copy-Item (Join-Path $source 'LMCost') $destination -Recurse
Copy-Item $PSScriptRoot $destination -Recurse
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'AI Cost Estimator.lnk'))
$link.TargetPath = Join-Path $destination 'windows\Launch.cmd'
$link.WorkingDirectory = $destination
$link.Save()
Start-Process $link.TargetPath
Write-Output "Installed in $destination. Collection is off until you connect in the tool."
