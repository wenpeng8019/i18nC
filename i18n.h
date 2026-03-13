/*
 * 多语言国际化支持 - 通用头文件
 */
#ifndef LANG_H
#define LANG_H

#include <stdio.h>

/* 多语言宏定义
 * 使用 #ifndef 保护，允许构建系统（如 i18n.sh）在命令行预先注入自定义定义
 * LA_RID 由各项目的 .LANG.h 定义，用于索引该项目的语言表实例 */
#ifdef I18N_ENABLED
#   ifndef LA_W
#       define LA_W(WD, ID, ...) lang_str(LA_RID, ID)
#   endif
#   ifndef LA_S
#       define LA_S(STR, ID, ...) lang_str(LA_RID, ID)
#   endif
#   ifndef LA_F
#       define LA_F(FMT, ID, ...) lang_str(LA_RID, ID)
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

const char* lang_str(int la_id, unsigned s_id);

/* lang_cstr: 将常量 ID 转换为字符串（仅在定义了 LA_RID 时可用）*/
#ifdef LA_RID
static inline const char* lang_cstr(const char* cs_id) {
#   ifdef I18N_ENABLED
    return lang_str(LA_RID, (unsigned)(uintptr_t)cs_id);
#   else
    return cs_id;
#   endif
}
#endif

/* 注册默认语言表，返回 la_id（>=0）或 -1（失败） */
int lang_def(const char* lang_table[], size_t num_lines, size_t format_start);

/* 加载翻译表到指定实例，返回 0（成功）或 -1（失败） */
int lang_load(int la_id, const char* lang_table[], size_t num_lines);
int lang_load_tx(int la_id, const char* text);
int lang_load_fp(int la_id, FILE *fp);

#endif /* LANG_H */
