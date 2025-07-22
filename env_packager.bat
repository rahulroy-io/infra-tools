@echo off
setlocal enabledelayedexpansion

echo Micromamba Environment Packager
echo ===============================

rem Auto-detect micromamba.exe
set "MM="
set "MRP="

rem 1) Check existing environment variables
if defined MAMBA_EXE if exist "%MAMBA_EXE%" set "MM=%MAMBA_EXE%"
if defined MAMBA_ROOT_PREFIX if exist "%MAMBA_ROOT_PREFIX%" set "MRP=%MAMBA_ROOT_PREFIX%"

rem 2) Search PATH for micromamba.exe
if not defined MM (
    for /f "delims=" %%F in ('where micromamba.exe 2^>nul') do (
        set "MM=%%F"
        goto :mm_found
    )
)

rem 3) Parse micromamba.bat if present
if not defined MM (
    for /f "delims=" %%F in ('where micromamba.bat 2^>nul') do (
        for /f "tokens=2 delims==" %%G in ('findstr /i "MAMBA_EXE" "%%F"') do (
            set "TEMP_EXE=%%G"
            set "TEMP_EXE=!TEMP_EXE:"=!"
            if exist "!TEMP_EXE!" set "MM=!TEMP_EXE!"
        )
        for /f "tokens=2 delims==" %%H in ('findstr /i "MAMBA_ROOT_PREFIX" "%%F"') do (
            set "TEMP_ROOT=%%H"
            set "MRP=!TEMP_ROOT:"=!"
        )
        if defined MM goto :mm_found
    )
)

rem 4) Prompt if not found
:prompt_mm
if not defined MM (
    set /p MM=Enter full path to micromamba.exe: 
    if not exist "%MM%" (
        echo Error: File not found. Please try again.
        goto :prompt_mm
    )
)

:mm_found
echo Using micromamba: %MM%
echo.

rem List environments and prompt for selection
echo Available environments:
"%MM%" env list
echo.
set /p ENV_NAME=Enter environment name to package: 
if "%ENV_NAME%"=="" (
    echo Error: Environment name cannot be empty.
    goto :eof
)

rem Verify environment exists
"%MM%" env list | findstr /i "%ENV_NAME%" >nul
if errorlevel 1 (
    echo Error: Environment '%ENV_NAME%' not found.
    goto :eof
)

rem Prompt for package cache directory
if defined MRP (
    set "DEFAULT_CACHE=%MRP%\pkgs"
) else (
    set "DEFAULT_CACHE=%USERPROFILE%\micromamba\pkgs"
)
set /p PKG_CACHE=Package cache directory [%DEFAULT_CACHE%]: 
if "%PKG_CACHE%"=="" set "PKG_CACHE=%DEFAULT_CACHE%"

rem Prompt for output parent folder
set "DEFAULT_PARENT=%CD%"
set /p OUT_PARENT=Output parent folder [%DEFAULT_PARENT%]: 
if "%OUT_PARENT%"=="" set "OUT_PARENT=%DEFAULT_PARENT%"

rem Create working directory structure
set "WORK_DIR=%OUT_PARENT%\%ENV_NAME%"
echo.
echo Creating working directory: %WORK_DIR%
if exist "%WORK_DIR%" (
    echo Removing existing working folder...
    rd /s /q "%WORK_DIR%" 2>nul
)
mkdir "%WORK_DIR%" 2>nul || (
    echo Error: Cannot create working directory.
    goto :eof
)
mkdir "%WORK_DIR%\win-64" 2>nul
mkdir "%WORK_DIR%\noarch" 2>nul

rem Export environment to YAML
echo Exporting environment to YAML...
"%MM%" env export -n "%ENV_NAME%" > "%WORK_DIR%\%ENV_NAME%_env.yml"
if errorlevel 1 (
    echo Error: Failed to export environment.
    rd /s /q "%WORK_DIR%"
    goto :eof
)

rem Download packages using staging environment
echo Downloading packages...
"%MM%" create -n _staging --download-only -f "%WORK_DIR%\%ENV_NAME%_env.yml" -y
if errorlevel 1 (
    echo Error: Failed to download packages.
    "%MM%" env remove -n _staging -y 2>nul
    rd /s /q "%WORK_DIR%"
    goto :eof
)

rem Copy packages from cache based on environment list
echo Copying packages from cache...
"%MM%" list -n "%ENV_NAME%" > "%TEMP%\pkg_list.txt"
for /f "skip=4 tokens=1,2,3" %%A in ("%TEMP%\pkg_list.txt") do (
    if not "%%A"=="" if not "%%A"=="--" (
        set "PKG_FILE=%%A-%%B-%%C.conda"
        if exist "%PKG_CACHE%\!PKG_FILE!" (
            echo Copying !PKG_FILE!
            if "%%C"=="%%C:py=" (
                copy "%PKG_CACHE%\!PKG_FILE!" "%WORK_DIR%\noarch\" >nul
            ) else (
                copy "%PKG_CACHE%\!PKG_FILE!" "%WORK_DIR%\win-64\" >nul
            )
        ) else (
            echo Warning: Package file !PKG_FILE! not found in cache
        )
    )
)
del "%TEMP%\pkg_list.txt" 2>nul

rem Clean up staging environment
echo Cleaning up staging environment...
"%MM%" env remove -n _staging -y >nul 2>&1

rem Generate repository metadata
echo Generating repository metadata...
for %%D in ("%WORK_DIR%\win-64" "%WORK_DIR%\noarch") do (
    conda-index "%%D" >nul 2>&1 || (
        echo Warning: conda-index failed for %%D
        echo {"info": {"subdir": "%%~nD"}, "packages": {}, "packages.conda": {}, "removed": [], "repodata_version": 1} > "%%D\repodata.json"
    )
)

rem Copy micromamba.exe for portability
echo Copying micromamba.exe...
copy "%MM%" "%WORK_DIR%\micromamba.exe" >nul

rem Generate README with offline installation instructions
echo Creating README_offline.txt...
(
    echo Offline Micromamba Environment: %ENV_NAME%
    echo ==========================================
    echo.
    echo To install this environment offline:
    echo.
    echo 1. Extract this package to your desired location
    echo 2. Open a command prompt in the extracted folder
    echo 3. Run the following commands:
    echo.
    echo    set MAMBA_ROOT_PREFIX=%%CD%%\micromamba
    echo    set CONDA_PKGS_DIRS=%%CD%%
    echo    .\micromamba.exe create -n %ENV_NAME% -f %ENV_NAME%_env.yml --override-channels -c file://%%CD%%/win-64 -c file://%%CD%%/noarch --offline -y
    echo.
    echo 4. Activate and verify the environment:
    echo    .\micromamba.exe activate %ENV_NAME%
    echo    .\micromamba.exe list -n %ENV_NAME%
    echo.
    echo Note: This package contains all necessary files for offline installation.
) > "%WORK_DIR%\README_offline.txt"

rem Create the zip package
echo Creating zip package...
powershell -NoLogo -Command "try { Compress-Archive -Path '%WORK_DIR%\*' -DestinationPath '%OUT_PARENT%\%ENV_NAME%.zip' -Force; exit 0 } catch { exit 1 }"
if errorlevel 1 (
    echo Error: Failed to create zip package.
    rd /s /q "%WORK_DIR%"
    goto :eof
)

rem Clean up working directory
echo Cleaning up...
rd /s /q "%WORK_DIR%"

echo ==========================================
echo Packaging complete!
echo Package location: %OUT_PARENT%\%ENV_NAME%.zip
echo ==========================================
