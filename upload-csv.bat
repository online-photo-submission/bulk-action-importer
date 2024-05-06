@echo off

setlocal enabledelayedexpansion

set FILE=%1

if "%FILE%"=="" (
    echo FILE is required as the 1st arg
    exit /b 1
)

set API_URL=%2

if "%API_URL%"=="" (
    echo API_URL is required as the 2nd arg
    exit /b 1
)

set SESSION_TOKEN=%3

if "%SESSION_TOKEN%"=="" (
    echo SESSION_TOKEN is required as the 3Rd arg
    exit /b 1
)

echo Sending %FILE% to %API_URL%

set COLUMN_NAMES=%4

REM to set the column names add the following to the curl command
REM --form "columnNames=\"%COLUMN_NAMES%\""

curl -i --location "%API_URL%/bulk-action" --header "X-Auth-Token: %SESSION_TOKEN%" --form "csv=@\"%FILE%\"" --form "actionDefault=\"%ACTION_DEFAULT%\""