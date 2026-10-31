@echo off
rem Build the GlideLink SoapySDR module for Windows with MSVC, against the SoapySDR and libiio of a
rem radioconda / conda-forge environment (their SoapySDR is built with MSVC, so the module must be).
rem
rem   build_win.bat [install] [conda prefix]
rem
rem   conda prefix: default %CONDA_PREFIX%, else D:\radioconda
rem   install:      copy glidelinkSupport.dll to <prefix>\Library\lib\SoapySDR\modules0.8
rem
rem Needs the Visual Studio 2022 Build Tools (C++: MSVC x64 and a Windows SDK).
setlocal
set "HERE=%~dp0"
set "DO_INSTALL="
if /i "%~1"=="install" (set "DO_INSTALL=1" & shift)
set "PREFIX=%~1"
if "%PREFIX%"=="" set "PREFIX=%CONDA_PREFIX%"
if "%PREFIX%"=="" set "PREFIX=D:\radioconda"
if not exist "%PREFIX%\Library\include\SoapySDR\Device.hpp" (
	echo SoapySDR not found in %PREFIX%
	exit /b 1
)

rem the MSVC environment: vswhere, else the usual install places
set "VCVARS="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" (
	for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VCVARS=%%i\VC\Auxiliary\Build\vcvars64.bat"
)
if not defined VCVARS if exist "D:\VSBuildTools2022\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=D:\VSBuildTools2022\VC\Auxiliary\Build\vcvars64.bat"
if not defined VCVARS set "VCVARS=%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
	echo MSVC not found: install the Visual Studio 2022 Build Tools with the C++ x64 tools and a Windows SDK
	exit /b 1
)
call "%VCVARS%" >nul

if not exist "%HERE%build-win" mkdir "%HERE%build-win"
pushd "%HERE%build-win"
cl /nologo /EHsc /O2 /MD /std:c++17 /W3 /wd4251 /D_CRT_SECURE_NO_WARNINGS /I "%PREFIX%\Library\include" ^
	"%HERE%GlideLink.cpp" /LD /Fe:glidelinkSupport.dll ^
	/link /LIBPATH:"%PREFIX%\Library\lib" SoapySDR.lib libiio.lib ws2_32.lib
if errorlevel 1 (popd & exit /b 1)
popd
echo built %HERE%build-win\glidelinkSupport.dll

if defined DO_INSTALL (
	copy /y "%HERE%build-win\glidelinkSupport.dll" "%PREFIX%\Library\lib\SoapySDR\modules0.8\" >nul || exit /b 1
	echo installed to %PREFIX%\Library\lib\SoapySDR\modules0.8
)
endlocal
