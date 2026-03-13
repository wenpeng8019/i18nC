#!/usr/bin/env bash
# i18n/test/test.sh — 集成测试脚本
#
# 覆盖以下场景：
#   ① 初次生成（.LANG.h / .LANG.c / .i18n）
#   ② 三种构建模式均可编译并正常退出
#   ③ 幂等性（重复运行 i18n.sh 不重新分配 SID）
#   ④ --import cn 首次生成 LANG.cn.h（NOTE: N new string(s)）
#   ⑤ 填入中文翻译后可编译 hello-cn
#   ⑥ --import cn 二次运行（全部 unchanged，无 NOTE）
#   ⑦ UPDATED 检测（修改一条字符串后 SID 不变，翻译文件出现 UPDATED 注释）
#   ⑧ 恢复后再次幂等

set -euo pipefail

# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
I18N_DIR="$(cd .. && pwd)"          # i18n/ 根目录（i18n.sh 所在位置）
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"  # i18n/test/ 目录

cd "$TEST_DIR"

ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

check()          { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
check_contains() { local desc="$1" pat="$2" file="$3"; if grep -q "$pat" "$file" 2>/dev/null; then ok "$desc"; else fail "$desc"; fi; }
check_file()     { local desc="$1" file="$2"; if [ -f "$file" ]; then ok "$desc"; else fail "$desc"; fi; }
check_not_found(){ local desc="$1" pat="$2" file="$3"; if ! grep -q "$pat" "$file" 2>/dev/null; then ok "$desc"; else fail "$desc"; fi; }

die() { echo "FATAL: $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 准备：清除所有生成产物
# ---------------------------------------------------------------------------
echo "=== [SETUP] Clean generated files ==="
rm -f hello hello-i18n hello-cn .LANG.h .LANG.c .i18n LANG.cn.h hello.c.bak lang.en
# LANG.h is auto-created by i18n.sh on first run; remove it here to test the full flow
rm -f LANG.h

# ---------------------------------------------------------------------------
# 阶段 1 — 初次 gen
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 1] First-time gen ==="
(cd "$I18N_DIR" && bash i18n.sh test --name hello)

check_file ".LANG.h generated"   ".LANG.h"
check_file ".LANG.c generated"   ".LANG.c"
check_file ".i18n generated"     ".i18n"
check_file "LANG.h auto-created" "LANG.h"
check_contains "LA_NUM defined"  "LA_NUM"    ".LANG.h"
check_contains "lang_en defined" "lang_en"   ".LANG.c"
check_contains "SID_NEXT in .i18n" "SID_NEXT" ".i18n"
# Expected: 8W (5 unique + 3 wide) + 6S (5 unique + 1 utf8) + 4F (3+1 plain) = 18 strings → SID_NEXT=19
# Dedup (W_OK_DUP*, S_HELLO_DUP) merge to existing IDs, don't allocate new SIDs.
check_contains "SID_NEXT=19"     "SID_NEXT=19" ".i18n"
check_contains "LA_FMT_START in .LANG.h" "LA_FMT_START" ".LANG.h"

# ---------------------------------------------------------------------------
# 阶段 2 — 三种构建模式
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 2] Build all three modes ==="

echo "  Building: hello (literal) ..."
make -s hello
check "hello builds"           test -x hello
echo "  Running:  hello ..."
./hello
check "hello exits 0"          ./hello

echo "  Building: hello-i18n ..."
make -s hello-i18n
check "hello-i18n builds"      test -x hello-i18n
echo "  Running:  hello-i18n ..."
./hello-i18n
check "hello-i18n exits 0"     ./hello-i18n

# hello-cn 需要 LANG.cn.h，先跳过，稍后再建

# ---------------------------------------------------------------------------
# 阶段 3 — 幂等性（重复运行 gen，SID_NEXT 不变）
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 3] Idempotency (re-run gen) ==="
NEXT_BEFORE=$(grep SID_NEXT .i18n | head -1)
(cd "$I18N_DIR" && bash i18n.sh test --name hello) > /tmp/i18n_gen2.log 2>&1
NEXT_AFTER=$(grep SID_NEXT .i18n | head -1)
if [ "$NEXT_BEFORE" = "$NEXT_AFTER" ]; then
    ok "SID_NEXT unchanged after re-run"
else
    fail "SID_NEXT changed: $NEXT_BEFORE -> $NEXT_AFTER"
