#!/bin/bash
#
# 多语言字符串提取工具 - 生成 LANG.h 和 LANG.c
#
# 用法：./i18n/i18n.sh <source_dir>
# 示例：./i18n/i18n.sh p2p_ping
#
# ============================================================================
# 宏系统说明
# ============================================================================
#
# LA_W(str, id) - Words 词汇
#   用于单个词或短语，常用于状态名、按钮文本等
#   示例：LA_W("CONNECTED", LA_W2)
#
# LA_S(str, id) - Strings 字符串
#   用于完整句子或长文本
#   示例：LA_S("Connection established", LA_S0)
#
# LA_F(str, id, ...) - Formats 格式化字符串
#   用于包含 printf 格式符的字符串
#   示例：LA_F("State: %s (%d)", LA_F0, state, code)
#
# ============================================================================
# ID 命名规则（按字母顺序排列）
# ============================================================================
#
# LA_PREDEFINED - 预定义基础 ID（默认 -1，可通过编译选项重定义）
# LA_PRED       - 枚举基础 ID（= LA_PREDEFINED），后续 ID 从此递增
#
# LA_W0~W8   - Words 词汇 ID
# LA_F0~F3   - Formats 格式化字符串 ID
# LA_S0~S26  - Strings 普通字符串 ID
#
# 各类型独立编号，增强代码可读性
#
# 说明：通过设置 LA_PREDEFINED 可以调整所有 ID 的起始值
#       例如：-DLA_PREDEFINED=100 可让所有 ID 从 100 开始
#
# ============================================================================
# 归并规则（去重机制）
# ============================================================================
#
# 不同类型的字符串有不同的归并规则：
#
# 【LA_W - Words 词汇】
#
# 1. Trim 处理：去除字符串首尾空格
#    " CLOSING"   -> "CLOSING"
#    "ERROR "     -> "ERROR"
#    " UNKNOWN "  -> "UNKNOWN"
#
# 2. 忽略大小写：转为小写后作为 key 比对
#    "CLosED"     -> 小写 "closed"  -> 归并到 "CLOSED"
#    "CLOsiNG"    -> 小写 "closing" -> 归并到 "CLOSING"
#    "PUNchiNG"   -> 小写 "punching"-> 归并到 "PUNCHING"
#
# 3. 排序和去重：基于 key（小写版本）进行字母顺序排序和去重
#    排序命令：sort -u -t'|' -k2,2
#    - 相同 key 的多个变体只保留第一个
#    - 按 key 字母序排列：closed < closing < connected < error < init...
#    - ID 编号：LA_W0=CLOSED, LA_W1=CLOSING, LA_W2=CONNECTED...
#
# 4. 源码保留原样：源文件中保留原始字符串（包括空格和大小写）
#    代码：LA_W(" CLOSING", LA_W1)   // 保留前导空格
#    映射：" CLOSING" -> trim+lc -> "closing" -> LA_W1
#    输出：LANG.c 中统一存储规范化版本 "CLOSING"
#
# 归并示例：
#   LA_W("CLOSING", LA_W1)      // 原始标准版本
#   LA_W(" CLOSING", LA_W1)     // 前导空格 -> 归并
#   LA_W("CLOsiNG", LA_W1)      // 大小写混合 -> 归并
#   LA_W("closing ", LA_W1)     // 小写+尾随空格 -> 归并
#
# 所有变体都指向同一个 LA_W1，LANG.c 中只存储一份 "CLOSING"
# （LA_W1 是因为 "closing" 在字母表中排序到第2位，从0开始编号）
#
# 【LA_S - Strings 字符串】
#
# 1. 只忽略大小写：转为小写后作为 key 比对
#    "Connection Error" 和 "connection error" -> 归并
#
# 2. 空格格式必须一致：不做 trim 处理
#    " Connection Error" 和 "Connection Error" -> 不归并（前导空格不同）
#    "Connection Error " 和 "Connection Error" -> 不归并（尾随空格不同）
#
# 【LA_F - Formats 格式化字符串】
#
# 1. 完全一致：不做任何转换
#    格式化字符串必须完全匹配才能归并（包括大小写和空格）
#
# 2. 自动前缀：如果字符串不包含 % 格式符，自动添加 "% " 前缀
#    LA_F("hello world", LA_F1) -> 输出到 .LANG.c 中变为 "% hello world"
#    这让 print() 将其当作普通字符串直接输出，避免格式化解析错误
#
# ============================================================================
# 工作流程
# ============================================================================
#
# 1. 扫描源文件，提取所有 LA_W/LA_S/LA_F 宏中的字符串
# 2. 对每个字符串生成归并 key（trim + lowercase）
# 3. 按 key 去重（sort -u -t'|' -k2,2），保留首次出现的原始字符串
# 4. 按 key 字母顺序排序，生成连续的 LA_W/F/S 编号
#    - Words 按小写字母序：closed, closing, connected, error, init...
#    - Formats 按小写字母序
#    - Strings 按小写字母序
# 5. 生成 LANG.h（枚举定义）和 LANG.c（字符串数组）
# 6. 回写源文件，更新所有宏的第二个参数为正确的 SID
#
# 注意：ID 编号由排序决定，添加/删除字符串可能导致 ID 重新分配
#
# ============================================================================
# NDEBUG 双模式（i18n.sh 命令行选项 --ndebug）
# ============================================================================
#
# 默认 (Debug):
#   - 枚举 ID 名称基于 SID（稳定自增编号），如 LA_W5, LA_S26, LA_F96
#   - 枚举按 SID 顺序排列，空洞用占位符 _LA_N 填充，LA_NUM 覆盖全部 SID
#   - 数组可能有空洞（以空间换稳定性：lang_str() 对 NULL 返回 ""）
#   - 增删条目不影响已有项的 ID，避免源文件大面积 diff 污染
#
# --ndebug (Release):
#   - 枚举按类型分组连续编号，如 LA_W0~Wn, LA_S0~Sn, LA_F0~Fn
#   - 数组紧凑无空洞，最小化内存占用
#   - 增删条目会导致现有 ID 值重新分配
#
# 两种模式共用相同的 SID 追踪系统（.i18n 文件），切换无需重新初始化
#
# ============================================================================

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <source_dir> [--name NAME] [--ndebug] [--export] [--import SUFFIX]"
    echo "Example: $0 p2p_ping"
    echo "Options:"
    echo "  --name NAME       Set module name for unique symbols (default: auto from dir name)"
    echo "  --export          Export lang.en template file for translations"
    echo "  --import SUFFIX   Generate LANG.SUFFIX.h with embedded language table from lang.SUFFIX"
    echo "  --ndebug          Generate compact sequential IDs (release mode)"
    echo "  --debug           Keep temp files in ./i18n/debug/ for inspection"
    exit 1
fi

SOURCE_DIR="$1"
EXPORT_LANG_EN=0
IMPORT_SUFFIX=""
NDEBUG_MODE=0
DEBUG_MODE=0
LA_NAME=""

# 解析选项
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --export)
            EXPORT_LANG_EN=1
            ;;
        --import)
            shift
            if [ $# -eq 0 ]; then
                echo "Error: --import requires a SUFFIX argument"
                exit 1
            fi
            IMPORT_SUFFIX="$1"
            ;;
        --name)
            shift
            if [ $# -eq 0 ]; then
                echo "Error: --name requires a NAME argument"
                exit 1
            fi
            LA_NAME="$1"
            ;;
        --ndebug)
            NDEBUG_MODE=1
            ;;
        --debug)
            DEBUG_MODE=1
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

OUTPUT_H="$SOURCE_DIR/.LANG.h"
OUTPUT_C="$SOURCE_DIR/.LANG.c"
USER_LANG_H="$SOURCE_DIR/LANG.h"

# 加载/初始化持久化 SID 计数器（与 .LANG.c 同目录的 .i18n 文件）
# SID 是字符串条目的唯一序列号，跨版本稳定追踪；各子目录独立计数，互不干扰
# 若 .i18n 不存在则全量重新初始化（所有条目重新从 1 分配 SID）
I18N_FILE="$SOURCE_DIR/.i18n"
SID_NEXT=""
I18N_REINIT=0
if [ -f "$I18N_FILE" ]; then
    SID_NEXT=$(awk -F= '/^SID_NEXT=/{print $2}' "$I18N_FILE" | tr -d '[:space:]')
    # 如果没有通过 --name 指定，尝试从 .i18n 文件读取
    if [ -z "$LA_NAME" ]; then
        LA_NAME=$(awk -F= '/^LA_NAME=/{print $2}' "$I18N_FILE" | tr -d '[:space:]')
    fi
else
    I18N_REINIT=1
    echo "Note: $I18N_FILE not found — reinitializing all SIDs from 1"
fi
[ -z "${SID_NEXT:-}" ] && SID_NEXT=1
SID_NEXT_START=$SID_NEXT

# 如果 LA_NAME 仍未设置，从目录名自动生成
if [ -z "$LA_NAME" ]; then
    LA_NAME=$(basename "$SOURCE_DIR")
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Directory not found: $SOURCE_DIR"
    exit 1
fi

# 检查是否存在用户定义的 LANG.h，如果不存在则生成模板
if [ ! -f "$USER_LANG_H" ]; then
    echo "Creating template LANG.h in $SOURCE_DIR..."
    cat > "$USER_LANG_H" <<'EOF'
#ifndef LANG_H_
#define LANG_H_

enum {
    /* 预定义字符串 ID（在此添加项目特定的预定义字符串）*/
    /* 示例：
    SID_CUSTOM0,
    SID_CUSTOM1,
    */
    
    PRED_NUM,
};

/* 预定义字符串内容（对应上面的枚举）*/
/* 示例：
#define STR_CUSTOM0 "Custom String 0"
#define STR_CUSTOM1 "Custom String 1"
*/

