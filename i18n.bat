@echo off
rem ============================================================================
rem i18n.bat - Windows 启动器
rem
rem 优先级：
rem   1. WSL (Windows Subsystem for Linux)   -> 直接运行 i18n.sh
rem   2. Git Bash                             -> 直接运行 i18n.sh
rem   3. MSYS2                                -> 直接运行 i18n.sh
rem   4. Cygwin                               -> 直接运行 i18n.sh
rem   5. PowerShell (fallback)                -> 运行 i18n.ps1
rem ============================================================================

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

rem ---- 1. WSL ----------------------------------------------------------------
where wsl >nul 2>&1
if not errorlevel 1 (
    rem 将 Windows 路径转换为 WSL 路径
    for /f "delims=" %%i in ('wsl wslpath -u "%SCRIPT_DIR%\\i18n.sh" 2^>nul') do set "WSL_SCRIPT=%%i"
    if not "!WSL_SCRIPT!"=="" (
        echo [i18n] Using WSL bash
        wsl -- bash "!WSL_SCRIPT!" %*
        exit /b %errorlevel%
    )
)

rem ---- 2. Git Bash -----------------------------------------------------------
for %%B in (
    "%PROGRAMFILES%\Git\bin\bash.exe"
    "%PROGRAMFILES(X86)%\Git\bin\bash.exe"
    "%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
) do (
    if exist %%B (
        echo [i18n] Using Git Bash: %%B
        %%B "%SCRIPT_DIR%\i18n.sh" %*
        exit /b %errorlevel%
    )
)

rem ---- 3. MSYS2 --------------------------------------------------------------
for %%B in (
    "C:\msys64\usr\bin\bash.exe"
    "C:\msys32\usr\bin\bash.exe"
) do (
    if exist %%B (
        echo [i18n] Using MSYS2 bash: %%B
        %%B "%SCRIPT_DIR%\i18n.sh" %*
        exit /b %errorlevel%
    )
)

rem ---- 4. Cygwin -------------------------------------------------------------
for %%B in (
    "C:\cygwin64\bin\bash.exe"
    "C:\cygwin\bin\bash.exe"
) do (
    if exist %%B (
        echo [i18n] Using Cygwin bash: %%B
        %%B "%SCRIPT_DIR%\i18n.sh" %*
        exit /b %errorlevel%
    )
)

rem ---- 5. PowerShell fallback ------------------------------------------------
echo [i18n] No bash environment found, using PowerShell implementation

rem 将 --debug 等 bash 风格参数原样透传，i18n.ps1 内部用同名参数
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\i18n.ps1" %*
exit /b %errorlevel%