fi
# 第二次应无 "NOTE: N new" 输出
check_not_found "no new SIDs allocated" "NOTE:.*new" /tmp/i18n_gen2.log

# ---------------------------------------------------------------------------
# 阶段 3b — --ndebug 模式（紧凑顺序 ID）
#   验证 --ndebug 生成的 .LANG.h 无 _LA_ gap 占位符，ID 紧凑连续，
#   三种构建模式均可编译运行。最后恢复默认（debug）模式。
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 3b] --ndebug mode (compact sequential IDs) ==="

# 保存 debug 模式产物
cp .LANG.h .LANG.h.debug
cp .LANG.c .LANG.c.debug

(cd "$I18N_DIR" && bash i18n.sh test --name hello --ndebug) > /tmp/i18n_ndebug.log 2>&1

check_file ".LANG.h exists after --ndebug"   ".LANG.h"
check_file ".LANG.c exists after --ndebug"   ".LANG.c"
check_not_found "no _LA_ gap fillers"        "_LA_[0-9]" .LANG.h
check_contains  "LA_NUM in ndebug .LANG.h"   "LA_NUM"    .LANG.h
check_contains  "lang_en in ndebug .LANG.c"  "lang_en"   .LANG.c

# Count enum members: ndebug should have exactly the real entries, no gaps
NDEBUG_NUM=$(grep -c 'LA_[WSF][0-9]' .LANG.h || true)
DEBUG_NUM=$(grep -c 'LA_[WSF][0-9]' .LANG.h.debug || true)
# ndebug count <= debug count (debug has gap placeholders, ndebug doesn't)
if [ "$NDEBUG_NUM" -le "$DEBUG_NUM" ]; then
    ok "ndebug enum count ($NDEBUG_NUM) <= debug enum count ($DEBUG_NUM)"
else
    fail "ndebug enum count ($NDEBUG_NUM) > debug enum count ($DEBUG_NUM)"
fi

# Build all three modes with ndebug-generated files
echo "  Building: hello (literal, ndebug gen) ..."
make -s hello
check "hello builds (ndebug)"       test -x hello
check "hello runs (ndebug)"         ./hello

echo "  Building: hello-i18n (ndebug gen) ..."
make -s hello-i18n
check "hello-i18n builds (ndebug)"  test -x hello-i18n
check "hello-i18n runs (ndebug)"    ./hello-i18n

# 恢复 debug 模式产物（后续阶段使用 SID-based IDs）
mv .LANG.h.debug .LANG.h
mv .LANG.c.debug .LANG.c
echo "  Restored debug-mode .LANG.h/.LANG.c"

# ---------------------------------------------------------------------------
# 阶段 4 — --import cn 首次生成 LANG.cn.h
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 4] First --import cn (all new) ==="
(cd "$I18N_DIR" && bash i18n.sh test --name hello --import cn) > /tmp/i18n_import1.log 2>&1

check_file "LANG.cn.h created"           "LANG.cn.h"
# 应报告 18 条新字符串（8W + 6S + 4F）
check_contains "NOTE: 18 new" "NOTE: 18 new" /tmp/i18n_import1.log
# 新条目含 "/* SID:N new */" 注释
check_contains "new comment in LANG.cn.h" "new \*/" LANG.cn.h

# ---------------------------------------------------------------------------
# 阶段 5 — 填入中文翻译并构建 hello-cn
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 5] Inject Chinese translations and build hello-cn ==="

