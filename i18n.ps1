#Requires -Version 5.1
<#
.SYNOPSIS
    多语言字符串提取工具 - Windows PowerShell 版（等同于 i18n.sh）

.DESCRIPTION
    当系统无 WSL / Git Bash / MSYS2 时由 i18n.bat 调用。
    支持与 i18n.sh 相同的全部选项（--export / --import / --debug）。
    编译器检测顺序：compile_commands.json 中指定 -> cl.exe -> gcc.exe -> clang.exe

.EXAMPLE
    powershell -File i18n\i18n.ps1 p2p_server
    powershell -File i18n\i18n.ps1 p2p_ping --debug
    powershell -File i18n\i18n.ps1 p2p_server --import cn
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# 参数解析（手动解析以兼容 --style 参数，与 bash 版保持一致）
# ============================================================================

$SourceDir    = ""
$ExportMode   = $false
$ImportSuffix = ""
$DebugMode    = $false

$i = 0
while ($i -lt $args.Count) {
    $a = $args[$i]
    switch ($a) {
        "--export"  { $ExportMode = $true }
        "--import"  { $i++; $ImportSuffix = $args[$i] }
        "--debug"   { $DebugMode = $true }
        default {
            if ($SourceDir -eq "") { $SourceDir = $a }
            else { Write-Error "Unknown option: $a"; exit 1 }
        }
    }
    $i++
}

if ($SourceDir -eq "") {
    Write-Host "Usage: i18n.ps1 <source_dir> [--export] [--import SUFFIX] [--debug]"
    Write-Host "Example: i18n.ps1 p2p_ping"
    Write-Host "Options:"
    Write-Host "  --export          Export lang.en template file for translations"
    Write-Host "  --import SUFFIX   Generate LANG.SUFFIX.h with embedded language table"
    Write-Host "  --debug           Keep temp files in .\i18n\debug\ for inspection"
    exit 1
}

# ============================================================================
# 路径初始化
# ============================================================================

