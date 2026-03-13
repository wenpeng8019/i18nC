/*
 * hello.c -- i18n Hello World example & self-test
 *
 * Serves two purposes:
 *   1. Usage example  -- shows LA_W / LA_S / LA_F macros in context
 *   2. Unit tests     -- covers literal mode, i18n mode, lang_load_tx,
 *                        static embedded translation, format-spec validation
 *
 * Three build modes (driven by Makefile):
 *   hello       -- literal mode: macros return English strings directly,
 *                  no i18n.c linked (zero-dependency demo)
 *   hello-i18n  -- I18N mode: lang_str() looks up table at runtime
 *   hello-cn    -- I18N + embedded Chinese: loads s_lang_cn[] from LANG.cn.h
 *
 * Toolchain role (see test.sh):
 *   i18n.sh test           -- scan this file, generate .LANG.h / .LANG.c / .i18n
 *   i18n.sh test --import cn -- generate/maintain LANG.cn.h (3-case logic)
 *
 * Macro parameter notes:
 *   LA_W("str", LA_Wn, SID)  2nd arg: array enum index  3rd arg: stable SID
 *   LA_S("str", LA_Sn, SID)  both are auto-maintained by i18n.sh
 *   LA_F("fmt", LA_Fn, SID)  format args passed separately at call site
 *
 * NOTE: 2nd and 3rd args are written back by i18n.sh.
 *       Run "make gen" before the first build.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>

#ifdef I18N_ENABLED
/*
 * LANG.h includes:
 *   - .LANG.h  (auto-generated enum LA_W0..LA_NUM)
 *   - lang_init() helper that calls lang_def() to register the English table
 */
#  include "LANG.h"

/* Optional: embed a static translation (defined when building hello-cn) */
#  ifdef USE_CN
#    include "LANG.cn.h"   /* provides: static const char* s_lang_cn[LA_NUM] and lang_cn() */
#  endif
#else
/* Literal mode: only the base header is needed; macros expand to string literals */
#  include "../i18n.h"
#endif

/* ============================================================================
 * String annotations
 * 2nd and 3rd parameters (LA_Wn / SID) are auto-maintained by i18n.sh.
 * ============================================================================ */

/* LA_W -- status words (single words or very short tokens) */
#define W_ERROR  LA_W("ERROR",  LA_W1, 1)
#define W_FAIL   LA_W("FAIL",   LA_W2, 2)
#define W_OK     LA_W("OK",     LA_W3, 3)
#define W_PASS   LA_W("PASS",   LA_W4, 4)
#define W_READY  LA_W("READY",  LA_W5, 5)

/* Wide/Unicode string prefix tests (u"", L"", U"", u8"") */
#define W_UTF16  LA_W(u"UTF16",  LA_W6, 6)
#define W_WIDE   LA_W(L"WIDE",   LA_W8, 8)
#define W_UTF32  LA_W(U"UTF32",  LA_W7, 7)

/* LA_S -- complete sentences */
#define S_ALL_PASS  LA_S("All tests passed.",  LA_S9, 9)
#define S_HELLO     LA_S("Hello, World!",      LA_S10, 10)
#define S_SOME_FAIL LA_S("Some tests FAILED.", LA_S11, 11)
#define S_WELCOME   LA_S("Welcome to i18n.",   LA_S13, 13)
#define S_UTF8      LA_S(u8"UTF-8 String",     LA_S12, 12)

/* LA_F -- printf format strings (variadic args passed at the call site)
 * Example:  printf(F_RESULT, W_PASS, "test name")
 *           printf(F_COUNT, 42)                       */
#define F_RESULT  LA_F("  [%s] %s\n",    LA_F14, 14)
#define F_LANG    LA_F("Language: %s\n", LA_F15, 15)
#define F_COUNT   LA_F("Tests run: %d\n",LA_F16, 16)

/* LA_F without % -- i18n.sh should auto-add "% " prefix in generated code */
#define F_PLAIN   LA_F("hello world",    LA_F17, 17)

/* Deduplication tests -- these should merge to existing IDs */
#define W_OK_DUP1   LA_W("OK",    LA_W3, 3)  /* Should merge to LA_W3 (same as W_OK) */
#define W_OK_DUP2   LA_W("ok",    LA_W3, 3)  /* LA_W trims+lowercase: ok -> OK -> LA_W3 */
#define W_OK_DUP3   LA_W(" OK ",  LA_W3, 3)  /* Trim spaces -> OK -> LA_W3 */
#define S_HELLO_DUP LA_S("Hello, World!", LA_S10, 10)  /* Should merge to LA_S7 (same as S_HELLO) */

/* ============================================================================
 * Minimal test framework
 * ============================================================================ */

static int g_pass = 0, g_fail = 0;

#define CHECK(desc, expr) do {                           \
    if (expr) {                                          \
        printf(F_RESULT, W_PASS, desc);  g_pass++;      \
    } else {                                             \
        printf(F_RESULT, W_FAIL, desc);  g_fail++;      \
    }                                                    \
} while (0)

