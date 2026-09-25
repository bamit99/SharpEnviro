@echo off
REM ===================================================================
REM  Give the shell back to Explorer (SharpEnviro recovery / revert)
REM
REM  Black screen, no taskbar, no way to start anything?
REM    1. Press Ctrl+Alt+Del  ->  Task Manager
REM       (Ctrl+Shift+Esc is served by the shell and may do nothing)
REM    2. File -> Run new task -> tick "Create this task with
REM       administrative privileges" -> cmd
REM    3. Run this script from wherever it is shared into the VM, e.g.
REM          \\vmware-host\Shared Folders\SharpE-vmtest\recover-shell.cmd
REM    4. Log off and back on (or reboot) - Explorer is the shell again.
REM ===================================================================

setlocal
set SCRIPTDIR=%~dp0

echo.
echo [1/4] Importing %SCRIPTDIR%restore-explorer.reg
reg import "%SCRIPTDIR%restore-explorer.reg"
if errorlevel 1 echo   WARNING: reg import failed - are you running as administrator?

echo.
echo [2/4] Current shell registration:
echo   HKCU Winlogon\Shell          :
reg query "HKCU\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell 2>nul | find "Shell" || echo     ^<not set^>
echo   HKLM Winlogon\Shell          :
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell 2>nul | find "Shell" || echo     ^<not set^>
echo   HKLM IniFileMapping Shell    :
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\IniFileMapping\system.ini\boot" /v Shell 2>nul | find "Shell" || echo     ^<not set^>

echo.
echo [3/4] Stopping SharpE processes (if any are still running)
for %%P in (SharpCore.exe SharpBar.exe SharpDesk.exe SharpMenu.exe SharpCenter.exe SharpConsole.exe SetShell.exe) do (
  taskkill /IM %%P /F >nul 2>&1 && echo   killed %%P
)

echo.
echo [4/4] Starting explorer.exe
start "" "%WinDir%\explorer.exe"
echo.
echo Done. If the desktop did not come back, log off and on again.
echo (Log off from Task Manager: Users tab - right-click your account - Sign off.)
endlocal
