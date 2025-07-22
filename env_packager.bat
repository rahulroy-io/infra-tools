@echo off
setlocal enabledelayedexpansion

rem Attempt to locate micromamba.exe
set "MM="
set "MRP="

rem 1) use existing environment variables if valid
if defined MAMBA_EXE if exist "%MAMBA_EXE%" set "MM=%MAMBA_EXE%"

if defined MAMBA_ROOT_PREFIX if exist "%MAMBA_ROOT_PREFIX%" set "MRP=%MAMBA_ROOT_PREFIX%"

rem 2) search PATH for micromamba.exe
if not defined MM (
    for /f "delims=" %%F in ('where micromamba.exe 2^>nul') do (
        set "MM=%%F"
        goto :mm_found
    )
)

rem 3) parse micromamba.bat if present
if not defined MM (
    for /f "delims=" %%F in ('where micromamba.bat 2^>nul') do (
        for /f "tokens=2 delims==^\"" %%G in ('findstr /i "MAMBA_EXE" "%%F"') do if exist "%%~G" set "MM=%%~G"
        for /f "tokens=2 delims==^\"" %%H in ('findstr /i "MAMBA_ROOT_PREFIX" "%%F"') do set "MRP=%%~H"
        if defined MM goto :mm_found
    )
)

if not defined MM goto prompt_mm

:prompt_mm
set /p MM=Enter full path to micromamba.exe:
if not exist "%MM%" (
    echo File not found. Try again.
    goto prompt_mm
)
:mm_found

rem List existing environments and prompt for one
"%MM%" env list
set /p ENV_NAME=Enter environment name to package: 

rem Prompt for package cache directory
if defined MRP (
    set "DEFAULT_CACHE=%MRP%\pkgs"
) else (
    if not defined USERPROFILE set "USERPROFILE=%HOMEDRIVE%%HOMEPATH%"
    set "DEFAULT_CACHE=%USERPROFILE%\micromamba\pkgs"
)
set /p PKG_CACHE=Package cache directory [%DEFAULT_CACHE%]:
if "%PKG_CACHE%"=="" set "PKG_CACHE=%DEFAULT_CACHE%"

rem Prompt for output parent folder
set "DEFAULT_PARENT=%CD%"
set /p OUT_PARENT=Output parent folder [%DEFAULT_PARENT%]: 
if "%OUT_PARENT%"=="" set "OUT_PARENT=%DEFAULT_PARENT%"

rem Define working folder
set "WORK_DIR=%OUT_PARENT%\%ENV_NAME%"
if exist "%WORK_DIR%" (
    echo Removing existing working folder "%WORK_DIR%" ...
    rd /s /q "%WORK_DIR%"
)
mkdir "%WORK_DIR%" || goto :eof
mkdir "%WORK_DIR%\win-64"
mkdir "%WORK_DIR%\noarch"

rem Export environment to YAML
"%MM%" env export -n "%ENV_NAME%" > "%WORK_DIR%\%ENV_NAME%_env.yml"

rem Download packages to staging env
"%MM%" create -n _staging --download-only -f "%WORK_DIR%\%ENV_NAME%_env.yml" -y

rem Copy packages from cache
robocopy "%PKG_CACHE%\win-64" "%WORK_DIR%\win-64" /e >nul
robocopy "%PKG_CACHE%\noarch" "%WORK_DIR%\noarch" /e >nul

rem Remove staging environment
"%MM%" env remove -n _staging -y >nul

rem Run conda-index on each channel
for %%D in ("%WORK_DIR%\win-64" "%WORK_DIR%\noarch") do (
    conda-index "%%~fD"
)

rem Copy micromamba.exe into working folder
copy "%MM%" "%WORK_DIR%" >nul

rem Create README_offline.txt
(
    echo set "MAMBA_ROOT_PREFIX=%%CD%%\micromamba"
    echo set "CONDA_PKGS_DIRS=%%CD%%"
    echo "\.\micromamba.exe" create -n %ENV_NAME% -f %ENV_NAME%_env.yml --override-channels -c file://%%CD%% --offline -y
    echo "\.\micromamba.exe" activate %ENV_NAME% ^&^& micromamba list -n %ENV_NAME%
) > "%WORK_DIR%\README_offline.txt"

rem Zip the working folder
powershell -NoLogo -Command "Compress-Archive -Path '%WORK_DIR%\*' -DestinationPath '%OUT_PARENT%\%ENV_NAME%.zip' -Force"

rem Cleanup working folder
rd /s /q "%WORK_DIR%"

echo Packaging complete: %OUT_PARENT%\%ENV_NAME%.zip
endlocal