/* ============================================================================
 * Test 1 -- literal content
 * Literal mode: macros equal the English string directly.
 * I18N mode   : macros call lang_str(); verify against default English table.
 * ============================================================================ */
static void test_literals(void)
{
    printf("\n[Test 1] literal / default-language content\n");

#ifndef I18N_ENABLED
    /* Literal mode: direct strcmp */
    CHECK("W_OK    == \"OK\"",           strcmp(W_OK,     "OK")            == 0);
    CHECK("W_ERROR == \"ERROR\"",        strcmp(W_ERROR,  "ERROR")         == 0);
    CHECK("W_PASS  == \"PASS\"",         strcmp(W_PASS,   "PASS")          == 0);
    CHECK("W_FAIL  == \"FAIL\"",         strcmp(W_FAIL,   "FAIL")          == 0);
#ifdef W_READY
    CHECK("W_READY == \"READY\"",        strcmp(W_READY,  "READY")         == 0);
#endif
    CHECK("S_HELLO == \"Hello, World!\"",strcmp(S_HELLO,  "Hello, World!") == 0);
    CHECK("S_WELCOME contains i18n",     strstr(S_WELCOME,"i18n") != NULL);
    CHECK("F_RESULT contains %s",        strstr(F_RESULT, "%s")   != NULL);
    CHECK("F_COUNT  contains %d",        strstr(F_COUNT,  "%d")   != NULL);
    CHECK("F_PLAIN == \"hello world\"",  strcmp(F_PLAIN,  "hello world") == 0);
#else
    /* I18N mode: lang_init() called in main(); verify non-empty and English */
    CHECK("W_OK    non-empty",  W_OK[0]     != '\0');
    CHECK("W_ERROR non-empty",  W_ERROR[0]  != '\0');
    CHECK("S_HELLO non-empty",  S_HELLO[0]  != '\0');
    CHECK("F_RESULT has %%s",   strstr(F_RESULT, "%s")  != NULL);
    CHECK("F_COUNT  has %%d",   strstr(F_COUNT,  "%d")  != NULL);
    CHECK("W_OK    == \"OK\"",  strcmp(W_OK,    "OK")              == 0);
    CHECK("S_HELLO == \"Hello, World!\"",
                                strcmp(S_HELLO, "Hello, World!")   == 0);
    /* LA_F without % should have "% " prefix added by i18n.sh */
    CHECK("F_PLAIN == \"% hello world\"", strcmp(F_PLAIN, "% hello world") == 0);
#endif

    /* Wide/Unicode string prefix tests (u"", L"", U"", u8"") */
    CHECK("W_UTF16 non-empty",  W_UTF16[0] != '\0');
    CHECK("W_WIDE  non-empty",  W_WIDE[0]  != '\0');
    CHECK("W_UTF32 non-empty",  W_UTF32[0] != '\0');
    CHECK("S_UTF8  non-empty",  S_UTF8[0]  != '\0');

#ifdef I18N_ENABLED
    /* Deduplication tests -- verify merged IDs point to same strings
     * (Only in I18N mode: i18n.sh merges "ok"/"OK"/" OK " to same LA_W2.
     *  Literal mode keeps them as separate string literals.) */
    CHECK("W_OK_DUP1 == W_OK",  strcmp(W_OK_DUP1, W_OK)    == 0);
    CHECK("W_OK_DUP2 == W_OK",  strcmp(W_OK_DUP2, W_OK)    == 0);
    CHECK("W_OK_DUP3 == W_OK",  strcmp(W_OK_DUP3, W_OK)    == 0);
    CHECK("S_HELLO_DUP == S_HELLO", strcmp(S_HELLO_DUP, S_HELLO) == 0);
#endif
}

/* ============================================================================
 * Test 2 -- lang_load_tx (I18N mode only)
 * Load a Chinese translation from an in-memory text block and verify it.
 * String order must exactly match .LANG.c s_lang_en[]:
 *   W1..W8  (ERROR, FAIL, OK, PASS, READY, UTF16, UTF32, WIDE)
 *   S9..S13 (All tests passed, Hello World, Some tests FAILED, UTF-8 String, Welcome to i18n)
 *   F14..F17 (RESULT, LANG, COUNT, PLAIN)
 * Format strings must keep identical specifiers or lang_load_tx rejects them.
 * ============================================================================ */
