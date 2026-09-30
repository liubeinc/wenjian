@echo off
rem ---------------------------------------------------------------------------
rem  Launcher for the local converter service.
rem
rem  IMPORTANT: keep this file PURE ASCII.
rem  cmd.exe re-reads a batch file by byte offset, and after `chcp 65001` it
rem  desyncs on multibyte characters, splitting lines in half and running
rem  garbage as commands. A batch file containing Chinese breaks itself the
rem  moment it changes the code page -- regardless of how it was saved.
rem  All Chinese text therefore lives in the .js, which prints UTF-8 to the
rem  65001 console just fine.
rem ---------------------------------------------------------------------------
chcp 65001 >nul
title File Converter - Local Service
cd /d "%~dp0"

rem Find a node to run the service. Two places, in order:
rem   1) node.exe sitting next to this file -- makes the whole folder
rem      self-contained, so it can be copied to another machine as-is
rem   2) ..\.tmp\node\node.exe               -- the portable node in .cowork
rem Keep this file PURE ASCII (see the note at the top).
set "NODE="
if exist "%~dp0node.exe" set "NODE=%~dp0node.exe"
if not defined NODE if exist "%~dp0..\.tmp\node\node.exe" set "NODE=%~dp0..\.tmp\node\node.exe"
if not defined NODE (
  echo.
  echo   [ERROR] No node.exe found. Looked in:
  echo           1^) %~dp0node.exe
  echo           2^) %~dp0..\.tmp\node\node.exe
  echo.
  echo   To make this folder self-contained, copy node.exe next to this file.
  echo.
  pause
  exit /b 1
)

rem Locate the service script by wildcard instead of hardcoding its name,
rem so this file can stay ASCII-only.
rem
rem The extension is .cjs, not .js, on purpose: Windows associates .js with
rem Windows Script Host, so double-clicking the service file would run it
rem under JScript and pop a scary "syntax error 800A03EA" dialog. Nothing
rem associates .cjs, so the worst case is a harmless "how do you want to
rem open this" prompt.
set "SVC="
for %%F in ("%~dp0*.cjs") do set "SVC=%%F"
if not defined SVC (
  echo.
  echo   [ERROR] No .cjs service script found in this folder.
  echo.
  pause
  exit /b 1
)

"%NODE%" "%SVC%"

echo.
echo   Service stopped.
pause