inject_cn() {
    local file="LANG.cn.h"
    # Inject Chinese translations by SID number.
    # IMPORTANT: this script must be valid UTF-8 (it contains Chinese literals).
    # Format strings use \\n (two chars) so they compile as C newline escapes.
    python3 - "$file" <<'PYEOF'
import re, sys

# Chinese translation table indexed by SID.
# Format strings (SID 15-18) use "\\n" (two chars) as the C escape sequence.
# SID allocation (18 strings): W1-W8 (1-8), S9-S14 (9-14), F15-F18 (15-18)
translations = {
    1:  "\u9519\u8bef",           # W_ERROR: 错误
    2:  "\u5931\u8d25",           # W_FAIL:  失败
    3:  "\u786e\u5b9a",           # W_OK:    确定
    4:  "\u901a\u8fc7",           # W_PASS:  通过
    5:  "\u5c31\u7eea",           # W_READY: 就绪
    6:  "UTF16",                  # W_UTF16 (English placeholder)
    7:  "UTF32",                  # W_UTF32
    8:  "WIDE",                   # W_WIDE
    9:  "\u5168\u90e8\u6d4b\u8bd5\u901a\u8fc7\u3002",         # S_ALL_PASS: 全部测试通过。
    10: "\u4f60\u597d\uff0c\u4e16\u754c\uff01",               # S_HELLO:    你好，世界！
    11: "\u7b2c\u4e00\u884c\\n\u7b2c\u4e8c\u884c\\t\u7ed3\u675f",  # S_ESCAPE: 第一行\n第二行\t结束
    12: "\u90e8\u5206\u6d4b\u8bd5\u5931\u8d25\u3002",         # S_SOME_FAIL:部分测试失败。
    13: "UTF-8 \u5b57\u7b26\u4e32",   # S_UTF8:     UTF-8 字符串
    14: "\u6b22\u8fce\u4f7f\u7528\u56fd\u9645\u5316\u3002",   # S_WELCOME:  欢迎使用国际化。
    15: "  [%s] %s\\n",           # F_RESULT: keep specifiers (\\n = backslash-n in C)
    16: "\u8bed\u8a00: %s\\n",    # F_LANG:   语言: %s\n
    17: "\u5df2\u8fd0\u884c\u6d4b\u8bd5: %d\\n",  # F_COUNT: 已运行测试: %d\n
    18: "% hello world",          # F_PLAIN:  no change (no format specifiers)
}

def repl2(m):
    key  = m.group(1)
    sid  = int(m.group(2) or m.group(3))
    tr   = translations.get(sid)
    if tr is None:
        return m.group(0)
    # Escape only double quotes; backslash sequences are already correct C escapes.
    tr_e = tr.replace('"', '\\"')
    return f'    {key} = "{tr_e}",  /* SID:{sid} */'

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    content = f.read()

content = re.sub(
    r'    (\[LA_[WSF]\d+\]) = (?:NULL|"(?:[^"\\]|\\.)*"),\s+/\* (?:\[SID:(\d+)\] UPDATED new: "(?:[^"\\]|\\.)*"|SID:(\d+)(?:\s+new)?) \*/',
    repl2, content
)

with open(sys.argv[1], 'w', encoding='utf-8') as f:
    f.write(content)
print("  Translations injected.")
PYEOF
}

inject_cn
check_contains "Chinese in LANG.cn.h (你好)" "你好" LANG.cn.h

echo "  Building: hello-cn ..."
make -s hello-cn
check "hello-cn builds"    test -x hello-cn
echo "  Running:  hello-cn ..."
./hello-cn
check "hello-cn exits 0"   ./hello-cn

# ---------------------------------------------------------------------------
# 阶段 6 — --import cn 二次运行：无变化（全 unchanged）
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 6] Second --import cn (unchanged, no NOTE) ==="
(cd "$I18N_DIR" && bash i18n.sh test --name hello --import cn) > /tmp/i18n_import2.log 2>&1
check_not_found "no NOTE in second import"        "NOTE:.*new"     /tmp/i18n_import2.log
check_not_found "no UPDATED in second import"     "UPDATED"        /tmp/i18n_import2.log
# 翻译保持不变（中文仍在）
check_contains  "Chinese preserved after re-import" "你好" LANG.cn.h

