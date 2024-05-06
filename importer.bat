@echo off
setlocal enabledelayedexpansion

REM get the config values from 'config.bat'
call config.bat

REM output the config variables
echo ========================================================================================================
echo  IMPORT_DIRECTORY = %IMPORT_DIRECTORY%
echo    DONE_DIRECTORY = %DONE_DIRECTORY%
echo           API_URL = %API_URL%
echo     PERSISTENT_ACCESS_TOKEN = ****!PERSISTENT_ACCESS_TOKEN:~-4!
echo      COLUMN_NAMES = %COLUMN_NAMES%
echo    ACTION_DEFAULT = %ACTION_DEFAULT%
echo ========================================================================================================

if "%PERSISTENT_ACCESS_TOKEN%"=="" (
    echo PERSISTENT_ACCESS_TOKEN is required in config file. Exiting now.
    exit /b 1
)

set EMPTY_DIR=1
for /r "%IMPORT_DIRECTORY%" %%F in (*) do (
    set EMPTY_DIR=0
    break
)

if %EMPTY_DIR%==1 (
    echo IMPORT_DIRECTORY is empty. Nothing to import. Exiting now.
    exit /b 1
)

for /f "delims=" %%i in ('curl -X POST %API_URL%/authentication-token --header "Content-Type: application/json" --data "{""persistentAccessToken"": ""%PERSISTENT_ACCESS_TOKEN%""}"') do set "SESSION_TOKEN=%%i"

REM iterate over the CSVs in the import directory and upload each to the bulk action endpoint
for %%F in ("%IMPORT_DIRECTORY%\*.csv") do (
    call upload-csv.bat "%%F" %API_URL% %COLUMN_NAMES% %SESSION_TOKEN% %ACTION_DEFAULT%

    move "%%F" "%DONE_DIRECTORY%"
    echo completed: %%F
    echo ========================================================================================================
)

curl --location %API_URL%/person/me/logout --header "X-Auth-Token: %SESSION_TOKEN%" --header "Accept: application/json" --header "Content-Type: application/json" --data "{""authenticationToken"": ""%SESSION_TOKEN%""}"