/* 设置预定义基础 ID（自动生成的 ID 从此值+1 开始）*/
#define LA_PREDEFINED (PRED_NUM - 1)

/* 包含自动生成的语言 ID 定义（必须在 LA_PREDEFINED 之后）*/
#include ".LANG.h"

EOF
    # 动态生成 LA_RID 宏和 extern 声明（使用模块名避免符号冲突）
    printf '#define LA_RID LA_%s\n' "$LA_NAME" >> "$USER_LANG_H"
    printf 'extern int LA_%s;\n\n' "$LA_NAME" >> "$USER_LANG_H"
    cat >> "$USER_LANG_H" <<'EOF'
#include <i18n.h>

EOF
    # 动态生成 lang_init 函数声明（使用模块名避免符号冲突）
    printf '/* 语言初始化函数（自动生成，请勿修改）*/\n' >> "$USER_LANG_H"
    printf 'void LA_%s_init(void);\n' "$LA_NAME" >> "$USER_LANG_H"
    printf '#define LA_init LA_%s_init\n' "$LA_NAME" >> "$USER_LANG_H"
    cat >> "$USER_LANG_H" <<'EOF'

#endif /* LANG_H_ */
EOF
    echo "  Created: $USER_LANG_H"
fi

echo "=== Language String Extractor ==="
echo "Source: $SOURCE_DIR"
echo

# 临时文件
if [ "$DEBUG_MODE" -eq 1 ]; then
    _debug_dir="$(dirname "$0")/debug"
    mkdir -p "$_debug_dir"
    TEMP_ALL="$_debug_dir/all.txt"
    TEMP_WORDS="$_debug_dir/words.txt"
    TEMP_FORMATS="$_debug_dir/formats.txt"
    TEMP_STRINGS="$_debug_dir/strings.txt"
    TEMP_MAP="$_debug_dir/map.txt"
    TEMP_LINE_RAW="$_debug_dir/line_raw.txt"
    TEMP_LINE_MAP="$_debug_dir/line_map.txt"
    TEMP_OLD_SID_MAP="$_debug_dir/old_sid_map.txt"
    TEMP_OLD_IMPORT_MAP="$_debug_dir/old_import_map.txt"
    TEMP_ENUM_DATA="$_debug_dir/enum_data.txt"
    echo "Debug mode: temp files saved to $_debug_dir/"
else
    TEMP_ALL=$(mktemp)
    TEMP_WORDS=$(mktemp)
    TEMP_FORMATS=$(mktemp)
    TEMP_STRINGS=$(mktemp)
    TEMP_MAP=$(mktemp)
    TEMP_LINE_RAW=$(mktemp)
    TEMP_LINE_MAP=$(mktemp)
    TEMP_OLD_SID_MAP=$(mktemp)
    TEMP_OLD_IMPORT_MAP=$(mktemp)
    TEMP_ENUM_DATA=$(mktemp)
fi

# 处理格式字符串：如果不包含 % 则在前面添加 "% " 前缀
# 这样 print() 会将其当作普通字符串直接输出，而非格式化解析
_fmt_ensure_prefix() {
    local _s="$1"
    case "$_s" in
        *%*) printf '%s' "$_s" ;;
        *)   printf '%s' "% $_s" ;;
    esac
}

cleanup() {
    if [ "$DEBUG_MODE" -eq 0 ]; then
        rm -f "$TEMP_ALL" "$TEMP_WORDS" "$TEMP_FORMATS" "$TEMP_STRINGS" "$TEMP_MAP" \
              "$TEMP_LINE_RAW" "$TEMP_LINE_MAP" \
              "$TEMP_OLD_SID_MAP" "$TEMP_OLD_IMPORT_MAP" "$TEMP_ENUM_DATA" \
              "${TEMP_EN_TRANS_MAP:-}"
    fi
}
trap cleanup EXIT

# 查找 compile_commands.json（CMake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON 生成）
_compdb=""
for _bd in build_cmake cmake-build-debug cmake-build-release build .; do
    if [ -f "$_bd/compile_commands.json" ]; then
        _compdb="$(pwd)/$_bd/compile_commands.json"
        break
    fi
done

# 找不到时，若有 CMakeLists.txt 则自动 configure（只生成 compile_commands.json，不编译）
if [ -z "$_compdb" ] && [ -f "CMakeLists.txt" ]; then
    echo "compile_commands.json not found. Running cmake configure..."
    if cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -B build_cmake -S . >/dev/null 2>&1; then
        if [ -f "build_cmake/compile_commands.json" ]; then
            _compdb="$(pwd)/build_cmake/compile_commands.json"
            echo "Generated: $_compdb"
        fi
    else
        echo "Warning: cmake configure failed, falling back to compile_flags.txt"
    fi
fi

# 找不到时，若有 Makefile 且 bear 可用，则用 bear --dry-run 生成 compile_commands.json
# bear 通过拦截编译器调用捕获实际编译参数，适用于任意 Makefile 项目（含交叉编译）
# --dry-run（或旧版 bear 的 -- make -n）只解析命令，不真正编译
if [ -z "$_compdb" ] && [ -f "Makefile" ] && ! command -v bear >/dev/null 2>&1; then
    echo "Makefile detected but 'bear' is not installed."
    echo "bear is needed to extract per-file compile flags for Makefile projects."
    echo "Install:"
    echo "  macOS:  brew install bear"
    echo "  Debian: sudo apt install bear"
    echo "  Fedora: sudo dnf install bear"
    printf "Install bear now? [Y/n] "
    read -r _bear_ans </dev/tty
    case "$_bear_ans" in
        [Nn]*)
            echo "Skipping bear, falling back to compile_flags.txt"
            ;;
        *)
            if command -v brew >/dev/null 2>&1; then
                brew install bear
            elif command -v apt-get >/dev/null 2>&1; then
                sudo apt-get install -y bear
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y bear
            else
                echo "Warning: cannot auto-install bear (unknown package manager), please install manually"
            fi
            ;;
    esac
fi

if [ -z "$_compdb" ] && [ -f "Makefile" ] && command -v bear >/dev/null 2>&1; then
    echo "compile_commands.json not found. Running bear to intercept Makefile..."
    _bear_out="$(pwd)/compile_commands.json"
    # bear >= 3.x 使用 --output 和 --; bear 2.x 直接接命令
    # 优先尝试 3.x 语法
    if bear --version 2>&1 | grep -q '^bear [3-9]'; then
        bear --output "$_bear_out" -- make -n >/dev/null 2>&1 || true
    else
        bear -o "$_bear_out" make -n >/dev/null 2>&1 || true
    fi
    if [ -f "$_bear_out" ] && [ -s "$_bear_out" ]; then
        _compdb="$_bear_out"
        echo "Generated: $_compdb"
    else
        rm -f "$_bear_out"
        echo "Warning: bear failed or produced empty output, falling back to compile_flags.txt"
    fi
fi

if [ -n "$_compdb" ]; then
    echo "Using compile_commands.json: $_compdb"
else
    echo "Note: compile_commands.json not found, falling back to compile_flags.txt (may be incomplete)"
fi

