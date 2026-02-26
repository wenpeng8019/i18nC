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

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <source_dir> [--export] [--import SUFFIX]"
    echo "Example: $0 p2p_ping"
    echo "Options:"
    echo "  --export          Export lang.en template file for translations"
    echo "  --import SUFFIX   Generate LANG.SUFFIX.h with embedded language table from lang.SUFFIX"
    echo "  --debug           Keep temp files in ./i18n/debug/ for inspection"
    exit 1
fi

SOURCE_DIR="$1"
EXPORT_LANG_EN=0
IMPORT_SUFFIX=""
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
    echo "Debug mode: temp files saved to $_debug_dir/"
else
    TEMP_ALL=$(mktemp)
    TEMP_WORDS=$(mktemp)
    TEMP_FORMATS=$(mktemp)
    TEMP_STRINGS=$(mktemp)
    TEMP_MAP=$(mktemp)
fi

cleanup() {
    if [ "$DEBUG_MODE" -eq 0 ]; then
        rm -f "$TEMP_ALL" "$TEMP_WORDS" "$TEMP_FORMATS" "$TEMP_STRINGS" "$TEMP_MAP"
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
#ifndef LA_W
#define LA_W(WD, ID) _I18NW_ WD _I18NW_END_
#endif
#ifndef LA_S
#define LA_S(STR, ID) _I18NS_ STR _I18NS_END_
#endif
#ifndef LA_F
#define LA_F(FMT, ...) _I18NF_ FMT _I18NF_END_
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

            # 从 fragment 中提取并拼接所有字符串字面量（含宽字符串 L"..."）
            result = ""
            fpos = 1; flen = length(fragment)
            while (fpos <= flen) {
                c1 = substr(fragment, fpos, 1)
                # 跳过 C 字符串前缀：L"..." / u"..." / U"..." / u8"..."
                if (c1 ~ /[LuU]/ && fpos+1 <= flen) {
                    nxt = substr(fragment, fpos+1, 1)
                    if (nxt == "\"") {
                        fpos++; c1 = "\""
                    } else if (c1 == "u" && nxt == "8" && fpos+2 <= flen && substr(fragment, fpos+2, 1) == "\"") {
                        fpos += 2; c1 = "\""
                    }
                }
                if (c1 == "\"") {
                    fpos++
                    while (fpos <= flen) {
                        c2 = substr(fragment, fpos, 1)
                        if (c2 == "\\") {
                            result = result substr(fragment, fpos, 2)
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

            if (result != "") {
                if (tp == "W") {
                    key = result; gsub(/^[ \t]+|[ \t]+$/, "", key)
                    print "W|" tolower(key) "|" key "|" base
                } else if (tp == "S") {
                    print "S|" tolower(result) "|" result "|" base
                } else {
                    print "F|" result "|" result "|" base
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

# 分类并聚合文件名（去重 key，合并文件列表）
grep "^W|" "$TEMP_ALL" | awk -F'|' '{
    key=$2; str=$3; file=$4;
    if (seen[key]) {
        if (index(files[key], file) == 0) files[key] = files[key] "," file;
    } else {
        seen[key]=1; strs[key]=str; files[key]=file; order[++n]=key;
    }
} END {
    for (i=1; i<=n; i++) {
        k=order[i]; print "W|" k "|" strs[k] "|" files[k];
    }
}' | LC_ALL=C sort -t'|' -k2,2 > "$TEMP_WORDS" || true

grep "^F|" "$TEMP_ALL" | awk -F'|' '{
    key=$2; str=$3; file=$4;
    if (seen[key]) {
        if (index(files[key], file) == 0) files[key] = files[key] "," file;
    } else {
        seen[key]=1; strs[key]=str; files[key]=file; order[++n]=key;
    }
} END {
    for (i=1; i<=n; i++) {
        k=order[i]; print "F|" k "|" strs[k] "|" files[k];
    }
}' | LC_ALL=C sort -t'|' -k2,2 > "$TEMP_FORMATS" || true

grep "^S|" "$TEMP_ALL" | awk -F'|' '{
    key=$2; str=$3; file=$4;
    if (seen[key]) {
        if (index(files[key], file) == 0) files[key] = files[key] "," file;
    } else {
        seen[key]=1; strs[key]=str; files[key]=file; order[++n]=key;
    }
} END {
    for (i=1; i<=n; i++) {
        k=order[i]; print "S|" k "|" strs[k] "|" files[k];
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

# 生成 .h 文件
cat > "$OUTPUT_H" <<EOF
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

enum {
    LA_PRED = LA_PREDEFINED,  /* 基础 ID，后续 ID 从此开始递增 */
    
EOF

sid=0

# 词
if [ "$word_count" -gt 0 ]; then
    echo "    /* Words (LA_W) */" >> "$OUTPUT_H"
    wid=0
    while IFS='|' read -r type key str files; do
        id_name="LA_W${wid}"
        # 将逗号分隔的文件改为逗号+空格分隔
        files_formatted=$(echo "$files" | sed 's/,/, /g')
        printf '    %s,  /* "%s"  [%s] */\n' "$id_name" "$str" "$files_formatted" >> "$OUTPUT_H"
        echo "W|$key|$id_name" >> "$TEMP_MAP"
        wid=$((wid + 1))
        sid=$((sid + 1))
    done < "$TEMP_WORDS"
    echo "" >> "$OUTPUT_H"
fi

# 字符串
if [ "$string_count" -gt 0 ]; then
    echo "    /* Strings (LA_S) */" >> "$OUTPUT_H"
    strid=0
    while IFS='|' read -r type key str files; do
        id_name="LA_S${strid}"
        files_formatted=$(echo "$files" | sed 's/,/, /g')
        printf '    %s,  /* "%s"  [%s] */\n' "$id_name" "$str" "$files_formatted" >> "$OUTPUT_H"
        echo "S|$key|$id_name" >> "$TEMP_MAP"
        strid=$((strid + 1))
        sid=$((sid + 1))
    done < "$TEMP_STRINGS"
    echo "" >> "$OUTPUT_H"
fi

# 格式化（放在最后，方便校验）
if [ "$format_count" -gt 0 ]; then
    echo "    /* Formats (LA_F) - Format strings for validation */" >> "$OUTPUT_H"
    fid=0
    while IFS='|' read -r type key str files; do
        id_name="LA_F${fid}"
        files_formatted=$(echo "$files" | sed 's/,/, /g')
        params=$(printf '%s' "$str" | grep -o '%[sdifuxXclu]' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)
        if [ -n "$params" ]; then
            printf '    %s,  /* "%s" (%s)  [%s] */\n' "$id_name" "$str" "$params" "$files_formatted" >> "$OUTPUT_H"
        else
            printf '    %s,  /* "%s"  [%s] */\n' "$id_name" "$str" "$files_formatted" >> "$OUTPUT_H"
        fi
        echo "F|$key|$id_name" >> "$TEMP_MAP"
        fid=$((fid + 1))
        sid=$((sid + 1))
    done < "$TEMP_FORMATS"
    echo "" >> "$OUTPUT_H"
fi

cat >> "$OUTPUT_H" <<EOF
    LA_NUM = $sid
};

EOF

# 添加 LA_F 定义（格式字符串起始位置标记）
if [ "$format_count" -gt 0 ]; then
    cat >> "$OUTPUT_H" <<'EOF'
/* 格式字符串起始位置（用于验证） */
#define LA_FMT_START LA_F0

EOF
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
    wid=0
    while IFS='|' read -r type key str files; do
        # 转义字符串
        escaped=$(printf '%s' "$str" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '    [LA_W%s] = "%s",\n' "$wid" "$escaped" >> "$OUTPUT_C"
        wid=$((wid + 1))
    done < "$TEMP_WORDS"
fi

# 字符串
if [ "$string_count" -gt 0 ]; then
    strid=0
    while IFS='|' read -r type key str files; do
        escaped=$(printf '%s' "$str" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '    [LA_S%s] = "%s",\n' "$strid" "$escaped" >> "$OUTPUT_C"
        strid=$((strid + 1))
    done < "$TEMP_STRINGS"
fi

# 格式化
if [ "$format_count" -gt 0 ]; then
    fid=0
    while IFS='|' read -r type key str files; do
        escaped=$(printf '%s' "$str" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '    [LA_F%s] = "%s",\n' "$fid" "$escaped" >> "$OUTPUT_C"
        fid=$((fid + 1))
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
            printf '%s\n' "$str" >> "$OUTPUT_LANG_EN"
        done < "$TEMP_FORMATS"
    fi
fi

# 生成 LANG.${SUFFIX}.h 内嵌语言表头文件（仅在指定 --import 选项时）
# 从 .LANG.c 读取已有字符串作为翻译模板
if [ -n "$IMPORT_SUFFIX" ]; then
    OUTPUT_IMPORT_H="$SOURCE_DIR/LANG.$IMPORT_SUFFIX.h"
    
    # 备份已存在的文件
    if [ -f "$OUTPUT_IMPORT_H" ]; then
        BACKUP_FILE="${OUTPUT_IMPORT_H}.bak"
        mv "$OUTPUT_IMPORT_H" "$BACKUP_FILE"
        echo "Backed up existing file: $BACKUP_FILE"
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
    
    # 从 .LANG.c 读取已生成的字符串（作为翻译模板）
    # 词
    if [ "$word_count" -gt 0 ]; then
        wid=0
        while IFS='|' read -r type key str files; do
            escaped=$(echo "$str" | sed 's/\\/\\\\/g; s/"/\\"/g')
            echo "    [LA_W${wid}] = \"$escaped\"," >> "$OUTPUT_IMPORT_H"
            wid=$((wid + 1))
        done < "$TEMP_WORDS"
    fi
    
    # 字符串
    if [ "$string_count" -gt 0 ]; then
        strid=0
        while IFS='|' read -r type key str files; do
            escaped=$(echo "$str" | sed 's/\\/\\\\/g; s/"/\\"/g')
            echo "    [LA_S${strid}] = \"$escaped\"," >> "$OUTPUT_IMPORT_H"
            strid=$((strid + 1))
        done < "$TEMP_STRINGS"
    fi
    
    # 格式化
    if [ "$format_count" -gt 0 ]; then
        fid=0
        while IFS='|' read -r type key str files; do
            escaped=$(echo "$str" | sed 's/\\/\\\\/g; s/"/\\"/g')
            echo "    [LA_F${fid}] = \"$escaped\"," >> "$OUTPUT_IMPORT_H"
            fid=$((fid + 1))
        done < "$TEMP_FORMATS"
    fi
    
    # 生成尾部
    cat >> "$OUTPUT_IMPORT_H" <<EOF
};
EOF
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
                n = split(ln, a, "|"); if (n >= 3) mapn[a[1] SUBSEP a[2]] = a[3]
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
                                        sid = mapn[t SUBSEP kv]
                                        if (sid != "") {
                                            result = result substr(line,i,eq-i+1) substr(line,eq+1,id0-eq-1) sid
                                            i = k; continue
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
