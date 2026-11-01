@echo off
REM resume_build.cmd - set up the WSL2 toolchain and build kernel + menu runtime.
REM Right-click "Run as administrator", or run from an elevated cmd.
REM Logs land in <repo>\logs\build-<date>\. Nothing here touches the tablet.
setlocal
set WSL=wsl.exe -d Ubuntu -u root --

echo == WSL version
wsl.exe -l -v
if errorlevel 1 (
  echo Ubuntu is not registered - run: wsl.exe --install Ubuntu --web-download
  goto :done
)

for /f "delims=" %%p in ('wsl.exe wslpath -a "%~dp0.."') do set WSLREPO=%%p
echo == repo in WSL: %WSLREPO%

echo == fetch dependencies (linux tarball + upstream repos)
%WSL% bash "%WSLREPO%/build/fetch-deps.sh"
if errorlevel 1 goto :done

echo == setup (apt toolchain, binfmt, staged source check)
%WSL% bash "%WSLREPO%/build/wsl_setup.sh"
if errorlevel 1 goto :done

echo == kernel 7.2.6-tb710fu (Image, dtb, modules) - this takes a while
%WSL% bash "%WSLREPO%/build/wsl_build.sh" kernel

echo == kShimC menu runtime + DualBootKernelPatcher
%WSL% bash "%WSLREPO%/build/wsl_build.sh" shim

:done
echo.
echo artifacts: %~dp0..\out\  (logs in %~dp0..\logs\build-*)
pause
