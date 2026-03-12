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
    echo "Usage: $0 <source_dir> [--ndebug] [--export] [--import SUFFIX]"
    echo "Example: $0 p2p_ping"
    echo "Options:"
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
else
    I18N_REINIT=1
    echo "Note: $I18N_FILE not found — reinitializing all SIDs from 1"
fi
[ -z "${SID_NEXT:-}" ] && SID_NEXT=1
SID_NEXT_START=$SID_NEXT

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

#include <i18n.h>

typedef enum {
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

/* 语言初始化函数（自动生成，请勿修改）*/
static inline void lang_init(void) {
    lang_def(lang_en, sizeof(lang_en) / sizeof(lang_en[0]), LA_FMT_START);
}

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
              "$TEMP_OLD_SID_MAP" "$TEMP_OLD_IMPORT_MAP" "$TEMP_ENUM_DATA"
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
        # awk 无输出：此文件不在 compile_commands.json 中，继续走兜底逻辑
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
/* 从 variadic args 中提取 SID（第2个参数），缺省为 0 */
#define _I18N_SID_GET(_id, _sid, ...) _sid
#define _I18N_SID(...) _I18N_SID_GET(__VA_ARGS__, 0, 0)
#ifndef LA_W
#define LA_W(WD, ...) _I18NW_ WD _I18NSID_ _I18N_SID(__VA_ARGS__) _I18NW_END_
#endif
#ifndef LA_S
#define LA_S(STR, ...) _I18NS_ STR _I18NSID_ _I18N_SID(__VA_ARGS__) _I18NS_END_
#endif
#ifndef LA_F
#define LA_F(FMT, ...) _I18NF_ FMT _I18NSID_ _I18N_SID(__VA_ARGS__) _I18NF_END_
#endif
MARKER_EOF

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
    awk -v base="$base" '
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

            # 在 fragment 中分离字符串部分和 SID 部分
            # 格式: <strings> _I18NSID_ <sid> （SID 由 marker 宏从源码透传）
            esid = 0
            str_frag = fragment
            if (match(fragment, /_I18NSID_/)) {
                str_frag = substr(fragment, 1, RSTART - 1)
                _sf = substr(fragment, RSTART + RLENGTH)
                gsub(/[ \t\n]/, "", _sf)
                esid = _sf + 0
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

            # 多段字符串字面量 = 含宏拼接（如 PRIu64），无法通过原始源码追踪 SID，跳过
            if (nlit > 1) { result = "" }

            if (result != "") {
                if (tp == "W") {
                    key = result; gsub(/^[ \t]+|[ \t]+$/, "", key)
                    print "W|" tolower(key) "|" key "|" base "|" esid
                } else if (tp == "S") {
                    print "S|" tolower(result) "|" result "|" base "|" esid
                } else {
                    print "F|" result "|" result "|" base "|" esid
                }
            }
        }
    }
    '; then
        echo "Warning: preprocessing failed for $file" >&2
        [ "$DEBUG_MODE" -eq 1 ] && cat "$_cc_err_tmp" >&2
    fi
    rm -f "$_cc_err_tmp"
done > "$TEMP_ALL"
rm -f "$_marker_h"

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

# 从当前（旧）.LANG.c 中提取 SID→字符串 映射（变更检测用，必须在覆写 .c 前完成）
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
        s = line; sub(/.*= "/, "", s)
        val = ""
        for (ci = 1; ci <= length(s); ci++) {
            ch = substr(s, ci, 1)
            if (ch == "\\") { val = val ch substr(s,ci+1,1); ci++ }
            else if (ch == "\"") break
            else val = val ch
        }
        if (entry_sid != "" && val != "") print entry_sid "|" val
    }
    ' "$OUTPUT_C" > "$TEMP_OLD_SID_MAP" 2>/dev/null || true
else
    : > "$TEMP_OLD_SID_MAP"
fi

