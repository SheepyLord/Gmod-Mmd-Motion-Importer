param(
    [string]$Python = "python",
    [string]$Name = "GmodMMDMotionImporter",
    [switch]$UseUPX,
    [switch]$NoBundledFFmpeg
)
# Motions are baked in-process by tools\vmd_baker.py (NumPy), so neither
# Blender nor mmd_tools is bundled.

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$OriginalPath = $env:PATH
Push-Location $Root
try {
    # Qt6Core links against the Windows system ICU (icuuc.dll). PyInstaller
    # resolves DLL dependencies through PATH, so another tool's icuuc.dll on
    # PATH (poppler builds, SDKs) gets bundled in its place and the EXE dies at
    # startup with "DLL load failed while importing QtCore". Freeze without
    # those folders.
    $SystemRoot = [Environment]::GetFolderPath("Windows")
    $KeptPath = @()
    foreach ($Dir in ($OriginalPath -split ";")) {
        if (-not $Dir) { continue }
        $HasIcu = $false
        try { $HasIcu = Test-Path (Join-Path $Dir "icuuc*.dll") } catch { }
        if ($HasIcu -and -not $Dir.StartsWith($SystemRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "Ignoring PATH folder with its own ICU while freezing: $Dir"
            continue
        }
        $KeptPath += $Dir
    }
    $env:PATH = $KeptPath -join ";"

    $IconPath = Join-Path $Root "tools\assets\importer_icon.ico"
    $PythonPrefix = (& $Python -c "import sys; print(sys.prefix)")
    if ($LASTEXITCODE -ne 0) {
        throw "Could not resolve Python prefix"
    }
    $LibraryBin = Join-Path $PythonPrefix "Library\bin"
    $PythonDlls = Join-Path $PythonPrefix "DLLs"
    $ExtraArgs = @()
    function Add-BinaryIfExists([string]$Path, [string]$Dest = ".") {
        if (Test-Path $Path) {
            $script:ExtraArgs += @("--add-binary", "$Path;$Dest")
            return $true
        }
        return $false
    }

    if (Test-Path $LibraryBin) {
        $ExtraArgs += @("--paths", $LibraryBin)
        foreach ($Dll in @(
            "ffi-8.dll",
            "libffi-8.dll",
            "libssl-3-x64.dll",
            "libcrypto-3-x64.dll",
            "libexpat.dll",
            "liblzma.dll",
            "libbz2.dll",
            "zlib.dll",
            "sqlite3.dll"
        )) {
            [void](Add-BinaryIfExists (Join-Path $LibraryBin $Dll))
        }
    }
    if (Test-Path $PythonDlls) {
        $ExtraArgs += @("--paths", $PythonDlls)
    }
    foreach ($Dll in @("zlib.dll")) {
        [void](Add-BinaryIfExists (Join-Path $PythonPrefix $Dll))
    }
    if (-not $NoBundledFFmpeg) {
        $FfmpegPath = (& $Python -c "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())")
        if ($LASTEXITCODE -eq 0 -and (Test-Path $FfmpegPath)) {
            $ExtraArgs += @("--add-binary", "$FfmpegPath;imageio_ffmpeg\binaries")
        }
    }

    & $Python -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('PyInstaller') else 1)" > $null
    if ($LASTEXITCODE -ne 0) {
        throw "PyInstaller is not installed. Run: $Python -m pip install pyinstaller"
    }

    $OutputExe = Join-Path $Root "dist\$Name.exe"
    if (Test-Path $OutputExe) {
        try {
            Remove-Item -LiteralPath $OutputExe -Force
        }
        catch {
            throw "Could not replace dist\$Name.exe. Close any running importer window using this EXE, then build again. $($_.Exception.Message)"
        }
    }

    $OptimizedImports = @(
        "--hidden-import", "ctypes",
        "--hidden-import", "_ctypes",
        "--hidden-import", "numpy",
        "--hidden-import", "vmd_baker",
        "--hidden-import", "OpenGL.GL",
        "--hidden-import", "OpenGL.arrays.numpymodule",
        "--hidden-import", "OpenGL.platform.win32",
        "--hidden-import", "PySide6.QtCore",
        "--hidden-import", "PySide6.QtGui",
        "--hidden-import", "PySide6.QtWidgets",
        "--hidden-import", "PySide6.QtMultimedia",
        "--hidden-import", "PySide6.QtOpenGLWidgets"
    )
    if (-not $NoBundledFFmpeg) {
        $OptimizedImports += @(
            "--hidden-import", "imageio_ffmpeg",
            "--copy-metadata", "imageio_ffmpeg"
        )
    }

    $ExcludedModules = @(
        "IPython",
        "OpenGL_accelerate",
        "OpenGL.GLE",
        "OpenGL.GLUT",
        "OpenGL.Tk",
        "PIL",
        "PyQt5",
        "PyQt6",
        "PySide2",
        "matplotlib",
        "pandas",
        "pytest",
        "scipy",
        "setuptools",
        "tkinter",
        "torch",
        "unittest",
        "cv2",
        "PySide6.Qt3DAnimation",
        "PySide6.Qt3DCore",
        "PySide6.Qt3DExtras",
        "PySide6.Qt3DInput",
        "PySide6.Qt3DLogic",
        "PySide6.Qt3DRender",
        "PySide6.QtBluetooth",
        "PySide6.QtCharts",
        "PySide6.QtDataVisualization",
        "PySide6.QtDesigner",
        "PySide6.QtHelp",
        "PySide6.QtLocation",
        "PySide6.QtNetworkAuth",
        "PySide6.QtPdf",
        "PySide6.QtPdfWidgets",
        "PySide6.QtPositioning",
        "PySide6.QtPrintSupport",
        "PySide6.QtQml",
        "PySide6.QtQuick",
        "PySide6.QtQuick3D",
        "PySide6.QtQuickControls2",
        "PySide6.QtQuickWidgets",
        "PySide6.QtRemoteObjects",
        "PySide6.QtScxml",
        "PySide6.QtSensors",
        "PySide6.QtSerialPort",
        "PySide6.QtSql",
        "PySide6.QtSvg",
        "PySide6.QtTest",
        "PySide6.QtTextToSpeech",
        "PySide6.QtWebChannel",
        "PySide6.QtWebEngineCore",
        "PySide6.QtWebEngineQuick",
        "PySide6.QtWebEngineWidgets",
        "PySide6.QtWebSockets",
        "PySide6.QtXml"
    )
    foreach ($Module in $ExcludedModules) {
        $ExtraArgs += @("--exclude-module", $Module)
    }
    if ($NoBundledFFmpeg) {
        $ExtraArgs += @("--exclude-module", "imageio_ffmpeg")
    }
    if (-not $UseUPX) {
        $ExtraArgs += @("--noupx")
    }

    # PyInstaller warns, and future versions may block, when launched from an elevated token.
    # This build script intentionally supports admin terminals, so bypass only that guard.
    $RunPyInstaller = "import sys; import PyInstaller.__main__ as pyi; pyi.check_unsafe_privileges = lambda: None; pyi.run(sys.argv[1:])"
    & $Python -c $RunPyInstaller `
        --noconfirm `
        --clean `
        --onefile `
        --windowed `
        --name $Name `
        --icon "$IconPath" `
        @OptimizedImports `
        --add-data "mmd_vmd_npc;mmd_vmd_npc" `
        --add-data "source_models\mmd_model;source_models\mmd_model" `
        --add-data "source_models\bone_mmd_to_source.py;source_models" `
        --add-data "source_models\flex_mmd_to_source.py;source_models" `
        --add-data "source_models\mmd_model_source_format\Body.smd;source_models\mmd_model_source_format" `
        --add-data "tools\assets;tools\assets" `
        --add-data "tools\i18n;tools\i18n" `
        --add-data "tools\preview;tools\preview" `
        --add-data "tools\import_vmd.py;tools" `
        --add-data "tools\vmd_baker.py;tools" `
        @ExtraArgs `
        "tools\mmd_vmd_importer_gui.py"

    if ($LASTEXITCODE -ne 0) {
        throw "PyInstaller build failed"
    }

    if (Test-Path $OutputExe) {
        $SizeMb = [math]::Round((Get-Item $OutputExe).Length / 1MB, 1)
        Write-Host "Built dist\$Name.exe ($SizeMb MB)"
        Write-Host "Size optimization: targeted Qt/OpenGL/imageio imports are used instead of --collect-all package bundling."
        if ($NoBundledFFmpeg) {
            Write-Host "FFmpeg was not bundled; music/video conversion requires ffmpeg on PATH."
        }
    }
    else {
        Write-Host "Built dist\$Name.exe"
    }
}
finally {
    $env:PATH = $OriginalPath
    Pop-Location
}