#ifdef I18N_ENABLED
static void test_load_tx(void)
{
    printf("\n[Test 2] lang_load_tx (inline Chinese)\n");

    /* UTF-8 Chinese translation text (hex-escaped to keep source ASCII) */
    const char *cn_tx =
        "\xe9\x94\x99\xe8\xaf\xaf\n"                   /* W1: ERROR */
        "\xe5\xa4\xb1\xe8\xb4\xa5\n"                   /* W2: FAIL  */
        "\xe7\xa1\xae\xe5\xae\x9a\n"                   /* W3: OK    */
        "\xe9\x80\x9a\xe8\xbf\x87\n"                   /* W4: PASS  */
        "\xe5\xb0\xb1\xe7\xbb\xaa\n"                   /* W5: READY */
        "UTF16\n"                                      /* W6: UTF16 */
        "UTF32\n"                                      /* W7: UTF32 */
        "WIDE\n"                                       /* W8: WIDE  */
        "\xe5\x85\xa8\xe9\x83\xa8\xe6\xb5\x8b\xe8\xaf\x95\xe9\x80\x9a\xe8\xbf\x87\xe3\x80\x82\n"  /* S9: All tests passed */
        "\xe4\xbd\xa0\xe5\xa5\xbd\xef\xbc\x8c\xe4\xb8\x96\xe7\x95\x8c\xef\xbc\x81\n"              /* S10: Hello, World! */
        "\xe9\x83\xa8\xe5\x88\x86\xe6\xb5\x8b\xe8\xaf\x95\xe5\xa4\xb1\xe8\xb4\xa5\xe3\x80\x82\n" /* S11: Some tests FAILED */
        "UTF-8 String\n"                               /* S12: UTF-8 String */
        "\xe6\xac\xa2\xe8\xbf\x8e\xe4\xbd\xbf\xe7\x94\xa8\xe5\x9b\xbd\xe9\x99\x85\xe5\x8c\x96\xe3\x80\x82\n" /* S13: Welcome to i18n */
        "  [%s] %s\n"              /* F14: RESULT -- keep specifiers identical */
        "\xe8\xaf\xad\xe8\xa8\x80: %s\n"               /* F15: LANG   */
        "\xe5\xb7\xb2\xe8\xbf\x90\xe8\xa1\x8c: %d\n"   /* F16: COUNT  */
        "% hello world\n";                             /* F17: PLAIN -- no format specs */

    int ok = lang_load_tx(LA_RID, cn_tx);
    CHECK("lang_load_tx succeeds",                ok == 0);
    /* After loading CN, W_OK must differ from "OK" */
    CHECK("W_OK != \"OK\" after CN load",  strcmp(W_OK, "OK") != 0);
    CHECK("W_OK  non-empty after CN load",  W_OK[0]           != '\0');
    CHECK("F_COUNT still has %%d",          strstr(F_COUNT, "%d") != NULL);

    /* Bad format spec (%d -> %s) -- must be rejected */
    const char *bad_tx =
        "e1\nf2\ng3\nh4\ni5\n"
        "UTF16\nUTF32\nWIDE\n"
        "all-pass\nhello\nsome-fail\nUTF-8\nwelcome\n"
        "  [%s] %s\n"
        "lang: %s\n"
        "count: %s\n"   /* wrong: %d -> %s */
        "% hello world\n";  /* 17 entries matching LA_NUM */
    int bad_ok = lang_load_tx(LA_RID, bad_tx);
    CHECK("bad format spec rejected", bad_ok != 0);

    /* Restore English table */
    lang_reset(LA_RID);
    CHECK("after reload: W_OK == \"OK\"", strcmp(W_OK, "OK") == 0);
}
#endif  /* I18N_ENABLED */

/* ============================================================================
 * Test 3 -- static embedded s_lang_cn[] (USE_CN build only)
 * ============================================================================ */
#if defined(I18N_ENABLED) && defined(USE_CN)
static void test_static_cn(void)
{
    printf("\n[Test 3] static embedded s_lang_cn[]\n");

    int ok = lang_cn();  /* calls lang_load(LA_RID, s_lang_cn, LA_NUM) */
    CHECK("lang_cn() succeeds",          ok == 0);
    CHECK("W_OK  != \"OK\" in CN mode",   strcmp(W_OK, "OK")       != 0);
    CHECK("W_OK  non-empty",              W_OK[0]                  != '\0');
    CHECK("S_HELLO != English",           strcmp(S_HELLO, "Hello, World!") != 0);
    CHECK("F_COUNT has %%d",              strstr(F_COUNT, "%d")    != NULL);

    /* Restore English */
    lang_reset(LA_RID);
    CHECK("restored: W_OK == \"OK\"",     strcmp(W_OK, "OK")        == 0);
}
#endif

/* ============================================================================
 * main
 * ============================================================================ */
int main(void)
{
    /* Initialize i18n runtime before any string is used */
#ifdef I18N_ENABLED
    LA_init();    /* register lang_en[] as the default English table */
#endif

    /* Demo greeting */
    printf("%s\n", S_HELLO);
    printf("%s\n", S_WELCOME);
    printf(F_LANG,
#ifdef I18N_ENABLED
#  ifdef USE_CN
        "zh (embedded)"
#  else
        "en (i18n mode)"
#  endif
#else
        "en (literal)"
#endif
    );

    /* ---- Self-tests ---- */
    test_literals();

#ifdef I18N_ENABLED
    test_load_tx();
#endif

#if defined(I18N_ENABLED) && defined(USE_CN)
    test_static_cn();
#endif

    /* Summary */
    printf("\n");
    printf(F_COUNT, g_pass + g_fail);
    if (g_fail == 0) {
        printf("%s\n", S_ALL_PASS);
    } else {
        printf("%s (%d failed)\n", S_SOME_FAIL, g_fail);
    }

    return (g_fail == 0) ? 0 : 1;
}
