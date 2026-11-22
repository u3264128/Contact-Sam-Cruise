@echo off
setlocal
set "game_dir=%~dp0"
set "game=contact-sam-cruise"
set "model=-pal"
:args
if "%~1"=="" goto run
if /i "%~1"=="--help" goto help
if /i "%~1"=="-h" goto help
if /i "%~1"=="standard" (set "game=contact-sam-cruise" & goto next)
if /i "%~1"=="stripes" (set "game=contact-sam-cruise-stripes" & goto next)
if /i "%~1"=="pal" (set "model=-pal" & goto next)
if /i "%~1"=="ntsc" (set "model=-ntsc" & goto next)
>&2 echo Unknown option. Run play.cmd --help.
exit /b 2
:next
shift /1
goto args
:run
if not exist "%game_dir%build\%game%.prg" (
  >&2 echo Missing %game%.prg. Run python tools\build.py first.
  if "%game%"=="contact-sam-cruise-stripes" >&2 echo Add --stripe-camera to build this variant.
  exit /b 1
)
if defined X64SC goto launch
if not defined VICE_ROOT (
  set "X64SC=x64sc"
  goto launch
)
if exist "%VICE_ROOT%\bin\x64sc.exe" (
  set "X64SC=%VICE_ROOT%\bin\x64sc.exe"
  goto launch
)
if exist "%VICE_ROOT%\x64sc.exe" (
  set "X64SC=%VICE_ROOT%\x64sc.exe"
  goto launch
)
>&2 echo x64sc.exe was not found under VICE_ROOT. Check VICE_ROOT or set X64SC.
exit /b 1
:launch
start "" "%X64SC%" %model% -VICIIvsync -autostartprgmode 1 -autostart "%game_dir%build\%game%.prg"
exit /b %errorlevel%
:help
echo Usage: play.cmd [standard ^| stripes] [pal ^| ntsc]
echo Set VICE_ROOT to the VICE installation directory or X64SC to the emulator path.
exit /b 0