# ---------------------------------------------------------------------------
# Stage 7 -- UPDATED detection
#   Modify one string in the source; the i18n.sh --import should detect
#   that SID 7 ("Hello, World!") changed and mark it UPDATED.
#
#   IMPORTANT: gen overwrites .LANG.c before --import reads old_sid_map.
#   Correct order:
#     a) --import cn records current .LANG.c entries as "old english" baseline
#     b) Make the source change
#     c) Run gen  (rewrites .LANG.c with "Hello, World!!")
#     d) Run --import cn  (reads NEW .LANG.c — "Hello, World!!" — vs old baseline)
#        Wait, that still compares new vs new.
#
#   Actually the correct sequence is:
#     a) Source is at "Hello, World!" with translations injected
#     b) Run --import cn once more to establish a "clean" old_import_map baseline
#     c) Change source to "Hello, World!!"
#     d) Run gen (updates .LANG.c to "Hello, World!!")
#     e) Run --import cn: reads old .LANG.cn.h (SID 7 = 你好) as old_translation,
#        reads .LANG.c (SID 7 = "Hello, World!!") as new english,
#        reads old_sid_map from .LANG.c *before* overwrite... wait:
#
#   The key insight: gen UPDATES .LANG.c. --import reads .LANG.c AFTER gen.
#   But TEMP_OLD_SID_MAP is built from .LANG.c at the START of --import,
#   before .LANG.c is overwritten. So running --import (which includes gen)
#   in one pass means old_sid_map = old .LANG.c, new extraction = new source.
#   But gen is a *separate* script run.
#
#   Correct procedure:
#     1. cp .LANG.c .LANG.c.snapshot   (save old english)
#     2. Change source to "Hello, World!!"
#     3. Run gen  (updates .LANG.c)
#     4. cp .LANG.c.snapshot .LANG.c   (restore old, so --import sees old english)
#     5. Run --import cn               (detects old="Hello, World!" vs new="Hello, World!!")
#     ... But that's too invasive.
#
#   SIMPLEST correct approach: run "bash i18n.sh test --name hello --import cn" which
#   internally does gen + import in one pass. In that case:
#     - TEMP_OLD_SID_MAP is built from .LANG.c BEFORE this run overwrites it
#     - Then gen extracts "Hello, World!!" from source
#     - Then .LANG.c is rewritten with "Hello, World!!"
#     - Then _import_loop compares old_sid_map ("Hello, World!") vs new escape ("Hello, World!!")
#   That works! i18n.sh already does gen + import in ONE run (no separate gen step).
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 7] UPDATED detection ==="
cp hello.c hello.c.bak
sed -i.tmp 's/LA_S("Hello, World!",/LA_S("Hello, World!!",/' hello.c
rm -f hello.c.tmp

# Run gen+import in a single call (i18n.sh does gen internally, then import)
(cd "$I18N_DIR" && bash i18n.sh test --name hello --import cn) > /tmp/i18n_import3.log 2>&1

check_contains "UPDATED in LANG.cn.h"            "UPDATED"           LANG.cn.h
check_contains "UPDATED shows new eng"            "Hello, World!!"    LANG.cn.h
check_contains "old CN preserved in UPDATED line" $(printf '\xe4\xbd\xa0\xe5\xa5\xbd') LANG.cn.h

echo "  INFO: LANG.cn.h UPDATED entry:"
grep UPDATED LANG.cn.h || true

# ---------------------------------------------------------------------------
# Stage 8 -- Restore and settle
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 8] Restore and settle ==="
mv hello.c.bak hello.c
# Single combined gen+import run -- UPDATED entry will appear for SID 7 again
# since we reverted "Hello, World!!" back to "Hello, World!" but the .LANG.c
# saved "Hello, World!!" as the baseline. Run gen+import twice to settle.
(cd "$I18N_DIR" && bash i18n.sh test --name hello --import cn) > /dev/null 2>&1
# Update translations (UPDATED entry may have NULL -- inject again)
inject_cn
(cd "$I18N_DIR" && bash i18n.sh test --name hello --import cn) > /tmp/i18n_settle.log 2>&1
check_not_found "UPDATED gone after restore+settle" "UPDATED" LANG.cn.h
check_contains  "Chinese restored after settle"     $(printf '\xe4\xbd\xa0\xe5\xa5\xbd') LANG.cn.h
check_not_found "no NOTE after settle" "NOTE:.*new" /tmp/i18n_settle.log

# ---------------------------------------------------------------------------
# Stage 9 -- String deletion → disabled (trickle mode)
#   Remove one string definition from source; verify:
#     - SID_NEXT stays at 18 (no SID reclamation)
#     - .LANG.h retains LA_W5 with "disabled" prefix in comment
#     - .LANG.c retains the string with "disabled" comment
#     - LANG.cn.h preserves the entry (disabled, real ID)
#     - Other SIDs remain unchanged
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 9] String deletion → disabled (trickle mode) ==="
cp hello.c hello.c.stage9.bak

# Delete W_READY (originally SID 5)
sed -i.tmp '/^#define W_READY/d' hello.c
rm -f hello.c.tmp

SID_NEXT_BEFORE=$(grep SID_NEXT .i18n | head -1)

# Run gen+import
(cd "$I18N_DIR" && bash i18n.sh test --name hello --import cn) > /tmp/i18n_delete.log 2>&1

SID_NEXT_AFTER=$(grep SID_NEXT .i18n | head -1)