$WorkDir   = (Get-Location).Path                          # 项目根目录（调用时的 cwd）
$ScriptDir = $PSScriptRoot                                # i18n/ 目录
$SourceDir = $SourceDir.TrimEnd('\', '/')
$OutputH   = Join-Path $SourceDir ".LANG.h"
$OutputC   = Join-Path $SourceDir ".LANG.c"
$UserLangH = Join-Path $SourceDir "LANG.h"

if (-not (Test-Path $SourceDir -PathType Container)) {
    Write-Error "Error: Directory not found: $SourceDir"
    exit 1
}

# ============================================================================
# 模板 LANG.h（首次运行时生成）
# ============================================================================

if (-not (Test-Path $UserLangH)) {
    Write-Host "Creating template LANG.h in $SourceDir..."
    $template = @'
#ifndef LANG_H_
#define LANG_H_

#include <i18n.h>

typedef enum {
    /* 预定义字符串 ID */
    PRED_NUM,
};

#define LA_PREDEFINED (PRED_NUM - 1)
#include ".LANG.h"

static inline void lang_init(void) {
    lang_def(lang_en, sizeof(lang_en) / sizeof(lang_en[0]), LA_FMT_START);
}

#endif /* LANG_H_ */
'@
    [System.IO.File]::WriteAllText($UserLangH, $template, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  Created: $UserLangH"
}

# ============================================================================
# 临时文件
# ============================================================================

Write-Host "=== Language String Extractor ==="
Write-Host "Source: $SourceDir"
Write-Host ""

if ($DebugMode) {
    $DebugDir  = Join-Path $ScriptDir "debug"
    New-Item -ItemType Directory -Force -Path $DebugDir | Out-Null
    $TempAll     = Join-Path $DebugDir "all.txt"
    $TempWords   = Join-Path $DebugDir "words.txt"
    $TempFormats = Join-Path $DebugDir "formats.txt"
    $TempStrings = Join-Path $DebugDir "strings.txt"
    $TempMap     = Join-Path $DebugDir "map.txt"
    Write-Host "Debug mode: temp files saved to $DebugDir\"
} else {
    $TempAll     = [System.IO.Path]::GetTempFileName()
    $TempWords   = [System.IO.Path]::GetTempFileName()
    $TempFormats = [System.IO.Path]::GetTempFileName()
    $TempStrings = [System.IO.Path]::GetTempFileName()
    $TempMap     = [System.IO.Path]::GetTempFileName()
}

# 临时 marker 头文件路径（脚本结束时显式清理）
$TempMarkerH = [System.IO.Path]::GetTempFileName() + ".h"

# ============================================================================
# 搜索 compile_commands.json
# ============================================================================

$CompDb = ""
foreach ($bd in @("build_cmake","cmake-build-debug","cmake-build-release","build",".")) {
    $candidate = Join-Path $WorkDir "$bd\compile_commands.json"
    if (Test-Path $candidate) {
        $CompDb = $candidate
        break
    }
}

# 找不到时，若有 CMakeLists.txt 则自动 cmake configure
if ($CompDb -eq "" -and (Test-Path (Join-Path $WorkDir "CMakeLists.txt"))) {
    Write-Host "compile_commands.json not found. Running cmake configure..."
    $cmakeOut = Join-Path $WorkDir "build_cmake"
    $null = & cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -B $cmakeOut -S $WorkDir 2>&1
    $candidate = Join-Path $cmakeOut "compile_commands.json"
    if (Test-Path $candidate) {
        $CompDb = $candidate
        Write-Host "Generated: $CompDb"
    } else {
        Write-Host "Warning: cmake configure failed, falling back to compile_flags.txt"
    }
}

# 找不到时，若有 Makefile 且 bear 可用
if ($CompDb -eq "" -and (Test-Path (Join-Path $WorkDir "Makefile"))) {
    $bearCmd = Get-Command "bear" -ErrorAction SilentlyContinue
    if (-not $bearCmd) {
        Write-Host "Makefile detected but 'bear' is not installed."
        Write-Host "bear is needed to extract per-file compile flags for Makefile projects."
        Write-Host "On Windows, install via MSYS2: pacman -S bear"
        Write-Host "Or use WSL/Git Bash to run i18n.sh directly."
    } else {
        Write-Host "compile_commands.json not found. Running bear to intercept Makefile..."
        $bearOut = Join-Path $WorkDir "compile_commands.json"
        $bearVer = (& bear --version 2>&1) -join ""
        if ($bearVer -match '^bear [3-9]') {
            & bear --output $bearOut -- make -n 2>&1 | Out-Null
        } else {
            & bear -o $bearOut make -n 2>&1 | Out-Null
        }
        if ((Test-Path $bearOut) -and (Get-Item $bearOut).Length -gt 0) {
            $CompDb = $bearOut
            Write-Host "Generated: $CompDb"
        } else {
            Remove-Item $bearOut -ErrorAction SilentlyContinue
            Write-Host "Warning: bear failed, falling back to compile_flags.txt"
        }
    }
}

if ($CompDb -ne "") {
    Write-Host "Using compile_commands.json: $CompDb"
} else {
    Write-Host "Note: compile_commands.json not found, falling back to compile_flags.txt (may be incomplete)"
}

# ============================================================================
# 编译器检测
# ============================================================================

function Find-DefaultCompiler {
    # cl.exe (MSVC)
    if (Get-Command "cl.exe" -ErrorAction SilentlyContinue) {
        return @{ Cmd = "cl.exe"; Type = "msvc" }
    }
    # GCC (MinGW / MSYS2)
    foreach ($g in @("gcc", "gcc.exe")) {
        if (Get-Command $g -ErrorAction SilentlyContinue) {
            return @{ Cmd = $g; Type = "gcc" }
        }
    }
    # Clang
    foreach ($c in @("clang", "clang.exe")) {
        if (Get-Command $c -ErrorAction SilentlyContinue) {
            return @{ Cmd = $c; Type = "clang" }
        }
    }
    # cc (Cygwin / fallback)
    if (Get-Command "cc" -ErrorAction SilentlyContinue) {
        return @{ Cmd = "cc"; Type = "gcc" }
    }
    return $null
}

$DefaultCompiler = Find-DefaultCompiler
if ($null -eq $DefaultCompiler) {
    Write-Error "Error: No C compiler found (cl.exe / gcc / clang). Install one and retry."
    exit 1
}

# ============================================================================
# 从 compile_commands.json 提取某文件的编译器 + flags
# ============================================================================

# 加载一次 JSON（避免每个文件都重新解析）
$CompDbData = $null
if ($CompDb -ne "") {
    try {
        $CompDbData = Get-Content $CompDb -Raw | ConvertFrom-Json
    } catch {
        Write-Host "Warning: Failed to parse compile_commands.json: $_"
    }
}

function Get-CompilerFlagsForFile {
    param([string]$FilePath)

    $absPath = [System.IO.Path]::GetFullPath($FilePath)

    if ($null -ne $CompDbData) {
        foreach ($entry in $CompDbData) {
            $entryFile = [System.IO.Path]::GetFullPath($entry.file)
            # 路径匹配：精确匹配或互为后缀
            $match = ($entryFile -eq $absPath) -or
                     ($absPath.EndsWith($entryFile, [System.StringComparison]::OrdinalIgnoreCase)) -or
                     ($entryFile.EndsWith($absPath, [System.StringComparison]::OrdinalIgnoreCase))
            if (-not $match) { continue }

            # 解析命令：优先 arguments 数组，否则拆分 command 字符串
            if ($entry.PSObject.Properties['arguments']) {
                $parts = $entry.arguments
            } else {
                $parts = $entry.command -split '\s+' | Where-Object { $_ -ne '' }
            }

            $compiler = $parts[0]
            # 判断编译器类型
            $ctype = if ($compiler -match 'cl\.exe$|^cl$') { "msvc" } else { "gcc" }

            $flags = [System.Collections.Generic.List[string]]::new()
            $skip = $false
            for ($j = 1; $j -lt $parts.Count; $j++) {
                $p = $parts[$j]
                if ($skip) { $skip = $false; continue }
                # 跳过输出相关 flags
                if ($p -in @("-c", "-MF", "-MT", "-MQ", "-MMD", "-MD", "/c")) { continue }
                if ($p -in @("-o", "/Fo")) { $skip = $true; continue }
                if ($p -match '^/Fo') { continue }           # MSVC /Fofoo.obj
                if ($p -match '^/Fe') { continue }           # MSVC /Fefoo.exe
                if ($p -match '\.(c|cpp|cc|cxx)$') { continue }
                $flags.Add($p)
            }
            return @{ Cmd = $compiler; Flags = $flags.ToArray(); Type = $ctype }
        }
    }

    # 兜底：默认编译器 + compile_flags.txt
    $flagStr = @()
    foreach ($cfpath in @("compile_flags.txt", (Join-Path $SourceDir "..\compile_flags.txt"))) {
        if (Test-Path $cfpath) {
            $flagStr = (Get-Content $cfpath | Where-Object { $_ -notmatch '^\s*#' -and $_ -ne '' })
            break
        }
    }
    return @{ Cmd = $DefaultCompiler.Cmd; Flags = $flagStr; Type = $DefaultCompiler.Type }
}

# ============================================================================
# 生成 marker 头文件
# ============================================================================

$markerContent = @'
#ifndef LA_W
#define LA_W(WD, ID) _I18NW_ WD _I18NW_END_
#endif
#ifndef LA_S
#define LA_S(STR, ID) _I18NS_ STR _I18NS_END_
#endif
#ifndef LA_F
#define LA_F(FMT, ...) _I18NF_ FMT _I18NF_END_
#endif
'@
[System.IO.File]::WriteAllText($TempMarkerH, $markerContent, [System.Text.UTF8Encoding]::new($false))

# ============================================================================
# 运行预处理器，返回展开后文本
# ============================================================================

function Invoke-Preprocessor {
    param([string]$File, [hashtable]$CI, [bool]$IsHeader)

    $tempWrapper = $null
    try {
        if ($CI.Type -eq "msvc") {
            # MSVC: cl.exe /nologo /EP /FI"marker.h" [flags] source
            # /EP  = 预处理到 stdout，不附加 #line 指令
            # /FI  = 强制 include（等价于 -include）
            # .h 文件：用临时 .c 包装后预处理
            $srcFile = $File
            if ($IsHeader) {
                $tempWrapper = [System.IO.Path]::GetTempFileName() + ".c"
                $escaped = $File.Replace('\', '/')
                [System.IO.File]::WriteAllText($tempWrapper, "#include `"$escaped`"`n")
                $srcFile = $tempWrapper
            }
            $result = & $CI.Cmd /nologo /EP "/FI$TempMarkerH" @($CI.Flags) $srcFile 2>&1
            # cl.exe 错误会混在 stdout，过滤掉非代码行（以文件名开头的诊断行）
            $codeLines = $result | Where-Object { $_ -notmatch '^\s*$' -and $_ -notmatch '^[A-Za-z].*\(\d+\)\s*:' }
            return $codeLines -join "`n"
        } else {
            # GCC / Clang: -E -P -include marker.h [-x c] flags source
            $extraArgs = @()
            if ($IsHeader) { $extraArgs = @("-x", "c") }
            $result = & $CI.Cmd -E -P -include $TempMarkerH @($extraArgs) @($CI.Flags) $File 2>&1
            # 过滤 stderr 诊断，只保留预处理输出
            $codeLines = $result | Where-Object { $_ -is [string] }
            return $codeLines -join "`n"
        }
    } finally {
        if ($tempWrapper) { Remove-Item $tempWrapper -ErrorAction SilentlyContinue }
    }
}

# ============================================================================
# 从预处理输出中提取字符串（等价于 awk 提取逻辑）
# ============================================================================

function Extract-Strings {
    param([string]$Content, [string]$Base)

    $results = [System.Collections.Generic.List[string]]::new()
    $pos = 0
    $len = $Content.Length

    while ($pos -lt $len) {
        # 查找下一个 marker：_I18NW_ / _I18NS_ / _I18NF_
        $rest = $Content.Substring($pos)
        $m = [regex]::Match($rest, '_I18N([WSF])_')
        if (-not $m.Success) { break }

        $tp   = $m.Groups[1].Value        # W, S, or F
        $pos  = $pos + $m.Index + $m.Length

        # 查找对应结束 marker
        $endPat = "_I18N${tp}_END_"
        $endIdx = $Content.IndexOf($endPat, $pos)
        if ($endIdx -lt 0) { $pos++; continue }

        $fragment = $Content.Substring($pos, $endIdx - $pos)
        $pos      = $endIdx + $endPat.Length

        # 提取并拼接 fragment 中所有字符串字面量
        # 支持：普通 "..." / L"..." / u"..." / U"..." / u8"..."
        $sb   = [System.Text.StringBuilder]::new()
        $fpos = 0
        $flen = $fragment.Length

        while ($fpos -lt $flen) {
            $c1 = $fragment[$fpos]

            # 跳过字符串前缀 L / u / U / u8
            if ($c1 -in [char]'L', [char]'u', [char]'U') {
                if (($fpos + 1) -lt $flen) {
                    $nxt = $fragment[$fpos + 1]
                    if ($nxt -eq [char]'"') {
                        $fpos++; $c1 = [char]'"'
                    } elseif ($c1 -eq [char]'u' -and $nxt -eq [char]'8' `
                              -and ($fpos + 2) -lt $flen -and $fragment[$fpos + 2] -eq [char]'"') {
                        $fpos += 2; $c1 = [char]'"'
                    }
                }
            }

            if ($c1 -eq [char]'"') {
                $fpos++
                while ($fpos -lt $flen) {
                    $c2 = $fragment[$fpos]
                    if ($c2 -eq [char]'\') {
                        [void]$sb.Append($fragment[$fpos])
                        [void]$sb.Append($fragment[$fpos + 1])
                        $fpos += 2
                    } elseif ($c2 -eq [char]'"') {
                        $fpos++; break
                    } else {
                        [void]$sb.Append($c2)
                        $fpos++
                    }
                }
            } else {
                $fpos++
            }
        }

        $str = $sb.ToString()
        if ($str -ne '') {
            switch ($tp) {
                'W' {
                    $key = $str.Trim().ToLower()
                    $results.Add("W|$key|$str|$Base")
                }
                'S' {
                    $key = $str.ToLower()
                    $results.Add("S|$key|$str|$Base")
                }
                'F' {
                    $results.Add("F|$str|$str|$Base")
                }
            }
        }
    }
    return $results
}

# ============================================================================
# 扫描所有 .c / .h 文件，执行预处理并提取字符串
# ============================================================================

$allResults = [System.Collections.Generic.List[string]]::new()

$excludeNames = @('.LANG.h', '.LANG.c', 'LANG.h')

Get-ChildItem -Path $SourceDir -Recurse -File -Include @("*.c","*.h") |
    Where-Object {
        $n = $_.Name
        # 排除生成文件
        $n -notin $excludeNames -and $n -notmatch '^LANG\..+\.h$'
    } | ForEach-Object {
        $file = $_.FullName
        $base = $_.Name
        $isHeader = $_.Extension -eq ".h"

        $ci = Get-CompilerFlagsForFile -FilePath $file

        try {
            $preprocessed = Invoke-Preprocessor -File $file -CI $ci -IsHeader $isHeader
            $extracted = Extract-Strings -Content $preprocessed -Base $base
            foreach ($r in $extracted) { $allResults.Add($r) }
        } catch {
            Write-Warning "Warning: preprocessing failed for ${base}: $_"
        }
    }

[System.IO.File]::WriteAllLines($TempAll, $allResults, [System.Text.UTF8Encoding]::new($false))

# ============================================================================
# 分类、去重、排序辅助函数
# ============================================================================

function Aggregate-Entries {
    param([string[]]$Lines)
    # 去重（保留第一次出现），合并文件名列表，按 key 排序
    $seen   = [ordered]@{}
    $strs   = @{}
    $files  = @{}

    foreach ($line in $Lines) {
        $parts = $line -split '\|', 4
        if ($parts.Count -lt 4) { continue }
        $key  = $parts[1]
        $str  = $parts[2]
        $file = $parts[3]
        if ($seen.Contains($key)) {
            if ($files[$key] -notmatch [regex]::Escape($file)) {
                $files[$key] += ",$file"
            }
        } else {
            $seen[$key] = $true
            $strs[$key]  = $str
            $files[$key] = $file
        }
    }
    # 按 key 字母序排序后输出
    return $seen.Keys | Sort-Object | ForEach-Object {
        $k = $_
        "${Type}|$k|$($strs[$k])|$($files[$k])"
    }
}

# 实际分型聚合（type 前缀需要保留）
function Aggregate-ByType {
    param([string[]]$Lines, [string]$Type)
    $filtered = $Lines | Where-Object { $_.StartsWith("${Type}|") }
    if (-not $filtered) { return @() }

    $seen  = [ordered]@{}
    $strs  = @{}
    $files = @{}
    foreach ($line in $filtered) {
        $parts = $line -split '\|', 4
        $key  = $parts[1]
        $str  = $parts[2]
        $file = $parts[3]
        if ($seen.Contains($key)) {
            if ($files[$key].IndexOf($file) -lt 0) {
                $files[$key] += ",$file"
            }
        } else {
            $seen[$key]  = $true
            $strs[$key]  = $str
            $files[$key] = $file
        }
    }
    return $seen.Keys | Sort-Object | ForEach-Object {
        $k = $_
        "${Type}|$k|$($strs[$k])|$($files[$k])"
    }
}

# ============================================================================
# 分类聚合
# ============================================================================

$allLines    = [System.IO.File]::ReadAllLines($TempAll)
$wordLines   = @(Aggregate-ByType -Lines $allLines -Type "W")
$stringLines = @(Aggregate-ByType -Lines $allLines -Type "S")
$formatLines = @(Aggregate-ByType -Lines $allLines -Type "F")

[System.IO.File]::WriteAllLines($TempWords,   $wordLines,   [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllLines($TempStrings, $stringLines, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllLines($TempFormats, $formatLines, [System.Text.UTF8Encoding]::new($false))

$wordCount   = $wordLines.Count
$stringCount = $stringLines.Count
$formatCount = $formatLines.Count
$total       = $wordCount + $stringCount + $formatCount

Write-Host "Words (LA_W):   $wordCount"
Write-Host "Formats (LA_F): $formatCount"
Write-Host "Strings (LA_S): $stringCount"
Write-Host "Total:          $total"
Write-Host ""

if ($total -eq 0) {
    Write-Host "Warning: No LA_W/LA_S/LA_F macros found"
    exit 0
}

# ============================================================================
# 生成 .LANG.h
# ============================================================================

$map = @{}   # "W|key" -> "LA_W0" etc.
$sid = 0

$hLines = [System.Collections.Generic.List[string]]::new()
$hLines.Add("/*")
$hLines.Add(" * Auto-generated language IDs")
$hLines.Add(" *")
$hLines.Add(" * DO NOT EDIT - Regenerate with: i18n\i18n.bat")
$hLines.Add(" */")
$hLines.Add("")
$hLines.Add("#ifndef LANG_H__")
$hLines.Add("#define LANG_H__")
$hLines.Add("")
$hLines.Add("#ifndef LA_PREDEFINED")
$hLines.Add("#   define LA_PREDEFINED -1")
$hLines.Add("#endif")
$hLines.Add("")
$hLines.Add("enum {")
$hLines.Add("    LA_PRED = LA_PREDEFINED,  /* 基础 ID，后续 ID 从此开始递增 */")
$hLines.Add("")

# Words
if ($wordCount -gt 0) {
    $hLines.Add("    /* Words (LA_W) */")
    $wid = 0
    foreach ($line in $wordLines) {
        $parts = $line -split '\|', 4
        $str   = $parts[2]
        $files = $parts[3] -replace ',', ', '
        $idName = "LA_W$wid"
        $hLines.Add("    $idName,  /* `"$str`"  [$files] */")
        $map["W|$($parts[1])"] = $idName
        $wid++; $sid++
    }
    $hLines.Add("")
}

# Strings
if ($stringCount -gt 0) {
    $hLines.Add("    /* Strings (LA_S) */")
    $strid = 0
    foreach ($line in $stringLines) {
        $parts = $line -split '\|', 4
        $str   = $parts[2]
        $files = $parts[3] -replace ',', ', '
        $idName = "LA_S$strid"
        $hLines.Add("    $idName,  /* `"$str`"  [$files] */")
        $map["S|$($parts[1])"] = $idName
        $strid++; $sid++
    }
    $hLines.Add("")
}

# Formats
if ($formatCount -gt 0) {
    $hLines.Add("    /* Formats (LA_F) - Format strings for validation */")
    $fid = 0
    foreach ($line in $formatLines) {
        $parts = $line -split '\|', 4
        $str   = $parts[2]
        $files = $parts[3] -replace ',', ', '
        $idName = "LA_F$fid"
        # 提取格式参数列表
        $params = ([regex]::Matches($str, '%[sdifuxXclu]') | ForEach-Object { $_.Value }) -join ','
        if ($params) {
            $hLines.Add("    $idName,  /* `"$str`" ($params)  [$files] */")
        } else {
            $hLines.Add("    $idName,  /* `"$str`"  [$files] */")
        }
        $map["F|$str"] = $idName
        $fid++; $sid++
    }
    $hLines.Add("")
}

$hLines.Add("    LA_NUM = $sid")
$hLines.Add("};")
$hLines.Add("")
if ($formatCount -gt 0) {
    $hLines.Add("/* 格式字符串起始位置（用于验证） */")
    $hLines.Add("#define LA_FMT_START LA_F0")
} else {
    $hLines.Add("/* 无格式字符串 */")
    $hLines.Add("#define LA_FMT_START LA_NUM")
}
$hLines.Add("")
$hLines.Add("/* 字符串表 */")
$hLines.Add("extern const char* lang_en[LA_NUM];")
$hLines.Add("")
$hLines.Add("#endif /* LANG_H__ */")

[System.IO.File]::WriteAllLines($OutputH, $hLines, [System.Text.UTF8Encoding]::new($false))

# ============================================================================
# 生成 .LANG.c
# ============================================================================

$cLines = [System.Collections.Generic.List[string]]::new()
$cLines.Add("/*")
$cLines.Add(" * Auto-generated language strings")
$cLines.Add(" */")
$cLines.Add("")
$cLines.Add("#include `".LANG.h`"")
$cLines.Add("")
$cLines.Add("/* 字符串表 */")
$cLines.Add("const char* lang_en[LA_NUM] = {")

function Escape-CString([string]$s) {
    return $s.Replace('\', '\\').Replace('"', '\"')
}

$wid = 0
foreach ($line in $wordLines) {
    $str = ($line -split '\|', 4)[2]
    $cLines.Add("    [LA_W$wid] = `"$(Escape-CString $str)`",")
    $wid++
}
$strid = 0
foreach ($line in $stringLines) {
    $str = ($line -split '\|', 4)[2]
    $cLines.Add("    [LA_S$strid] = `"$(Escape-CString $str)`",")
    $strid++
}
$fid = 0
foreach ($line in $formatLines) {
    $str = ($line -split '\|', 4)[2]
    $cLines.Add("    [LA_F$fid] = `"$(Escape-CString $str)`",")
    $fid++
}

$cLines.Add("};")
[System.IO.File]::WriteAllLines($OutputC, $cLines, [System.Text.UTF8Encoding]::new($false))

# ============================================================================
# --export：生成 lang.en 翻译模板
# ============================================================================

if ($ExportMode) {
    $langEnPath = Join-Path $SourceDir "lang.en"
    $enLines = [System.Collections.Generic.List[string]]::new()
    $enLines.Add("# Language Table (one string per line)")
    $enLines.Add("# Use this file as a template for other language translations")
    $enLines.Add("# Line number corresponds to string ID (starting from 0)")
    foreach ($line in $wordLines)   { $enLines.Add(($line -split '\|', 4)[2]) }
    foreach ($line in $stringLines) { $enLines.Add(($line -split '\|', 4)[2]) }
    foreach ($line in $formatLines) { $enLines.Add(($line -split '\|', 4)[2]) }
    [System.IO.File]::WriteAllLines($langEnPath, $enLines, [System.Text.UTF8Encoding]::new($false))
}

# ============================================================================
# --import SUFFIX：生成 LANG.SUFFIX.h
# ============================================================================

if ($ImportSuffix -ne "") {
    $importH = Join-Path $SourceDir "LANG.$ImportSuffix.h"
    if (Test-Path $importH) {
        $bak = "$importH.bak"
        Move-Item $importH $bak -Force
        Write-Host "Backed up existing file: $bak"
    }
    $iLines = [System.Collections.Generic.List[string]]::new()
    $iLines.Add("/* Auto-generated language strings */")
    $iLines.Add("")
    $iLines.Add("#include `".LANG.h`"")
    $iLines.Add("")
    $iLines.Add("static const char* lang_${ImportSuffix}[LA_NUM] = {")
    $wid = 0
    foreach ($line in $wordLines)   { $iLines.Add("    [LA_W$wid] = `"$(Escape-CString (($line -split '\|',4)[2]))`","); $wid++ }
    $strid = 0
    foreach ($line in $stringLines) { $iLines.Add("    [LA_S$strid] = `"$(Escape-CString (($line -split '\|',4)[2]))`","); $strid++ }
    $fid = 0
    foreach ($line in $formatLines) { $iLines.Add("    [LA_F$fid] = `"$(Escape-CString (($line -split '\|',4)[2]))`","); $fid++ }
    $iLines.Add("};")
    [System.IO.File]::WriteAllLines($importH, $iLines, [System.Text.UTF8Encoding]::new($false))
}

# ============================================================================
# 保存 map 供调试
# ============================================================================

$mapLines = $map.GetEnumerator() | ForEach-Object { "$($_.Key)|$($_.Value)" }
[System.IO.File]::WriteAllLines($TempMap, $mapLines, [System.Text.UTF8Encoding]::new($false))

# ============================================================================
# 输出生成结果概览
# ============================================================================

Write-Host "Generated:"
Write-Host "  $OutputH ($sid IDs)"
Write-Host "  $OutputC"
if ($ExportMode)       { Write-Host "  $(Join-Path $SourceDir 'lang.en')" }
if ($ImportSuffix -ne "") { Write-Host "  $(Join-Path $SourceDir "LANG.$ImportSuffix.h")" }
Write-Host ""

# ============================================================================
# 回写源文件，用正确 ID 替换宏参数（等价于 perl -i 替换）
# ============================================================================

Write-Host "Updating source files..."

# 正则替换 MatchEvaluator（PS 5.1+ 支持 ScriptBlock 作为 MatchEvaluator）
$reW = [regex]'(LA_W\s*\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*)(?:0|LA_[WFS]\d+)'
$reS = [regex]'(LA_S\s*\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*)(?:0|LA_[WFS]\d+)'
$reF = [regex]'(LA_F\s*\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*)(?:0|LA_[WFS]\d+)'

# 闭包引用 $map（PowerShell 闭包通过 $using: 或直接捕获）
$mapRef = $map

Get-ChildItem -Path $SourceDir -Recurse -File -Include @("*.c","*.h") |
    Where-Object { $_.FullName -ne $OutputH -and $_.FullName -ne $OutputC } |
    ForEach-Object {
        $file = $_.FullName
        try {
            $content = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)

            $content = $reW.Replace($content, [System.Text.RegularExpressions.MatchEvaluator]{
                param($m)
                $prefix = $m.Groups[1].Value
                $key    = $m.Groups[2].Value.Trim().ToLower()
                $sid    = if ($mapRef.ContainsKey("W|$key")) { $mapRef["W|$key"] } else { "0" }
                "$prefix$sid"
            })

            $content = $reS.Replace($content, [System.Text.RegularExpressions.MatchEvaluator]{
                param($m)
                $prefix = $m.Groups[1].Value
                $key    = $m.Groups[2].Value.ToLower()
                $sid    = if ($mapRef.ContainsKey("S|$key")) { $mapRef["S|$key"] } else { "0" }
                "$prefix$sid"
            })

            $content = $reF.Replace($content, [System.Text.RegularExpressions.MatchEvaluator]{
                param($m)
                $prefix = $m.Groups[1].Value
                $str    = $m.Groups[2].Value
                $sid    = if ($mapRef.ContainsKey("F|$str")) { $mapRef["F|$str"] } else { "0" }
                "$prefix$sid"
            })

            [System.IO.File]::WriteAllText($file, $content, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  Updated: $($_.Name)"
        } catch {
            Write-Warning "  Failed to update $($_.Name): $_"
        }
    }

Write-Host ""
Write-Host "Done! Source files updated with correct LA_W/F/Sxxx IDs"
Write-Host "Next: Rebuild with updated LANG.c"

# 清理临时文件
Remove-Item $TempMarkerH -ErrorAction SilentlyContinue
if (-not $DebugMode) {
    foreach ($f in @($TempAll,$TempWords,$TempFormats,$TempStrings,$TempMap)) {
        Remove-Item $f -ErrorAction SilentlyContinue
    }
}