# ======================================================================
# Phase 1: 收集所有条目（SID 分配 + TEMP_MAP / TEMP_ENUM_DATA）
# ======================================================================
# TEMP_MAP 格式:       TYPE|key|id_name|sid   （源文件回写用）
# TEMP_ENUM_DATA 格式: TYPE|id_name|sid|str|files_formatted[|params]
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

# ======================================================================
# Phase 2: 生成 .LANG.h
# ======================================================================
#
# --ndebug (Release): 枚举按类型分组连续编号，数组紧凑无空洞
# 默认 (Debug):       枚举按 SID 顺序排列，空洞用占位符填充
#                     增删条目不改变已有项的 ID，避免源文件大面积 diff 污染

cat > "$OUTPUT_H" <<'EOF'
/*
 * Auto-generated language IDs
 *
 * DO NOT EDIT - Regenerate with: ./i18n/i18n.sh
 */

#ifndef LANG_H__
#define LANG_H__

#ifndef LA_PREDEFINED
#   define LA_PREDEFINED -1
#endif

EOF

if [ "$NDEBUG_MODE" -eq 1 ]; then
    # --ndebug: 按类型分组，连续编号（紧凑模式）
    _emit_enum_grouped() {
        local _cur_type=""
        while IFS='|' read -r etype eid esid estr efiles eparams; do
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
    awk -F'|' -v max_sid="$max_sid" '
    {
        sid = $3 + 0
        type[sid] = $1; eid[sid] = $2; estr[sid] = $4
        efiles[sid] = $5; eparams[sid] = $6
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
                if (type[s] == "F" && eparams[s] != "")
                    cmt = "/* \"" estr[s] "\" (" eparams[s] ")  [" efiles[s] "] */"
                else
                    cmt = "/* \"" estr[s] "\"  [" efiles[s] "] */"
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
/* 字符串表 */
extern const char* lang_en[LA_NUM];

#endif /* LANG_H__ */
EOF

# 生成 .c 文件
cat > "$OUTPUT_C" <<EOF
/*
 * Auto-generated language strings
 */

#include ".LANG.h"

/* 字符串表 */
const char* lang_en[LA_NUM] = {
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

cat >> "$OUTPUT_C" <<EOF
};
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
    : > "$TEMP_OLD_IMPORT_MAP"
    if [ -f "$OUTPUT_IMPORT_H" ]; then
        awk '
        /\[LA_[WSF][0-9]+\]/ {
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
    fi

    # 生成头文件头部
    cat > "$OUTPUT_IMPORT_H" <<EOF
/*
 * Auto-generated language strings
 */

#include ".LANG.h"

/* Embedded ${IMPORT_SUFFIX} language table */
static const char* lang_${IMPORT_SUFFIX}[LA_NUM] = {
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
        _old_english=$(awk -F'|' -v s="${_entry_sid:-0}" '$1==s {print $2; exit}' "$TEMP_OLD_SID_MAP")
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

    # 生成尾部
    cat >> "$OUTPUT_IMPORT_H" <<EOF
};
EOF
    [ "$_new_count" -gt 0 ]     && echo "  NOTE: $_new_count new string(s) added as English placeholders (marked /* new */)"
    [ "$_updated_count" -gt 0 ] && echo "  NOTE: $_updated_count string(s) English changed — old translation kept, marked /* [SID:N] UPDATED new: ... */"
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
    awk -v mapfile="$TEMP_MAP" '
        BEGIN {
            while ((getline ln < mapfile) > 0) {
                n = split(ln, a, "|");
                if (n >= 3) mapn[a[1] SUBSEP a[2]] = a[3]
                if (n >= 4) mapsid[a[1] SUBSEP a[2]] = a[4]
            }
            close(mapfile)
        }
        {
            line = $0; result = ""; i = 1; L = length(line)
            while (i <= L) {
                if (substr(line,i,3) == "LA_") {
                    t = substr(line,i+3,1)
                    if (t == "W" || t == "S" || t == "F") {
                        j = i+4
                        while (j <= L && substr(line,j,1) ~ /[ \t]/) j++
                        if (j <= L && substr(line,j,1) == "(") {
                            j++
                            while (j <= L && substr(line,j,1) ~ /[ \t]/) j++
                            # Skip optional unicode string prefix: u" L" U" u8"
                            ch = substr(line,j,1)
                            if (ch == "u" || ch == "L" || ch == "U") {
                                if (ch == "u" && substr(line,j+1,1) == "8" && substr(line,j+2,1) == "\"") j += 2
                                else if (substr(line,j+1,1) == "\"") j += 1
                            }
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
                                        kv = sv
                                        if (t == "W") { gsub(/^[ \t]+|[ \t]+$/, "", kv); kv = tolower(kv) }
                                        else if (t == "S") kv = tolower(kv)
                                        new_id  = mapn[t SUBSEP kv]
                                        new_sid = mapsid[t SUBSEP kv]
                                        if (new_id != "") {
                                            result = result substr(line,i,eq-i+1) substr(line,eq+1,id0-eq-1) new_id
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
                                    # String literal concatenation (e.g. "..." PRIu64 "...")
                                    # — cannot track SID through raw source; force-reset to 0, 0
                                    else if (k <= L && substr(line,k,1) ~ /[A-Za-z_]/) {
                                        _cdone = 0
                                        _ck = k
                                        while (!_cdone && _ck <= L) {
                                            while (_ck <= L && substr(line,_ck,1) ~ /[A-Za-z0-9_]/) _ck++
                                            while (_ck <= L && substr(line,_ck,1) ~ /[ \t]/) _ck++
                                            if (_ck <= L && substr(line,_ck,1) == "\"") {
                                                _ck++
                                                while (_ck <= L) {
                                                    _cc = substr(line,_ck,1)
                                                    if (_cc == "\\") _ck += 2
                                                    else if (_cc == "\"") { _ck++; break }
                                                    else _ck++
                                                }
                                                while (_ck <= L && substr(line,_ck,1) ~ /[ \t]/) _ck++
                                                if (_ck <= L && substr(line,_ck,1) == ",") _cdone = 1
                                            } else break
                                        }
                                        if (_cdone) {
                                            _ck++
                                            while (_ck <= L && substr(line,_ck,1) ~ /[ \t]/) _ck++
                                            _cid0 = _ck
                                            while (_ck <= L && substr(line,_ck,1) ~ /[A-Za-z0-9_]/) _ck++
                                            result = result substr(line, i, _cid0 - i) "0"
                                            _ck2 = _ck
                                            while (_ck2 <= L && substr(line,_ck2,1) ~ /[ \t]/) _ck2++
                                            if (_ck2 <= L && substr(line,_ck2,1) == ",") {
                                                _ck3 = _ck2 + 1
                                                while (_ck3 <= L && substr(line,_ck3,1) ~ /[ \t]/) _ck3++
                                                if (_ck3 <= L && substr(line,_ck3,1) ~ /[0-9]/) {
                                                    while (_ck3 <= L && substr(line,_ck3,1) ~ /[0-9]/) _ck3++
                                                    result = result ", 0"
                                                    _ck = _ck3
                                                }
                                            }
                                            i = _ck; continue
                                        }
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

# 保存 SID_NEXT 到 .i18n 文件（始终写入）
# reinit 时不做 max 提升，正常模式下推至已提取的最大 SID+1 防止冲突
if [ "$I18N_REINIT" -eq 0 ] && [ "$max_sid" -ge "$SID_NEXT" ] 2>/dev/null; then
    SID_NEXT=$((max_sid + 1))
fi
printf 'SID_NEXT=%d\n' "$SID_NEXT" > "$I18N_FILE"
if [ "$SID_NEXT" -gt "$SID_NEXT_START" ]; then
    echo "Updated $I18N_FILE: SID_NEXT=$SID_NEXT (allocated $((SID_NEXT - SID_NEXT_START)) new IDs)"
else
    echo "Updated $I18N_FILE: SID_NEXT=$SID_NEXT (no new IDs allocated)"
fi
