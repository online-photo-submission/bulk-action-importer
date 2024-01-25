@echo off
setlocal enabledelayedexpansion

REM get the config values from 'config.bat'
call config.bat

if "%SESSION_TOKEN%"=="" (
    echo SESSION_TOKEN is required in config file. Exiting now.
    exit /b 1
)

REM output the config variables
echo ========================================================================================================
echo  IMPORT_DIRECTORY = %IMPORT_DIRECTORY%
echo    DONE_DIRECTORY = %DONE_DIRECTORY%
echo           API_URL = %API_URL%
echo     SESSION_TOKEN = ****!SESSION_TOKEN:~-4!
echo      COLUMN_NAMES = %COLUMN_NAMES%
echo    ACTION_DEFAULT = %ACTION_DEFAULT%
echo ========================================================================================================

REM quit if the import directory is empty
set EMPTY_DIR=1
for /r "%IMPORT_DIRECTORY%" %%F in (*) do (
    set EMPTY_DIR=0
    break
)

if %EMPTY_DIR%==1 (
    echo IMPORT_DIRECTORY is empty. Nothing to import. Exiting now.
    exit /b 1
)

REM iterate over the CSVs in the import directory and upload each to the bulk action endpoint
for %%F in ("%IMPORT_DIRECTORY%\*.csv") do (
    call upload-csv.bat "%%F" %API_URL% %COLUMN_NAMES% %ACTION_DEFAULT%

    move "%%F" "%DONE_DIRECTORY%"
    echo completed: %%F
    echo ========================================================================================================
)