check "SID_NEXT unchanged after deletion" test "$SID_NEXT_BEFORE" = "$SID_NEXT_AFTER"
# Trickle mode: LA_W5 stays in .LANG.h with disabled prefix
check_contains  "LA_W5 still in .LANG.h"          "LA_W5"        .LANG.h
check_contains  "disabled in .LANG.h comment"      "disabled"     .LANG.h
check_contains  "READY still in .LANG.c (disabled)" "disabled"    .LANG.c
check_contains  "LA_W5 preserved in LANG.cn.h"     "LA_W5"       LANG.cn.h
check_contains  "disabled import count"             "disabled string" /tmp/i18n_delete.log

echo "  INFO: Disabled entries:"
grep "disabled" .LANG.h || echo "    (none)"

# Restore
mv hello.c.stage9.bak hello.c
(cd "$I18N_DIR" && bash i18n.sh test --name hello --import cn) > /dev/null 2>&1
inject_cn  # Restore Chinese translations

# ---------------------------------------------------------------------------
# Stage 10 -- --ndebug + Chinese (compact IDs with import-cn)
#   Verify --ndebug codegen produces valid output for translation import,
#   and that hello-cn builds and runs correctly with compact IDs.
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 10] --ndebug + Chinese (compact IDs with import-cn) ==="

# Save debug-mode products
cp .LANG.h .LANG.h.debug
cp .LANG.c .LANG.c.debug
cp LANG.cn.h LANG.cn.h.debug

# Gen with --ndebug and import cn in separate steps
(cd "$I18N_DIR" && bash i18n.sh test --name hello --ndebug) > /dev/null 2>&1
(cd "$I18N_DIR" && bash i18n.sh test --name hello --ndebug --import cn) > /tmp/i18n_ndebug_cn.log 2>&1

check_file  "LANG.cn.h exists after ndebug import"  "LANG.cn.h"
check_not_found "no _LA_ gap in ndebug .LANG.h"     "_LA_[0-9]" .LANG.h
inject_cn   # Inject Chinese into ndebug LANG.cn.h

echo "  Building: hello-cn (ndebug) ..."
make -s hello-cn
check "hello-cn builds (ndebug)"  test -x hello-cn
check "hello-cn runs (ndebug)"    ./hello-cn

# Restore debug-mode products for clean state
mv .LANG.h.debug .LANG.h
mv .LANG.c.debug .LANG.c
mv LANG.cn.h.debug LANG.cn.h
echo "  Restored debug-mode products"

# ---------------------------------------------------------------------------
# Stage 11 -- Trickle mode full lifecycle: disabled → remove → deleted
#   a) Delete W_READY → becomes "disabled"
#   b) All three builds still compile (disabled entry has valid ID)
#   c) User changes "disabled" to "remove" in .LANG.h
#   d) Re-gen → debug: _LA_5 placeholder; release: entry removed
#   e) Restore W_READY → entry reappears as active
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 11] Trickle mode full lifecycle ==="
cp hello.c hello.c.stage11.bak
cp .LANG.h .LANG.h.stage11.bak
cp .LANG.c .LANG.c.stage11.bak
cp LANG.cn.h LANG.cn.h.stage11.bak

# Step a: Delete W_READY → disabled
sed -i.tmp '/^#define W_READY/d' hello.c
rm -f hello.c.tmp

(cd "$I18N_DIR" && bash i18n.sh test --name hello --import cn) > /tmp/i18n_trickle_a.log 2>&1

check_contains  "11a: LA_W5 disabled in .LANG.h" 'disabled.*READY' .LANG.h
check_contains  "11a: disabled in .LANG.c"        'disabled'        .LANG.c

# Step b: All builds compile with disabled entry
echo "  Building: hello (literal, with disabled entry) ..."
make -s hello
check "11b: hello builds (disabled entry)"       test -x hello
check "11b: hello runs (disabled entry)"         ./hello

echo "  Building: hello-i18n (with disabled entry) ..."
make -s hello-i18n
check "11b: hello-i18n builds (disabled entry)"  test -x hello-i18n
check "11b: hello-i18n runs (disabled entry)"    ./hello-i18n

inject_cn
echo "  Building: hello-cn (with disabled entry) ..."
make -s hello-cn
check "11b: hello-cn builds (disabled entry)"    test -x hello-cn
check "11b: hello-cn runs (disabled entry)"      ./hello-cn

