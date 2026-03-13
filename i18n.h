/*
 * 多语言国际化支持 - 通用头文件
 */
#ifndef LANG_H
#define LANG_H

#include <stdio.h>
#include <stdbool.h>

/* 多语言宏定义
 * 使用 #ifndef 保护，允许构建系统（如 i18n.sh）在命令行预先注入自定义定义 */
#ifdef I18N_ENABLED
#   ifndef LA_W
#       define LA_W(WD, ID, ...) lang_str(ID)
#   endif
#   ifndef LA_S
#       define LA_S(STR, ID, ...) lang_str(ID)
#   endif
#   ifndef LA_F
#       define LA_F(FMT, ID, ...) lang_str(ID)
#   endif
#   ifndef LA_CW
#       define LA_CW(WD, ID, ...) ((const char*)(uintptr_t)(ID))
#   endif
#   ifndef LA_CS
#       define LA_CS(STR, ID, ...) ((const char*)(uintptr_t)(ID))
#   endif
#   ifndef LA_CF
#       define LA_CF(FMT, ID, ...) ((const char*)(uintptr_t)(ID))
#   endif
#else
#   ifndef LA_W
#       define LA_W(WD, ID, ...) WD
#   endif
#   ifndef LA_S
#       define LA_S(STR, ID, ...) STR
#   endif
#   ifndef LA_F
#       define LA_F(FMT, ID, ...) FMT
#   endif
#   ifndef LA_CW
#       define LA_CW(WD, ID, ...) WD
#   endif
#   ifndef LA_CS
#       define LA_CS(STR, ID, ...) STR
#   endif
#   ifndef LA_CF
#       define LA_CF(FMT, ID, ...) FMT
#   endif
#endif

const char* lang_str(unsigned id);

static const char* lang_cstr(const char* cs_id) {
#ifdef I18N_ENABLED
    return lang_str((unsigned)(uintptr_t)cs_id);
#else
    return cs_id;
#endif
}

bool lang_def(const char* lang_table[], size_t num_lines, size_t format_start);
bool lang_load(const char* lang_table[], size_t num_lines);
bool lang_load_tx(const char* text);
bool lang_load_fp(FILE *fp);

#endif /* LANG_H */