# 从 compile_commands.json 提取指定源文件的编译器和编译参数
# compile_commands.json 格式固定（CMake 生成），每个字段单独一行，可安全逐行解析
# 输出格式："<compiler> <flags>"，第一个 token 是编译器本身
_cc_and_flags_for_file() {
    local _f _result
    _f=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
    if [ -n "$_compdb" ]; then
        _result=$(awk -v target="$_f" '
        /^\{/  { entry_file = ""; entry_cmd = "" }
        /^\}/  {
            # 路径匹配：精确匹配，或互为后缀（应对路径前缀不同的情况）
            tlen = length(target); flen = length(entry_file)
            match_ok = (entry_file == target) || \
                       (tlen >= flen && flen > 0 && substr(target, tlen-flen+1) == entry_file) || \
                       (flen >= tlen && tlen > 0 && substr(entry_file, flen-tlen+1) == target)
            if (match_ok && entry_cmd != "") {
                # 保留编译器（第一个 token），去掉 -c、-o <next>、依赖生成标志、源文件名
                n = split(entry_cmd, a, " ")
                out = a[1]; skip = 0
                for (i = 2; i <= n; i++) {
                    if (skip) { skip = 0; continue }
                    if (a[i] == "-c" || a[i] == "-MF" || a[i] == "-MT" || \
                        a[i] == "-MQ" || a[i] == "-MMD" || a[i] == "-MD") continue
                    if (a[i] == "-o") { skip = 1; continue }
                    if (a[i] ~ /\.(c|cpp|cc|cxx)$/) continue
                    out = out " " a[i]
                }
                print out
                exit
            }
        }
        /"file"/ {
            s = $0
            sub(/.*"file"[[:space:]]*:[[:space:]]*"/, "", s)
            sub(/".*$/, "", s)
            entry_file = s
        }
        /"command"/ {
            s = $0
            sub(/.*"command"[[:space:]]*:[[:space:]]*"/, "", s)
            sub(/"[[:space:]]*,?[[:space:]]*$/, "", s)
            entry_cmd = s
        }
        ' "$_compdb")
        if [ -n "$_result" ]; then
            printf '%s' "$_result"
            return
        fi
        # awk 无输出：此文件不在 compile_commands.json 中
        # .h 文件：尝试从同目录下的 .c 文件借用编译参数
        case "$_f" in
        *.h)
            local _dir; _dir=$(dirname "$_f")
            local _sibling
            _sibling=$(awk '/"file"/ {
                s=$0; sub(/.*"file"[[:space:]]*:[[:space:]]*"/, "", s); sub(/".*$/, "", s)
                print s
            }' "$_compdb" | grep "^${_dir}/.*\.c$" | head -1)
            if [ -n "$_sibling" ]; then
                _result=$(_cc_and_flags_for_file "$_sibling")
                if [ -n "$_result" ]; then
                    printf '%s' "$_result"
                    return
                fi
            fi
            ;;
        esac
    fi
    # 兜底：host cc + compile_flags.txt
    local _flags=""
    for _cfpath in "compile_flags.txt" "$SOURCE_DIR/../compile_flags.txt"; do
        if [ -f "$_cfpath" ]; then
            _flags=$(grep -v '^#' "$_cfpath" | tr '\n' ' ')
            break
        fi
    done
    printf 'cc %s' "$_flags"
}

# 生成临时 marker 头文件
# 利用 #ifndef 保护（i18n.h 中已同步添加），使此处定义不被 i18n.h 覆盖
_marker_h=$(mktemp /tmp/i18n_markers_XXXXXX)  # BSD mktemp 要求 X 在末尾，不带后缀
cat > "$_marker_h" <<'MARKER_EOF'
/* 屏蔽用户的 LANG.h — marker 已自带 LA_W/S/F 定义，无需从 LANG.h 引入 */
#define LANG_H_
/* 从 variadic args 中提取 SID（第2个参数），缺省为 0 */
#define _I18N_SID_GET(_id, _sid, ...) _sid
#define _I18N_SID(...) _I18N_SID_GET(__VA_ARGS__, 0, 0)
#ifndef LA_W
#define LA_W(WD, ...) _I18NW_ WD _I18NSID_ _I18N_SID(__VA_ARGS__) _I18NLINE_ __LINE__ _I18NW_END_
#endif
#ifndef LA_S
#define LA_S(STR, ...) _I18NS_ STR _I18NSID_ _I18N_SID(__VA_ARGS__) _I18NLINE_ __LINE__ _I18NS_END_
#endif
#ifndef LA_F
#define LA_F(FMT, ...) _I18NF_ FMT _I18NSID_ _I18N_SID(__VA_ARGS__) _I18NLINE_ __LINE__ _I18NF_END_
#endif
#ifndef LA_CW
#define LA_CW(WD, ...) _I18NW_ WD _I18NSID_ _I18N_SID(__VA_ARGS__) _I18NLINE_ __LINE__ _I18NW_END_
#endif
#ifndef LA_CS
#define LA_CS(STR, ...) _I18NS_ STR _I18NSID_ _I18N_SID(__VA_ARGS__) _I18NLINE_ __LINE__ _I18NS_END_
#endif
#ifndef LA_CF
#define LA_CF(FMT, ...) _I18NF_ FMT _I18NSID_ _I18N_SID(__VA_ARGS__) _I18NLINE_ __LINE__ _I18NF_END_
#endif
MARKER_EOF

# 保存 awk 提取脚本到临时文件（避免重复）
_awk_extract=$(mktemp /tmp/i18n_awk_XXXXXX)
cat > "$_awk_extract" <<'AWK_EOF'
{ content = content "\n" $0 }
END {
    pos = 1; clen = length(content)
    while (pos <= clen) {
        rest = substr(content, pos)
        # 查找下一个 marker：_I18NW_、_I18NS_、_I18NF_
        if (!match(rest, /_I18N[WSF]_/)) break
        tp = substr(rest, RSTART + 5, 1)   # W, S, or F
        pos = pos + RSTART + RLENGTH - 1

        # 找对应的结束 marker
        end_pat = "_I18N" tp "_END_"
        rest2 = substr(content, pos)
        if (!match(rest2, end_pat)) { pos++; continue }
        fragment = substr(rest2, 1, RSTART - 1)
        pos = pos + RSTART + RLENGTH - 1

        # 在 fragment 中分离字符串部分、SID 和行号
        # 格式: <strings> _I18NSID_ <sid> _I18NLINE_ <line>
        esid = 0
        eline = 0
        str_frag = fragment
        if (match(fragment, /_I18NSID_/)) {
            str_frag = substr(fragment, 1, RSTART - 1)
            _sf = substr(fragment, RSTART + RLENGTH)
            if (match(_sf, /_I18NLINE_/)) {
                _sid_part = substr(_sf, 1, RSTART - 1)
                _line_part = substr(_sf, RSTART + RLENGTH)
            } else {
                _sid_part = _sf
                _line_part = ""
            }
            gsub(/[ \t\n]/, "", _sid_part)
            gsub(/[ \t\n]/, "", _line_part)
            esid = _sid_part + 0
            eline = _line_part + 0
        }

        # 从 str_frag 中提取并拼接所有字符串字面量（含宽字符串 L"..."）
        result = ""
        nlit = 0   # 统计字符串字面量个数（>1 = 宏拼接，如 PRIu64）
        fpos = 1; flen = length(str_frag)
        while (fpos <= flen) {
            c1 = substr(str_frag, fpos, 1)
            # 跳过 C 字符串前缀：L"..." / u"..." / U"..." / u8"..."
            if (c1 ~ /[LuU]/ && fpos+1 <= flen) {
                nxt = substr(str_frag, fpos+1, 1)
                if (nxt == "\"") {
                    fpos++; c1 = "\""
                } else if (c1 == "u" && nxt == "8" && fpos+2 <= flen && substr(str_frag, fpos+2, 1) == "\"") {
                    fpos += 2; c1 = "\""
                }
            }
            if (c1 == "\"") {
                nlit++
                fpos++
                while (fpos <= flen) {
                    c2 = substr(str_frag, fpos, 1)
                    if (c2 == "\\") {
                        result = result substr(str_frag, fpos, 2)
                        fpos += 2
                    } else if (c2 == "\"") {
                        fpos++; break
                    } else {
                        result = result c2; fpos++
                    }
                }
            } else {
                fpos++
            }
        }

        # 多段字符串字面量（如 PRIu64）照常提取，回写时只更新枚举和 SID 参数

        if (result != "") {
            occ = 0
            if (eline > 0) {
                line_type_occ[eline, tp]++
                occ = line_type_occ[eline, tp]
            }
            if (tp == "W") {
                key = result; gsub(/^[ \t]+|[ \t]+$/, "", key)
                print "W|" tolower(key) "|" key "|" base "|" esid "|" eline "|" src "|" occ
            } else if (tp == "S") {
                print "S|" tolower(result) "|" result "|" base "|" esid "|" eline "|" src "|" occ
            } else {
                print "F|" result "|" result "|" base "|" esid "|" eline "|" src "|" occ
            }
        }
    }
}
AWK_EOF

# 提取所有 LA_W/LA_S/LA_F
# 处理 .c 和 .h 文件（.h 用 -x c 强制当 C 处理；cc -E 会递归展开所有 #include）
# 排除自动生成的文件，避免重复收录
find "$SOURCE_DIR" \( -name "*.c" -o -name "*.h" \) \
    ! -name ".LANG.h" ! -name ".LANG.c" \
    ! -name "LANG.h"  ! -name "LANG.*.h" | while read -r file; do
    base=$(basename "$file")
    _cc_flags=$(_cc_and_flags_for_file "$file")

    # .h 文件需要 -x c 告知编译器当作 C 源文件处理
    _xflag=""
    case "$file" in *.h) _xflag="-x c" ;; esac

    # 捕获 cc -E 的 stderr；预处理失败时打印警告（不影响其余文件继续处理）
    _cc_err_tmp=$(mktemp)
    # shellcheck disable=SC2086
    if ! $_cc_flags $_xflag -E -P -include "$_marker_h" "$file" \
            2>"$_cc_err_tmp" | \
    awk -v base="$base" -v src="$file" -f "$_awk_extract"; then
        echo "Warning: preprocessing failed for $file" >&2
        [ "$DEBUG_MODE" -eq 1 ] && cat "$_cc_err_tmp" >&2
    fi
    rm -f "$_cc_err_tmp"

    # Phase 0.5: 处理 #define 中的 LA_ 调用
    # 支持多行续行（以 \ 结尾的行会与后续行合并）
    # 用 awk 合并续行后检测是否包含 LA_C?[WSF]
    _probe_tmp=$(mktemp /tmp/i18n_probe_XXXXXX.c)
    _abs_file=$(cd "$(dirname "$file")" && pwd)/$(basename "$file")
    # 转义 C 字符串特殊字符：\ → \\, " → \"
    _escaped_file=$(printf '%s' "$_abs_file" | sed 's/\\/\\\\/g; s/"/\\"/g')
    echo "#include \"$_escaped_file\"" > "$_probe_tmp"
    
    awk -v srcfile="$file" '
    BEGIN { in_define = 0; start_line = 0; content = "" }
    {
        # 检查是否是 #define 开头
        if (/^[[:space:]]*#[[:space:]]*define[[:space:]]/) {
            in_define = 1
            start_line = NR
            content = $0
        } else if (in_define) {
            content = content " " $0
        }
        
        # 检查是否续行（以 \ 结尾）
        if (in_define && /\\[[:space:]]*$/) {
            # 去掉行尾的 \ 和空白
            sub(/\\[[:space:]]*$/, "", content)
            next
        }
        
        # 续行结束或非续行，处理累积的内容
        if (in_define) {
            # 检查合并后的内容是否包含 LA_C?[WSF](
            if (match(content, /LA_C?[WSF]\(/)) {
                # 从 content 中提取所有 LA_C?[WSF](...) 调用
                line = content
                probe_num = 0
                pos = 1
                len = length(line)
                while (pos <= len) {
                    rest_str = substr(line, pos)
                    if (!match(rest_str, /LA_C?[WSF]\(/)) break
                    start = pos + RSTART - 1
                    # 找匹配的右括号
                    depth = 1
                    ppos = start + RLENGTH
                    while (ppos <= len && depth > 0) {
                        c = substr(line, ppos, 1)
                        if (c == "(") depth++
                        else if (c == ")") depth--
                        ppos++
                    }
                    if (depth == 0) {
                        call = substr(line, start, ppos - start)
                        probe_num++
                        print "#line " start_line " \"" srcfile "\""
                        print "static inline void __i18n_probe_" start_line "_" probe_num "() { " call "; }"
                    }
                    pos = ppos
                }
            }
            in_define = 0
            content = ""
        }
    }
    ' "$file" >> "$_probe_tmp"

    # 检查是否生成了探测代码（超过1行=有内容）
    if [ "$(wc -l < "$_probe_tmp")" -gt 1 ]; then
        # 用相同编译参数预处理探测文件
        _cc_err_tmp2=$(mktemp)
        # shellcheck disable=SC2086
        if $_cc_flags -x c -E -P -include "$_marker_h" "$_probe_tmp" 2>"$_cc_err_tmp2" | \
            awk -v base="$base" -v src="$file" -f "$_awk_extract"; then
            :
        else
            [ "$DEBUG_MODE" -eq 1 ] && echo "Warning: probe preprocessing failed for $file" >&2
            [ "$DEBUG_MODE" -eq 1 ] && cat "$_cc_err_tmp2" >&2
        fi
        rm -f "$_cc_err_tmp2"
    fi
    rm -f "$_probe_tmp"
done > "$TEMP_ALL"
rm -f "$_marker_h" "$_awk_extract"

# 记录每个宏调用位置（file|line|occ|type|key|sid）供回写使用
awk -F'|' 'NF >= 8 && $6 ~ /^[0-9]+$/ && $8 ~ /^[0-9]+$/ {
    print $7 "|" $6 "|" $8 "|" $1 "|" $2 "|" ($5+0)
}' "$TEMP_ALL" > "$TEMP_LINE_RAW"

# 分类并聚合文件名（去重 key，合并文件列表，保留首个非零 SID）
grep "^W|" "$TEMP_ALL" | awk -F'|' '{
    key=$2; str=$3; file=$4; sid=$5+0;
    if (seen[key]) {
        if (index(files[key], file) == 0) files[key] = files[key] "," file;
        if (sids[key]+0 == 0 && sid > 0) sids[key] = sid;
    } else {
        seen[key]=1; strs[key]=str; files[key]=file; sids[key]=sid; order[++n]=key;
    }
} END {
    for (i=1; i<=n; i++) {
        k=order[i]; print "W|" k "|" strs[k] "|" files[k] "|" sids[k]+0;
    }
}' | LC_ALL=C sort -t'|' -k2,2 > "$TEMP_WORDS" || true

grep "^F|" "$TEMP_ALL" | awk -F'|' '{
    key=$2; str=$3; file=$4; sid=$5+0;
    if (seen[key]) {
        if (index(files[key], file) == 0) files[key] = files[key] "," file;
        if (sids[key]+0 == 0 && sid > 0) sids[key] = sid;
    } else {
        seen[key]=1; strs[key]=str; files[key]=file; sids[key]=sid; order[++n]=key;
    }
} END {
    for (i=1; i<=n; i++) {
        k=order[i]; print "F|" k "|" strs[k] "|" files[k] "|" sids[k]+0;
    }
}' | LC_ALL=C sort -t'|' -k2,2 > "$TEMP_FORMATS" || true

grep "^S|" "$TEMP_ALL" | awk -F'|' '{
    key=$2; str=$3; file=$4; sid=$5+0;
    if (seen[key]) {
        if (index(files[key], file) == 0) files[key] = files[key] "," file;
        if (sids[key]+0 == 0 && sid > 0) sids[key] = sid;
    } else {
        seen[key]=1; strs[key]=str; files[key]=file; sids[key]=sid; order[++n]=key;
    }
} END {
    for (i=1; i<=n; i++) {
        k=order[i]; print "S|" k "|" strs[k] "|" files[k] "|" sids[k]+0;
    }
}' | LC_ALL=C sort -t'|' -k2,2 > "$TEMP_STRINGS" || true

# 统计
word_count=$(wc -l < "$TEMP_WORDS" | tr -d ' ')
format_count=$(wc -l < "$TEMP_FORMATS" | tr -d ' ')
string_count=$(wc -l < "$TEMP_STRINGS" | tr -d ' ')
total=$((word_count + format_count + string_count))

echo "Words (LA_W):   $word_count"
echo "Formats (LA_F): $format_count"
echo "Strings (LA_S): $string_count"
echo "Total:          $total"
echo

if [ "$total" -eq 0 ]; then
    echo "Warning: No LA_W/LA_S/LA_F macros found"
    exit 0
fi

# 从当前（旧）.LANG.c 中提取 SID→类型→字符串 映射（变更检测用，必须在覆写 .c 前完成）
# 格式: SID|TYPE|string   （TYPE = W/S/F）
if [ -f "$OUTPUT_C" ]; then
    awk '
    /SID:[0-9]/ {
        line = $0
        idx = index(line, "SID:")
        if (idx == 0) next
        rest = substr(line, idx + 4)
        entry_sid = ""
        for (ci = 1; ci <= length(rest); ci++) {
            ch = substr(rest, ci, 1)
            if (ch ~ /[0-9]/) entry_sid = entry_sid ch
            else break
        }
        if (entry_sid == "" || entry_sid+0 == 0) next
        # 提取类型（从 [LA_W...] / [LA_S...] / [LA_F...] 中获取）
        entry_type = "F"
        if (match(line, /\[LA_[WSF]/)) entry_type = substr(line, RSTART+4, 1)
        else if (line ~ /\[LA_W/) entry_type = "W"
        else if (line ~ /\[LA_S/) entry_type = "S"
        s = line; sub(/.*= "/, "", s)
        val = ""
        for (ci = 1; ci <= length(s); ci++) {
            ch = substr(s, ci, 1)
            if (ch == "\\") { val = val ch substr(s,ci+1,1); ci++ }
            else if (ch == "\"") break
            else val = val ch
        }
        if (entry_sid != "" && val != "") print entry_sid "|" entry_type "|" val
    }
    ' "$OUTPUT_C" > "$TEMP_OLD_SID_MAP" 2>/dev/null || true
else
    : > "$TEMP_OLD_SID_MAP"
fi

# 从当前（旧）.LANG.h 中提取条目状态（disabled / remove）
# 格式: SID|TYPE|status   （status 为空=active, disabled, remove）
TEMP_OLD_ENUM_STATUS=$(mktemp)
: > "$TEMP_OLD_ENUM_STATUS"
if [ -f "$OUTPUT_H" ]; then
    awk '
    /LA_[WSF][0-9]+,/ {
        line = $0
        # 提取 LA_X{SID}
        idx = match(line, /LA_[WSF][0-9]+/)
        if (idx > 0) {
            m = substr(line, RSTART, RLENGTH)
            t = substr(m, 4, 1)
            sid = substr(m, 5) + 0
            status = ""
            if (line ~ /\/\* disabled /) status = "disabled"
            else if (line ~ /\/\* remove /) status = "remove"
            print sid "|" t "|" status
        }
    }
    ' "$OUTPUT_H" > "$TEMP_OLD_ENUM_STATUS" 2>/dev/null || true
fi

# ======================================================================
# Phase 1: 收集所有条目（SID 分配 + TEMP_MAP / TEMP_ENUM_DATA）
# ======================================================================
# TEMP_MAP 格式:       TYPE|key|id_name|sid   （源文件回写用）
# TEMP_ENUM_DATA 格式: TYPE|id_name|sid|str|files_formatted|params|status
#   status: 空=active, disabled=已禁用, remove=待删除
#
# NDEBUG 模式: id_name = LA_{T}{seq}（紧凑连续）
# Debug 模式:  id_name = LA_{T}{sid}（SID 稳定映射）

sid=0
max_sid=0
first_fmt_id=""
w_seq=0; s_seq=0; f_seq=0

# 词
if [ "$word_count" -gt 0 ]; then
    while IFS='|' read -r type key str files entry_sid; do
        files_formatted=$(echo "$files" | sed 's/,/, /g')
        if [ "$I18N_REINIT" -ne 0 ] || [ -z "${entry_sid:-}" ] || ! [ "$entry_sid" -gt 0 ] 2>/dev/null; then
            entry_sid=$SID_NEXT; SID_NEXT=$((SID_NEXT + 1))
        fi
        if [ "$NDEBUG_MODE" -eq 1 ]; then
            id_name="LA_W${w_seq}"; w_seq=$((w_seq + 1))
        else
            id_name="LA_W${entry_sid}"
        fi
        printf 'W|%s|%s|%s\n' "$key" "$id_name" "$entry_sid" >> "$TEMP_MAP"
        printf 'W|%s|%s|%s|%s\n' "$id_name" "$entry_sid" "$str" "$files_formatted" >> "$TEMP_ENUM_DATA"
        [ "$entry_sid" -gt "$max_sid" ] && max_sid=$entry_sid
        sid=$((sid + 1))
    done < "$TEMP_WORDS"
fi

# 字符串
if [ "$string_count" -gt 0 ]; then
    while IFS='|' read -r type key str files entry_sid; do
        files_formatted=$(echo "$files" | sed 's/,/, /g')
        if [ "$I18N_REINIT" -ne 0 ] || [ -z "${entry_sid:-}" ] || ! [ "$entry_sid" -gt 0 ] 2>/dev/null; then
            entry_sid=$SID_NEXT; SID_NEXT=$((SID_NEXT + 1))
        fi
        if [ "$NDEBUG_MODE" -eq 1 ]; then
            id_name="LA_S${s_seq}"; s_seq=$((s_seq + 1))
        else
            id_name="LA_S${entry_sid}"
        fi
        printf 'S|%s|%s|%s\n' "$key" "$id_name" "$entry_sid" >> "$TEMP_MAP"
        printf 'S|%s|%s|%s|%s\n' "$id_name" "$entry_sid" "$str" "$files_formatted" >> "$TEMP_ENUM_DATA"
        [ "$entry_sid" -gt "$max_sid" ] && max_sid=$entry_sid
        sid=$((sid + 1))
    done < "$TEMP_STRINGS"
fi

# 格式化（放在最后，方便校验）
if [ "$format_count" -gt 0 ]; then
    while IFS='|' read -r type key str files entry_sid; do
        files_formatted=$(echo "$files" | sed 's/,/, /g')
        if [ "$I18N_REINIT" -ne 0 ] || [ -z "${entry_sid:-}" ] || ! [ "$entry_sid" -gt 0 ] 2>/dev/null; then
            entry_sid=$SID_NEXT; SID_NEXT=$((SID_NEXT + 1))
        fi
        if [ "$NDEBUG_MODE" -eq 1 ]; then
            id_name="LA_F${f_seq}"; f_seq=$((f_seq + 1))
        else
            id_name="LA_F${entry_sid}"
        fi
        [ -z "$first_fmt_id" ] && first_fmt_id="$id_name"
        params=$(printf '%s' "$str" | grep -o '%[sdifuxXclu]' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)
        # 如果 LA_F 字符串不包含 % 则添加 "% " 前缀（让 print() 直接输出）
        str_out=$(_fmt_ensure_prefix "$str")
        printf 'F|%s|%s|%s\n' "$key" "$id_name" "$entry_sid" >> "$TEMP_MAP"
        printf 'F|%s|%s|%s|%s|%s\n' "$id_name" "$entry_sid" "$str_out" "$files_formatted" "$params" >> "$TEMP_ENUM_DATA"
        [ "$entry_sid" -gt "$max_sid" ] && max_sid=$entry_sid
        sid=$((sid + 1))
    done < "$TEMP_FORMATS"
fi

# 用 TYPE|key 映射更新每个源码位置，得到 file|line|type|occ|id_name|sid
awk -F'|' '
    FNR==NR {
        map_id[$1 SUBSEP $2] = $3
        map_sid[$1 SUBSEP $2] = $4
        next
    }
    {
        k = $4 SUBSEP $5
        if (k in map_id) {
            print $1 "|" $2 "|" $4 "|" $3 "|" map_id[k] "|" map_sid[k]
        }
    }
' "$TEMP_MAP" "$TEMP_LINE_RAW" > "$TEMP_LINE_MAP"

# ======================================================================
# Phase 1b: 收集禁用条目（旧 .LANG.c 中存在但本次未扫描到的）
# ======================================================================
# Trickle 模式：宏开关变化时，消失的条目标记为 disabled（保留 ID 和字符串），
# 下次宏启用时自动恢复。用户可在 .LANG.h 中将 disabled 改为 remove 确认删除。
_disabled_count=0
if [ -s "$TEMP_OLD_SID_MAP" ]; then
    # 收集当前有效的 SID 集合
    awk -F'|' '{print $4}' "$TEMP_MAP" > "${TEMP_ALL}.active_sids"
    sort -u -o "${TEMP_ALL}.active_sids" "${TEMP_ALL}.active_sids"

    while IFS='|' read -r old_sid old_type old_str; do
        # 跳过已在当前扫描中的活跃条目
        if grep -q "^${old_sid}$" "${TEMP_ALL}.active_sids" 2>/dev/null; then
            continue
        fi

        # 检查旧 .LANG.h 中的状态
        _old_st=$(awk -F'|' -v s="$old_sid" '$1==s {print $3; exit}' "$TEMP_OLD_ENUM_STATUS")

        if [ "$_old_st" = "remove" ]; then
            # 用户已确认删除 — debug 模式留空洞（_LA_N），release 模式直接移除
            # 不加入 TEMP_ENUM_DATA，在枚举中自然成为 _LA_N 空洞
            continue
        fi

        # 标记为 disabled（保留 ID + 字符串，等待宏重新启用）
        id_name="LA_${old_type}${old_sid}"
        str_out="$old_str"
        # 如果是 F 类型且不含 %，需要保留 _fmt_ensure_prefix 的前缀
        if [ "$old_type" = "F" ]; then
            str_out=$(_fmt_ensure_prefix "$old_str")
        fi
        printf '%s|%s|%s|%s||%s|disabled\n' "$old_type" "$id_name" "$old_sid" "$str_out" "" >> "$TEMP_ENUM_DATA"
        [ "$old_sid" -gt "$max_sid" ] && max_sid=$old_sid
        _disabled_count=$((_disabled_count + 1))
    done < "$TEMP_OLD_SID_MAP"
    rm -f "${TEMP_ALL}.active_sids"
fi

# ======================================================================
# Phase 2: 生成 .LANG.h
# ======================================================================
#
# --ndebug (Release): 枚举按类型分组连续编号，数组紧凑无空洞
# 默认 (Debug):       枚举按 SID 顺序排列，空洞用占位符填充
#                     增删条目不改变已有项的 ID，避免源文件大面积 diff 污染

cat > "$OUTPUT_H" <<'EOF'
/*
 * 自动生成的语言 ID 枚举（由 i18n.sh 生成）
 *
 * 除「remove 操作」外请勿手动编辑，重新生成会覆盖所有改动。
 *
 * 条目状态:
 *   (无标记)  — active:   正常使用中，源文件中有对应的 LA_W/S/F 调用
 *   disabled  — disabled: 源文件扫描中未出现（如在未激活的 #ifdef 分支内），
 *                         ID 和字符串保留，宏重新启用后自动恢复为 active
 *   remove    — remove:   用户确认永久删除，下次生成时:
 *                           Debug  模式 → 该位置变为 _LA_N 占位空洞
 *                           Release 模式 → 该条目被完全移除
 *
 * 状态流转:
 *   active ──(扫描消失)──→ disabled ──(扫描重现)──→ active
 *                              │
 *                     (用户手动改为 remove)
 *                              ↓
 *                           remove ──(下次生成)──→ 删除
 *
 * 操作说明:
 *   若在枚举注释中看到 "disabled" 前缀，且确认该字符串不再需要，
 *   将注释中的 "disabled" 改为 "remove"，然后重新运行 i18n.sh 即可。
 *   示例:
 *     LA_F99,  // disabled "some old string"
 *     改为:
 *     LA_F99,  // remove "some old string"
 */

#ifndef LANG_H__
#define LANG_H__

#ifndef LA_PREDEFINED
#   define LA_PREDEFINED -1
#endif

EOF

if [ "$NDEBUG_MODE" -eq 1 ]; then
    # --ndebug: 按类型分组，连续编号（紧凑模式）
    # Release 模式下 disabled 和 remove 条目均被移除
    _emit_enum_grouped() {
        local _cur_type=""
        while IFS='|' read -r etype eid esid estr efiles eparams estatus; do
            # Release 模式跳过 disabled / remove 条目
            [ "$estatus" = "disabled" ] || [ "$estatus" = "remove" ] && continue
            if [ "$etype" != "$_cur_type" ]; then
                [ -n "$_cur_type" ] && echo ""
                _cur_type="$etype"
                case "$etype" in
                    W) echo "    /* Words (LA_W) */" ;;
                    S) echo "    /* Strings (LA_S) */" ;;
                    F) echo "    /* Formats (LA_F) */" ;;
                esac
            fi
            local _cmt
            if [ "$etype" = "F" ] && [ -n "$eparams" ]; then
                _cmt="/* \"$estr\" ($eparams)  [$efiles] */"
            else
                _cmt="/* \"$estr\"  [$efiles] */"
            fi
            printf '    %s,  %s\n' "$eid" "$_cmt"
        done < "$TEMP_ENUM_DATA"
    }
    {
    echo "enum {"
    echo "    LA_PRED = LA_PREDEFINED,  /* 基础 ID，后续 ID 从此开始递增 */"
    echo ""
    _emit_enum_grouped
    echo ""
    echo "    LA_NUM"
    echo "};"
    } >> "$OUTPUT_H"
else
    # Debug: 按 SID 顺序排列，空洞用占位符填充
    # disabled 条目保留 ID 但注释加 disabled 前缀
    awk -F'|' -v max_sid="$max_sid" '
    {
        sid = $3 + 0
        type[sid] = $1; eid[sid] = $2; estr[sid] = $4
        efiles[sid] = $5; eparams[sid] = $6; estatus[sid] = $7
    }
    END {
        cur_type = ""
        for (s = 1; s <= max_sid; s++) {
            if (s in type) {
                if (type[s] != cur_type) {
                    if (cur_type != "") printf "\n"
                    cur_type = type[s]
                    if (cur_type == "W") printf "    /* Words (LA_W) */\n"
                    else if (cur_type == "S") printf "    /* Strings (LA_S) */\n"
                    else if (cur_type == "F") printf "    /* Formats (LA_F) */\n"
                }
                prefix = ""
                if (estatus[s] == "disabled") prefix = "disabled "
                if (type[s] == "F" && eparams[s] != "")
                    cmt = "/* " prefix "\"" estr[s] "\" (" eparams[s] ")  [" efiles[s] "] */"
                else if (efiles[s] != "")
                    cmt = "/* " prefix "\"" estr[s] "\"  [" efiles[s] "] */"
                else
                    cmt = "/* " prefix "\"" estr[s] "\" */"
                printf "    %s,  %s\n", eid[s], cmt
            } else {
                printf "    _LA_%d,\n", s
            }
        }
    }
    ' "$TEMP_ENUM_DATA" > "${TEMP_ALL}.enum_body"
    {
    echo "enum {"
    echo "    LA_PRED = LA_PREDEFINED,  /* 基础 ID，后续 ID 从此开始递增 */"
    echo ""
    cat "${TEMP_ALL}.enum_body"
    echo ""
    echo "    LA_NUM"
    echo "};"
    } >> "$OUTPUT_H"
    rm -f "${TEMP_ALL}.enum_body"
fi

echo "" >> "$OUTPUT_H"

# 添加 LA_FMT_START（格式字符串起始位置标记）
if [ "$format_count" -gt 0 ]; then
    printf '/* 格式字符串起始位置（用于验证） */\n#define LA_FMT_START %s\n\n' "$first_fmt_id" >> "$OUTPUT_H"
else
    cat >> "$OUTPUT_H" <<'EOF'
/* 无格式字符串 */
#define LA_FMT_START LA_NUM

EOF
fi

cat >> "$OUTPUT_H" <<'EOF'
#endif /* LANG_H__ */
EOF

# 生成 .c 文件
cat > "$OUTPUT_C" <<EOF
/*
 * Auto-generated language strings
 */

#include "LANG.h"

int LA_${LA_NAME};

/* 字符串表 */
static const char* s_lang_en[LA_NUM] = {
EOF

# 提取 LANG.h 中的预定义项（如果存在）
if [ -f "$USER_LANG_H" ]; then
    # 提取枚举中 PRED_NUM 之前的项和对应的 STR_ 宏
    awk '
        BEGIN { in_enum=0; in_cmt=0; nsids=0 }
        /\/\*/ { in_cmt=1 }
        /\*\// { in_cmt=0; next }
        in_cmt { next }
        /^[[:space:]]*\/\// { next }
        /typedef[[:space:]]+enum/ { in_enum=1; next }
        in_enum && /PRED_NUM/ { in_enum=0 }
        in_enum && /SID_[A-Za-z_][A-Za-z0-9_]*/ {
            v = $0; gsub(/^[[:space:]]+/, "", v); gsub(/[[:space:]]*,.*$/, "", v)
            if (v ~ /^SID_/) sids[nsids++] = v
        }
        !in_enum && /^[[:space:]]*#[[:space:]]*define[[:space:]]+STR_/ {
            v = $0; sub(/^[[:space:]]*#[[:space:]]*define[[:space:]]+/, "", v)
            match(v, /^[A-Za-z_][A-Za-z0-9_]*/); name = substr(v, 1, RLENGTH)
            if (name != "") strs[name] = 1
        }
        END {
            for (i = 0; i < nsids; i++) {
                sid = sids[i]; str_name = sid
                sub(/^SID_/, "STR_", str_name)
                if (str_name in strs)
                    printf "    /* [%s] = %s */\n", sid, str_name
            }
        }
    ' "$USER_LANG_H" >> "$OUTPUT_C"
fi

# 词
if [ "$word_count" -gt 0 ]; then
    while IFS='|' read -r type key str files; do
        # 转义字符串（仅转义双引号；反斜杠序列如 \n 在提取时已保留为 C 原始形式，无需二次转义）
        escaped=$(printf '%s' "$str" | sed 's/"/\\"/g')
        id_name=$(_I18N_KEY="$key" awk -F'|' -v t="W" 'BEGIN{k=ENVIRON["_I18N_KEY"]} $1==t && $2==k {print $3; exit}' "$TEMP_MAP")
        entry_sid=$(_I18N_KEY="$key" awk -F'|' -v t="W" 'BEGIN{k=ENVIRON["_I18N_KEY"]} $1==t && $2==k {print $4; exit}' "$TEMP_MAP")
        printf '    [%s] = "%s",  /* SID:%s */\n' "${id_name:-LA_W0}" "$escaped" "${entry_sid:-0}" >> "$OUTPUT_C"
    done < "$TEMP_WORDS"
fi

# 字符串
if [ "$string_count" -gt 0 ]; then
    while IFS='|' read -r type key str files; do
        escaped=$(printf '%s' "$str" | sed 's/"/\\"/g')
        id_name=$(_I18N_KEY="$key" awk -F'|' -v t="S" 'BEGIN{k=ENVIRON["_I18N_KEY"]} $1==t && $2==k {print $3; exit}' "$TEMP_MAP")
        entry_sid=$(_I18N_KEY="$key" awk -F'|' -v t="S" 'BEGIN{k=ENVIRON["_I18N_KEY"]} $1==t && $2==k {print $4; exit}' "$TEMP_MAP")
        printf '    [%s] = "%s",  /* SID:%s */\n' "${id_name:-LA_S0}" "$escaped" "${entry_sid:-0}" >> "$OUTPUT_C"
    done < "$TEMP_STRINGS"
fi

# 格式化
if [ "$format_count" -gt 0 ]; then
    while IFS='|' read -r type key str files; do
        # 如果 LA_F 字符串不包含 % 则添加 "% " 前缀
        str_out=$(_fmt_ensure_prefix "$str")
        escaped=$(printf '%s' "$str_out" | sed 's/"/\\"/g')
        id_name=$(_I18N_KEY="$key" awk -F'|' -v t="F" 'BEGIN{k=ENVIRON["_I18N_KEY"]} $1==t && $2==k {print $3; exit}' "$TEMP_MAP")
        entry_sid=$(_I18N_KEY="$key" awk -F'|' -v t="F" 'BEGIN{k=ENVIRON["_I18N_KEY"]} $1==t && $2==k {print $4; exit}' "$TEMP_MAP")
        printf '    [%s] = "%s",  /* SID:%s */\n' "${id_name:-LA_F0}" "$escaped" "${entry_sid:-0}" >> "$OUTPUT_C"
    done < "$TEMP_FORMATS"
fi

# disabled 条目（保留字符串以便宏重新启用时直接可用）
if [ "$_disabled_count" -gt 0 ]; then
    awk -F'|' '$7 == "disabled" {
        id = $2; sid = $3; str = $4
        # 转义双引号
        gsub(/"/, "\\\"", str)
        printf "    [%s] = \"%s\",  /* SID:%s disabled */\n", id, str, sid
    }' "$TEMP_ENUM_DATA" >> "$OUTPUT_C"
fi

cat >> "$OUTPUT_C" <<EOF
};

/* 语言初始化函数（自动生成，请勿修改）*/
void LA_${LA_NAME}_init(void) {
    LA_RID = lang_def(s_lang_en, sizeof(s_lang_en) / sizeof(s_lang_en[0]), LA_FMT_START);
}
EOF

# 生成 lang.en 文本文件（仅在指定 --export 选项时）
if [ "$EXPORT_LANG_EN" -eq 1 ]; then
    OUTPUT_LANG_EN="$SOURCE_DIR/lang.en"
    cat > "$OUTPUT_LANG_EN" <<'EOF'
# Language Table (one string per line)
# Use this file as a template for other language translations
# Line number corresponds to string ID (starting from 0)
# Lines starting with '#' are comments
# Note: No blank lines allowed between comments and the string table
EOF

    # 如果有预定义项，先提取其值
    if [ -f "$USER_LANG_H" ]; then
        awk '
            BEGIN { in_enum=0; in_cmt=0; nsids=0 }
            /\/\*/ { in_cmt=1 }
            /\*\// { in_cmt=0; next }
            in_cmt { next }
            /^[[:space:]]*\/\// { next }
            /typedef[[:space:]]+enum/ { in_enum=1; next }
            in_enum && /PRED_NUM/ { in_enum=0 }
            in_enum && /SID_[A-Za-z_][A-Za-z0-9_]*/ {
                v = $0; gsub(/^[[:space:]]+/, "", v); gsub(/[[:space:]]*,.*$/, "", v)
                if (v ~ /^SID_/) sids[nsids++] = v
            }
            !in_enum && /^[[:space:]]*#[[:space:]]*define[[:space:]]+STR_/ {
                v = $0; sub(/^[[:space:]]*#[[:space:]]*define[[:space:]]+/, "", v)
                match(v, /^[A-Za-z_][A-Za-z0-9_]*/); name = substr(v, 1, RLENGTH)
                rest = substr(v, RLENGTH+1); gsub(/^[[:space:]]+/, "", rest)
                if (substr(rest,1,1) == "\"") {
                    val = ""; k = 2
                    while (k <= length(rest)) {
                        c = substr(rest,k,1)
                        if (c == "\\") {
                            nc = substr(rest,k+1,1)
                            if      (nc == "n")  { val = val "\n"; k+=2 }
                            else if (nc == "t")  { val = val "\t"; k+=2 }
                            else if (nc == "\"") { val = val "\""; k+=2 }
                            else if (nc == "\\") { val = val "\\"; k+=2 }
                            else                 { val = val nc;   k+=2 }
                        } else if (c == "\"") { break }
                        else { val = val c; k++ }
                    }
                    strs[name] = val
                }
            }
            END {
                for (i = 0; i < nsids; i++) {
                    sid = sids[i]; str_name = sid
                    sub(/^SID_/, "STR_", str_name)
                    if (str_name in strs) print strs[str_name]
                }
            }
        ' "$USER_LANG_H" >> "$OUTPUT_LANG_EN"
    fi

    # 输出自动提取的字符串（按 W, S, F 顺序）
    if [ "$word_count" -gt 0 ]; then
        while IFS='|' read -r type key str files; do
            printf '%s\n' "$str" >> "$OUTPUT_LANG_EN"
        done < "$TEMP_WORDS"
    fi

    if [ "$string_count" -gt 0 ]; then
        while IFS='|' read -r type key str files; do
            printf '%s\n' "$str" >> "$OUTPUT_LANG_EN"
        done < "$TEMP_STRINGS"
    fi

    if [ "$format_count" -gt 0 ]; then
        while IFS='|' read -r type key str files; do
            # 如果 LA_F 字符串不包含 % 则添加 "% " 前缀
            str_out=$(_fmt_ensure_prefix "$str")
            printf '%s\n' "$str_out" >> "$OUTPUT_LANG_EN"
        done < "$TEMP_FORMATS"
    fi
fi

# 生成 LANG.${SUFFIX}.h 内嵌语言表头文件（仅在指定 --import 选项时）
# 从 .LANG.c 读取已有字符串作为翻译模板
if [ -n "$IMPORT_SUFFIX" ]; then
    OUTPUT_IMPORT_H="$SOURCE_DIR/LANG.$IMPORT_SUFFIX.h"
    
    # 仅在 reinit 时备份（SID 已稳定追踪变更，正常运行无需 .bak）
    if [ -f "$OUTPUT_IMPORT_H" ] && [ "$I18N_REINIT" -eq 1 ]; then
        BACKUP_FILE="${OUTPUT_IMPORT_H}.bak"
        cp "$OUTPUT_IMPORT_H" "$BACKUP_FILE"
        echo "Backed up existing file (reinit): $BACKUP_FILE"
    fi

    # 解析旧 import 文件：建立 SID → 旧译文 映射
    # 格式：    [LA_Xx] = "译文",  /* SID:N */  或  /* UPDATED [SID:N] ... */
    #           [_LA_N] = "译文",  /* SID:N invalid */  （失效条目）
    : > "$TEMP_OLD_IMPORT_MAP"
    TEMP_EN_TRANS_MAP=$(mktemp)  # 额外：英文 → 翻译 映射
    : > "$TEMP_EN_TRANS_MAP"
    if [ -f "$OUTPUT_IMPORT_H" ]; then
        awk '
        /\[_?LA_[WSF]?[0-9]+\]/ {
            line = $0
            # 提取 SID
            entry_sid = ""
            idx = index(line, "SID:")
            if (idx > 0) {
                rest = substr(line, idx + 4)
                for (ci = 1; ci <= length(rest); ci++) {
                    ch = substr(rest, ci, 1)
                    if (ch ~ /[0-9]/) entry_sid = entry_sid ch
                    else break
                }
            }
            if (entry_sid == "" || entry_sid + 0 == 0) next
            # 提取译文内容（] = "…"）
            val = line; sub(/.*\] = "/, "", val)
            result = ""
            for (ci = 1; ci <= length(val); ci++) {
                ch = substr(val, ci, 1)
                if (ch == "\\") { result = result ch substr(val, ci+1, 1); ci++ }
                else if (ch == "\"") break
                else result = result ch
            }
            print entry_sid "|" result
        }
        ' "$OUTPUT_IMPORT_H" > "$TEMP_OLD_IMPORT_MAP" 2>/dev/null || true
        # 构建 英文→翻译 映射（结合 TEMP_OLD_SID_MAP 和 TEMP_OLD_IMPORT_MAP）
        # 无论英文和翻译是否相同都保留（用于 SID 变更时的内容匹配）
        awk -F'|' '
        NR==FNR { sid_en[$1]=$3; next }  # 第一文件: SID→英文（字段: SID|TYPE|string）
        { sid=$1; trans=$2; en=sid_en[sid]; if(en!="") print en"|"trans }
        ' "$TEMP_OLD_SID_MAP" "$TEMP_OLD_IMPORT_MAP" > "$TEMP_EN_TRANS_MAP" 2>/dev/null || true
    fi

    # 生成头文件头部
    cat > "$OUTPUT_IMPORT_H" <<EOF
/*
 * Auto-generated language strings
 */

#include "LANG.h"

/* Embedded ${IMPORT_SUFFIX} language table */
static const char* s_lang_${IMPORT_SUFFIX}[LA_NUM] = {
EOF

    # 三种情况:
    # 1. 新增条目（TEMP_OLD_IMPORT_MAP 中无此 SID）→ 写英文占位 + /* SID:N new */
    # 2. 进入变更（英文内容变了）→ 保留旧译文 + /* UPDATED [SID:N] en: "new" */
    # 3. 未变或无旧英文记录→ 保留旧译文 + /* SID:N */
    _new_count=0; _updated_count=0

    _import_loop() {
        local _type="$1" _key="$2" _escaped="$3"
        local _id_name _entry_sid _old_translation _old_english
        _id_name=$(_I18N_KEY="$_key" awk -F'|' -v t="$_type" 'BEGIN{k=ENVIRON["_I18N_KEY"]} $1==t && $2==k {print $3; exit}' "$TEMP_MAP")
        _entry_sid=$(_I18N_KEY="$_key" awk -F'|' -v t="$_type" 'BEGIN{k=ENVIRON["_I18N_KEY"]} $1==t && $2==k {print $4; exit}' "$TEMP_MAP")
        _old_translation=$(awk -F'|' -v s="${_entry_sid:-0}" '$1==s {print $2; exit}' "$TEMP_OLD_IMPORT_MAP")
        _old_english=$(awk -F'|' -v s="${_entry_sid:-0}" '$1==s {print $3; exit}' "$TEMP_OLD_SID_MAP")
        # 如果按 SID 找不到旧翻译，尝试按英文内容查找（处理 ID 变更情况）
        if [ -z "${_old_translation:-}" ]; then
            _old_translation=$(_I18N_ESC="$_escaped" awk -F'|' 'BEGIN{e=ENVIRON["_I18N_ESC"]} $1==e {print $2; exit}' "$TEMP_EN_TRANS_MAP")
        fi
        if [ -z "${_old_translation:-}" ]; then
            # 新增条目
            printf '    [%s] = "%s",  /* SID:%s new */\n' \
                "${_id_name}" "$_escaped" "${_entry_sid:-0}" >> "$OUTPUT_IMPORT_H"
            _new_count=$((_new_count + 1))
        elif [ -n "${_old_english:-}" ] && [ "$_old_english" != "$_escaped" ]; then
            # 英文内容已变更，保留旧译文并标记 UPDATED
            printf '    [%s] = "%s",  /* [SID:%s] UPDATED new: "%s" */\n' \
                "${_id_name}" "$_old_translation" "${_entry_sid:-0}" "$_escaped" >> "$OUTPUT_IMPORT_H"
            _updated_count=$((_updated_count + 1))
        else
            # 未变更
            printf '    [%s] = "%s",  /* SID:%s */\n' \
                "${_id_name}" "$_old_translation" "${_entry_sid:-0}" >> "$OUTPUT_IMPORT_H"
        fi
    }

    # 词
    if [ "$word_count" -gt 0 ]; then
        while IFS='|' read -r type key str files; do
            escaped=$(printf '%s' "$str" | sed 's/"/\\"/g')
            _import_loop "W" "$key" "$escaped"
        done < "$TEMP_WORDS"
    fi

    # 字符串
    if [ "$string_count" -gt 0 ]; then
        while IFS='|' read -r type key str files; do
            escaped=$(printf '%s' "$str" | sed 's/"/\\"/g')
            _import_loop "S" "$key" "$escaped"
        done < "$TEMP_STRINGS"
    fi

    # 格式化
    if [ "$format_count" -gt 0 ]; then
        while IFS='|' read -r type key str files; do
            # 如果 LA_F 字符串不包含 % 则添加 "% " 前缀
            str_out=$(_fmt_ensure_prefix "$str")
            escaped=$(printf '%s' "$str_out" | sed 's/"/\\"/g')
            _import_loop "F" "$key" "$escaped"
        done < "$TEMP_FORMATS"
    fi

    # Trickle 模式：disabled 条目以真实 ID 保留（.cn.h 无状态标记）
    #              remove 条目仅 debug 模式保留为 _LA_N 空洞
    _disabled_import_count=0
    _remove_count=0
    if [ "$_disabled_count" -gt 0 ]; then
        while IFS='|' read -r d_type d_id d_sid d_str _d5 _d6 d_status; do
            [ "$d_status" != "disabled" ] && continue
            d_trans=$(awk -F'|' -v s="$d_sid" '$1==s {print $2; exit}' "$TEMP_OLD_IMPORT_MAP")
            d_escaped=$(printf '%s' "$d_str" | sed 's/"/\\"/g')
            if [ -z "$d_trans" ]; then
                printf '    [%s] = "%s",  /* SID:%s new */\n' "$d_id" "$d_escaped" "$d_sid" >> "$OUTPUT_IMPORT_H"
                _new_count=$((_new_count + 1))
            else
                printf '    [%s] = "%s",  /* SID:%s */\n' "$d_id" "$d_trans" "$d_sid" >> "$OUTPUT_IMPORT_H"
            fi
            _disabled_import_count=$((_disabled_import_count + 1))
        done < "$TEMP_ENUM_DATA"
    fi
    if [ "$NDEBUG_MODE" -ne 1 ] && [ -s "$TEMP_OLD_ENUM_STATUS" ]; then
        # debug 模式：remove 条目保留为 _LA_N 空洞（保留旧翻译供参考）
        while IFS='|' read -r r_sid _r_type r_status; do
            [ "$r_status" != "remove" ] && continue
            # 若该 SID 在本次扫描中重新出现（已恢复为 active），跳过
            awk -F'|' -v s="$r_sid" '$3==s {found=1; exit} END{exit !found}' "$TEMP_ENUM_DATA" && continue
            r_trans=$(awk -F'|' -v s="$r_sid" '$1==s {print $2; exit}' "$TEMP_OLD_IMPORT_MAP")
            [ -z "$r_trans" ] && continue
            printf '    [_LA_%s] = "%s",  /* SID:%s remove */\n' "$r_sid" "$r_trans" "$r_sid" >> "$OUTPUT_IMPORT_H"
            _remove_count=$((_remove_count + 1))
        done < "$TEMP_OLD_ENUM_STATUS"
    fi

    # 生成尾部
    cat >> "$OUTPUT_IMPORT_H" <<EOF
};

static inline int lang_${IMPORT_SUFFIX}(void) {
    return lang_load(LA_RID, s_lang_${IMPORT_SUFFIX}, LA_NUM);
}
EOF
    [ "$_new_count" -gt 0 ]     && echo "  NOTE: $_new_count new string(s) added as English placeholders (marked /* new */)"
    [ "$_updated_count" -gt 0 ] && echo "  NOTE: $_updated_count string(s) English changed — old translation kept, marked /* [SID:N] UPDATED new: ... */"
    [ "$_disabled_import_count" -gt 0 ] && echo "  NOTE: $_disabled_import_count disabled string(s) preserved (trickle mode)"
    [ "$_remove_count" -gt 0 ]  && echo "  NOTE: $_remove_count removed string(s) kept as _LA_N placeholder"
fi

echo "Generated:"
echo "  $OUTPUT_H ($sid IDs)"
echo "  $OUTPUT_C"
if [ "$EXPORT_LANG_EN" -eq 1 ]; then
    echo "  $OUTPUT_LANG_EN"
fi
if [ -n "$IMPORT_SUFFIX" ]; then
    echo "  $OUTPUT_IMPORT_H"
fi
echo

# 回写源文件，替换 ID
echo "Updating source files..."
find "$SOURCE_DIR" -name "*.c" -o -name "*.h" | while read -r file; do
    # 跳过生成的文件
    if [ "$file" = "$OUTPUT_H" ] || [ "$file" = "$OUTPUT_C" ]; then
        continue
    fi
    
    # 使用 awk 扫描替换 LA_W/S/F 中的 ID
    _i18n_tmp=$(mktemp)
    awk -v mapfile="$TEMP_LINE_MAP" -v curfile="$file" '
        BEGIN {
            while ((getline ln < mapfile) > 0) {
                n = split(ln, a, "|");
                if (n >= 6) {
                    k = a[1] SUBSEP a[2] SUBSEP a[3] SUBSEP a[4]
                    mapn[k] = a[5]
                    mapsid[k] = a[6]
                }
            }
            close(mapfile)
        }
        {
            line = $0; result = ""; i = 1; L = length(line)
            delete type_occ
            while (i <= L) {
                if (substr(line,i,3) == "LA_") {
                    t = substr(line,i+3,1)
                    skip = 4  # 正常情况跳过 "LA_X"
                    # 处理 LA_CW, LA_CS, LA_CF 别名
                    if (t == "C") {
                        t2 = substr(line,i+4,1)
                        if (t2 == "W" || t2 == "S" || t2 == "F") {
                            t = t2
                            skip = 5  # 跳过 "LA_CX"
                        }
                    }
                    if (t == "W" || t == "S" || t == "F") {
                        j = i+skip
                        while (j <= L && substr(line,j,1) ~ /[ \t]/) j++
                        if (j <= L && substr(line,j,1) == "(") {
                            type_occ[t]++
                            mapk = curfile SUBSEP FNR SUBSEP t SUBSEP type_occ[t]
                            new_id = mapn[mapk]
                            new_sid = mapsid[mapk]
                            if (new_id == "") {
                                result = result substr(line,i,1)
                                i++
                                continue
                            }
                            j++
                            while (j <= L && substr(line,j,1) ~ /[ \t]/) j++
                            # Skip optional unicode string prefix: u" L" U" u8"
                            ch = substr(line,j,1)
                            if (ch == "u" || ch == "L" || ch == "U") {
                                if (ch == "u" && substr(line,j+1,1) == "8" && substr(line,j+2,1) == "\"") j += 2
                                else if (substr(line,j+1,1) == "\"") j += 1
                            }
                            # TODO: 当前只支持第一个参数以字符串字面量开头的情况。
                            # 如果第一个参数是带括号的宏调用（如 LA_F(CONCAT("a","b"), ID, SID)），
                            # 需要改用括号深度+字符串追踪来跳过，而不是假设以 " 开头。
                            # 目前这种用法会被跳过不处理。
                            if (j <= L && substr(line,j,1) == "\"") {
                                sv = ""; k = j+1
                                while (k <= L) {
                                    c = substr(line,k,1)
                                    if (c == "\\") { sv = sv c substr(line,k+1,1); k+=2 }
                                    else if (c == "\"") break
                                    else { sv = sv c; k++ }
                                }
                                if (substr(line,k,1) == "\"") {
                                    eq = k; k = eq+1
                                    while (k <= L && substr(line,k,1) ~ /[ \t]/) k++
                                    if (k <= L && substr(line,k,1) == ",") {
                                        k++
                                        while (k <= L && substr(line,k,1) ~ /[ \t]/) k++
                                        id0 = k
                                        while (k <= L && substr(line,k,1) ~ /[A-Za-z0-9_]/) k++
                                        if (new_id == "") {
                                            result = result substr(line,i,1)
                                            i++
                                            continue
                                        }
                                        result = result substr(line,i,id0-i) new_id
                                        if (new_sid != "") {
                                            result = result ", " new_sid
                                            # skip existing numeric 3rd arg if present
                                            k2 = k
                                            while (k2 <= L && substr(line,k2,1) ~ /[ \t]/) k2++
                                            if (k2 <= L && substr(line,k2,1) == ",") {
                                                k3 = k2+1
                                                while (k3 <= L && substr(line,k3,1) ~ /[ \t]/) k3++
                                                if (k3 <= L && substr(line,k3,1) ~ /[0-9]/) {
                                                    while (k3 <= L && substr(line,k3,1) ~ /[0-9]/) k3++
                                                    k = k3
                                                }
                                            }
                                        }
                                        i = k; continue
                                    }

                                    # 处理多字面量首参数: "..." PRIu64 "..." ... , id, sid
                                    kk = k
                                    ok = 0
                                    while (kk <= L) {
                                        while (kk <= L && substr(line,kk,1) ~ /[ \t]/) kk++
                                        if (kk <= L && substr(line,kk,1) == ",") { ok = 1; break }

                                        # 跳过中间宏名（如 PRIu64）
                                        if (kk <= L && substr(line,kk,1) ~ /[A-Za-z_]/) {
                                            while (kk <= L && substr(line,kk,1) ~ /[A-Za-z0-9_]/) kk++
                                            while (kk <= L && substr(line,kk,1) ~ /[ \t]/) kk++
                                            continue  # 回到循环顶部重新检查逗号
                                        }

                                        # 跳过可选字符串前缀
                                        cpk = substr(line,kk,1)
                                        if ((cpk == "u" || cpk == "L" || cpk == "U") && kk+1 <= L) {
                                            if (cpk == "u" && substr(line,kk+1,1) == "8" && kk+2 <= L && substr(line,kk+2,1) == "\"") kk += 2
                                            else if (substr(line,kk+1,1) == "\"") kk += 1
                                        }

                                        # 读取下一个字符串片段
                                        if (kk <= L && substr(line,kk,1) == "\"") {
                                            kk++
                                            while (kk <= L) {
                                                cc = substr(line,kk,1)
                                                if (cc == "\\") kk += 2
                                                else if (cc == "\"") { kk++; break }
                                                else kk++
                                            }
                                        } else {
                                            break
                                        }
                                    }

                                    if (ok == 1) {
                                        k = kk + 1
                                        while (k <= L && substr(line,k,1) ~ /[ \t]/) k++
                                        id0 = k
                                        while (k <= L && substr(line,k,1) ~ /[A-Za-z0-9_]/) k++
                                        if (new_id == "") {
                                            result = result substr(line,i,1)
                                            i++
                                            continue
                                        }
                                        result = result substr(line,i,id0-i) new_id
                                        if (new_sid != "") {
                                            result = result ", " new_sid
                                            # skip existing numeric 3rd arg if present
                                            k2 = k
                                            while (k2 <= L && substr(line,k2,1) ~ /[ \t]/) k2++
                                            if (k2 <= L && substr(line,k2,1) == ",") {
                                                k3 = k2+1
                                                while (k3 <= L && substr(line,k3,1) ~ /[ \t]/) k3++
                                                if (k3 <= L && substr(line,k3,1) ~ /[0-9]/) {
                                                    while (k3 <= L && substr(line,k3,1) ~ /[0-9]/) k3++
                                                    k = k3
                                                }
                                            }
                                        }
                                        i = k; continue
                                    }
                                }
                            }
                        }
                    }
                }
                result = result substr(line,i,1); i++
            }
            print result
        }
    ' "$file" > "$_i18n_tmp" && mv "$_i18n_tmp" "$file" && echo "  Updated: $file"
    rm -f "$_i18n_tmp"
done

echo
echo "Done! Source files updated with correct LA_W/F/Sxxx IDs"
echo "Next: Rebuild with updated LANG.c"

# 保存 SID_NEXT 和 LA_NAME 到 .i18n 文件（始终写入）
# reinit 时不做 max 提升，正常模式下推至已提取的最大 SID+1 防止冲突
if [ "$I18N_REINIT" -eq 0 ] && [ "$max_sid" -ge "$SID_NEXT" ] 2>/dev/null; then
    SID_NEXT=$((max_sid + 1))
fi
{
    printf 'SID_NEXT=%d\n' "$SID_NEXT"
    printf 'LA_NAME=%s\n' "$LA_NAME"
} > "$I18N_FILE"
if [ "$SID_NEXT" -gt "$SID_NEXT_START" ]; then
    echo "Updated $I18N_FILE: SID_NEXT=$SID_NEXT, LA_NAME=$LA_NAME (allocated $((SID_NEXT - SID_NEXT_START)) new IDs)"
else
    echo "Updated $I18N_FILE: SID_NEXT=$SID_NEXT, LA_NAME=$LA_NAME (no new IDs allocated)"
fi