# Step c: User marks "disabled" → "remove" in .LANG.h
sed -i.tmp 's|/\* disabled "READY"|/* remove "READY"|' .LANG.h
rm -f .LANG.h.tmp
check_contains  "11c: remove in .LANG.h" 'remove.*READY' .LANG.h

# Step d: Re-gen in debug mode → _LA_5 placeholder
(cd "$I18N_DIR" && bash i18n.sh test --name hello --import cn) > /tmp/i18n_trickle_d.log 2>&1

check_contains  "11d: _LA_5 placeholder in .LANG.h" '_LA_5' .LANG.h
check_not_found "11d: no LA_W5 active in .LANG.h"   'LA_W5' .LANG.h
check_not_found "11d: READY removed from .LANG.c"   'READY' .LANG.c

# Step d2: Re-gen in ndebug mode → entry fully removed (no _LA_5)
cp .LANG.h .LANG.h.remove_debug
cp .LANG.c .LANG.c.remove_debug
(cd "$I18N_DIR" && bash i18n.sh test --name hello --ndebug --import cn) > /dev/null 2>&1
check_not_found "11d: no _LA_5 in ndebug .LANG.h"   '_LA_5' .LANG.h
check_not_found "11d: no READY in ndebug .LANG.h"   'READY' .LANG.h
# Restore debug products for step e
mv .LANG.h.remove_debug .LANG.h
mv .LANG.c.remove_debug .LANG.c

# Step e: Restore W_READY → entry reappears as active
mv hello.c.stage11.bak hello.c
(cd "$I18N_DIR" && bash i18n.sh test --name hello --import cn) > /tmp/i18n_trickle_e.log 2>&1

check_contains  "11e: LA_W5 active again in .LANG.h" 'LA_W5'  .LANG.h
check_not_found "11e: no disabled in .LANG.h"         'disabled.*READY' .LANG.h
check_not_found "11e: no remove in .LANG.h"           'remove.*READY'   .LANG.h
check_contains  "11e: READY back in .LANG.c"          'READY'  .LANG.c

# Settle back to clean state
inject_cn
(cd "$I18N_DIR" && bash i18n.sh test --name hello --import cn) > /dev/null 2>&1

# Restore backups
rm -f .LANG.h.stage11.bak .LANG.c.stage11.bak LANG.cn.h.stage11.bak

# ---------------------------------------------------------------------------
# Stage 12 -- Codegen content verification
#   Verify that the generated .LANG.c / .LANG.h contain expected patterns:
#     a) "% " prefix on LA_F without format specifiers
#     b) Unicode prefixes (u"", L"", U"", u8"") stripped in .LANG.c
#     c) Deduplication: only ONE "OK" entry in .LANG.c
#     d) Escape sequences preserved in .LANG.c
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 12] Codegen content verification ==="

# a) "% " prefix on format strings without format specifiers
check_contains  "12a: '% hello world' in .LANG.c"  '% hello world'   .LANG.c

# b) Unicode prefixes stripped — stored as plain strings
#    Source has u"UTF16", L"WIDE", U"UTF32", u8"UTF-8 String"
#    .LANG.c should have the string without u/L/U/u8 prefix
check_contains  "12b: UTF16 in .LANG.c"            '"UTF16"'         .LANG.c
check_contains  "12b: WIDE in .LANG.c"             '"WIDE"'          .LANG.c
check_contains  "12b: UTF32 in .LANG.c"            '"UTF32"'         .LANG.c
check_contains  "12b: UTF-8 String in .LANG.c"     '"UTF-8 String"'  .LANG.c

# c) Deduplication: only ONE occurrence of = "OK" in the string table
OK_COUNT=$(grep -c '= "OK"' .LANG.c || true)
if [ "$OK_COUNT" -eq 1 ]; then ok "12c: exactly one OK entry in .LANG.c"
else fail "12c: expected 1 OK entry, got $OK_COUNT"; fi

# d) Escape sequences preserved
check_contains  "12d: escape seq in .LANG.c" 'Line1\\nLine2\\tEnd' .LANG.c

# ---------------------------------------------------------------------------
# Stage 13 -- --export + lang_load_fp
#   a) Run --export → generates lang.en
#   b) Verify lang.en exists and has expected line count
#   c) Build hello-i18n with lang.en present → Test 4 (test_load_fp) runs
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 13] --export + lang_load_fp ==="

(cd "$I18N_DIR" && bash i18n.sh test --name hello --export) > /dev/null 2>&1
check_file      "13a: lang.en generated"         "lang.en"
check_contains  "13a: lang.en has OK"            "^OK$"  lang.en
check_contains  "13a: lang.en has Hello"         "Hello, World!"  lang.en

# Count non-comment lines (= number of exported strings)
EN_LINES=$(grep -cv '^#' lang.en || true)
if [ "$EN_LINES" -ge 18 ]; then ok "13b: lang.en has >= 18 strings ($EN_LINES)"
else fail "13b: lang.en has $EN_LINES strings, expected >= 18"; fi

echo "  Building: hello-i18n (with lang.en present) ..."
make -s hello-i18n
check "13c: hello-i18n builds"           test -x hello-i18n
./hello-i18n > /tmp/i18n_fp_test.log 2>&1
check "13c: hello-i18n exits 0"          ./hello-i18n
check_contains  "13c: Test 4 runs"       "Test 4"         /tmp/i18n_fp_test.log
check_not_found "13c: no FAIL in Test 4" "\[FAIL\].*file" /tmp/i18n_fp_test.log

rm -f lang.en

# ---------------------------------------------------------------------------
# Stage 14 -- ndebug: disabled → remove → fully removed
#   a) Delete W_READY → becomes disabled
#   b) Gen with --ndebug → disabled entries still present (can re-appear)
#   c) Mark disabled → remove, gen with --ndebug → fully removed
#   d) Restore
# ---------------------------------------------------------------------------
echo ""
echo "=== [Stage 14] ndebug disabled → remove → fully removed ==="
cp hello.c hello.c.stage14.bak
cp .LANG.h .LANG.h.stage14.bak
cp .LANG.c .LANG.c.stage14.bak
cp LANG.cn.h LANG.cn.h.stage14.bak

# a) Delete W_READY → becomes disabled
sed -i.tmp '/^#define W_READY/d' hello.c
rm -f hello.c.tmp
(cd "$I18N_DIR" && bash i18n.sh test --name hello) > /dev/null 2>&1

check_contains  "14a: disabled in debug .LANG.h"   'disabled.*READY'  .LANG.h

# b) Re-gen with --ndebug — disabled entries are kept (not removed)
(cd "$I18N_DIR" && bash i18n.sh test --name hello --ndebug) > /dev/null 2>&1

check_contains  "14b: disabled kept in ndebug .LANG.h"   'disabled'  .LANG.h
check_contains  "14b: READY kept in ndebug .LANG.c"      'READY'     .LANG.c
check_not_found "14b: no _LA_ placeholder in .LANG.h"    '_LA_[0-9]' .LANG.h

# c) Mark disabled → remove, gen with --ndebug → fully removed
# Restore debug products first (ndebug may have compacted)
(cd "$I18N_DIR" && bash i18n.sh test --name hello) > /dev/null 2>&1
sed -i.tmp 's|/\* disabled "READY"|/* remove "READY"|' .LANG.h
rm -f .LANG.h.tmp
(cd "$I18N_DIR" && bash i18n.sh test --name hello) > /dev/null 2>&1
# Now have _LA_5 placeholder; ndebug will remove it
(cd "$I18N_DIR" && bash i18n.sh test --name hello --ndebug) > /dev/null 2>&1

check_not_found "14c: no _LA_ in ndebug .LANG.h"   '_LA_[0-9]' .LANG.h
check_not_found "14c: no READY in ndebug .LANG.c"   'READY'      .LANG.c
check_not_found "14c: no disabled entry in ndebug .LANG.h" 'disabled.*READY'  .LANG.h

# d) Build still works
echo "  Building: hello (ndebug, remove entry) ..."
make -s hello
check "14d: hello builds (ndebug)"    test -x hello
check "14d: hello runs (ndebug)"      ./hello

# e) Restore
mv hello.c.stage14.bak hello.c
mv .LANG.h.stage14.bak .LANG.h
mv .LANG.c.stage14.bak .LANG.c
mv LANG.cn.h.stage14.bak LANG.cn.h

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
echo ""
echo "=================================================="
echo "Tests run:   $((PASS + FAIL))"
echo "Passed:      $PASS"
echo "Failed:      $FAIL"
echo "=================================================="

if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
else
    echo "Some tests FAILED."
    exit 1
fi
