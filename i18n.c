/*
 * 多语言国际化支持 - 实现
 */

#include "i18n.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* 默认语言表（fallback） */
static const char**     g_lang_table = NULL;
static size_t           g_lang_table_size = 0;
static size_t           g_format_start = 0;  /* 格式字符串起始位置（SID_F） */

/* 加载的语言表（优先使用） */
static const char**     g_loaded_table = NULL;
static size_t           g_loaded_table_size = 0;
static bool             g_loaded_table_owned = false;  /* true = strdup'd，需要释放 */

/* 提取格式字符串中的格式符（%s, %d 等） */
static char* extract_format_specs(const char* str) {
    static char specs[256];
    int pos = 0;
    const char* p = str;
    
    specs[0] = '\0';
    while (*p && pos < 255) {
        if (*p == '%') {
            p++;
            if (*p == '%') {
                p++;  /* 跳过 %% */
                continue;
            }
            /* 跳过标志 */
            while (*p && strchr("-+ #0", *p)) p++;
            /* 跳过宽度 */
            while (*p && isdigit(*p)) p++;
            /* 跳过精度 */
            if (*p == '.') {
                p++;
                while (*p && isdigit(*p)) p++;
            }
            /* 跳过长度修饰符 */
            if (*p && strchr("hlLzjt", *p)) p++;
            if (*p && strchr("hlL", *p)) p++;  /* ll, hh */
            
            /* 记录转换说明符 */
            if (*p && strchr("diouxXfFeEgGaAcspn", *p)) {
                specs[pos++] = '%';
                specs[pos++] = *p;
                p++;
            }
        } else {
            p++;
        }
    }
    specs[pos] = '\0';
    return specs;
}

/* 比较两个字符串的格式符是否一致 */
static bool compare_format_specs(const char* str1, const char* str2) {
    char specs1_copy[256];
    char* specs1 = extract_format_specs(str1);
    strncpy(specs1_copy, specs1, sizeof(specs1_copy) - 1);
    specs1_copy[sizeof(specs1_copy) - 1] = '\0';
    
    char* specs2 = extract_format_specs(str2);
    return strcmp(specs1_copy, specs2) == 0;
}

/* 释放已加载的语言表 */
static void free_loaded_table(void) {
    if (g_loaded_table) {
        if (g_loaded_table_owned) {
            for (size_t i = 0; i < g_loaded_table_size; i++) {
                free((void*)g_loaded_table[i]);
            }
            free(g_loaded_table);
        }
        g_loaded_table = NULL;
        g_loaded_table_size = 0;
        g_loaded_table_owned = false;
    }
}

const char* lang_str(unsigned id) {
    /* 优先返回加载的语言表 */
    if (g_loaded_table && id < (unsigned)g_loaded_table_size && g_loaded_table[id]) {
        return g_loaded_table[id];
    }
    
    /* fallback 到默认语言表 */
    if (g_lang_table && id < g_lang_table_size && g_lang_table[id]) {
        return g_lang_table[id];
    }
    
    return "";
}

bool lang_def(const char* lang_table[], size_t num_lines, size_t format_start) {
    g_lang_table = lang_table;
    g_lang_table_size = num_lines;
    g_format_start = format_start;
    return true;
}

bool lang_load(const char* lang_table[], size_t num_lines) {
    if (!g_lang_table || num_lines != g_lang_table_size) {
        return false;
    }
    
    /* 校验格式字符串 */
    if (g_format_start < g_lang_table_size) {
        for (size_t i = g_format_start; i < num_lines; i++) {
            if (g_lang_table[i] && lang_table[i]) {
                if (!compare_format_specs(g_lang_table[i], lang_table[i])) {
                    return false;
                }
            }
        }
    }
    
    /* 直接引用数组，不复制（调用方负责生命周期） */
    free_loaded_table();
    g_loaded_table = (const char**)lang_table;
    g_loaded_table_size = num_lines;
    g_loaded_table_owned = false;
    return true;
}

bool lang_load_tx(const char* text) {
    if (!text) {
        return false;
    }
    
    /* 复制文本以便修改（strtok 会破坏原字符串） */
    char* buf = strdup(text);
    if (!buf) {
        return false;
    }
    
    if (!g_lang_table) {
        free(buf);
        return false;
    }
    
    /* 临时存储读取的行 */
    char** temp_table = calloc(g_lang_table_size, sizeof(char*));
    if (!temp_table) {
        free(buf);
        return false;
    }
    
    size_t line_count = 0;
    char* p = buf;
    
    while (*p) {
        /* 找到行尾 */
        char* end = p;
        while (*end && *end != '\n') end++;
        char next_char = *end;
        *end = '\0';
        
        /* 移除行尾 \r */
        size_t len = end - p;
        if (len > 0 && p[len - 1] == '\r') {
            p[--len] = '\0';
        }
        
        /* 跳过注释行和空行 */
        if (p[0] != '#' && p[0] != '\0') {
            if (line_count >= g_lang_table_size) {
                /* 行数超出 */
                for (size_t i = 0; i < line_count; i++) free(temp_table[i]);
                free(temp_table);
                free(buf);
                return false;
            }
            
            temp_table[line_count] = strdup(p);
            if (!temp_table[line_count]) {
                for (size_t i = 0; i < line_count; i++) free(temp_table[i]);
                free(temp_table);
                free(buf);
                return false;
            }
            
            /* 校验格式字符串 */
            const char* default_str = g_lang_table[line_count];
            if (default_str && g_format_start < g_lang_table_size && line_count >= g_format_start) {
                if (!compare_format_specs(default_str, temp_table[line_count])) {
                    for (size_t i = 0; i <= line_count; i++) free(temp_table[i]);
                    free(temp_table);
                    free(buf);
                    return false;
                }
            }
            
            line_count++;
        }
        
        if (!next_char) break;
        p = end + 1;
    }
    
    free(buf);
    
    /* 检查行数是否匹配 */
    if (line_count != g_lang_table_size) {
        for (size_t i = 0; i < line_count; i++) free(temp_table[i]);
        free(temp_table);
        return false;
    }
    
    free_loaded_table();
    g_loaded_table = (const char**)temp_table;
    g_loaded_table_size = line_count;
    g_loaded_table_owned = true;
    return true;
}

bool lang_load_fp(FILE *fp) {
    if (!fp || !g_lang_table) {
        return false;
    }
    
    /* 临时存储读取的行 */
    char** temp_table = calloc(g_lang_table_size, sizeof(char*));
    if (!temp_table) {
        return false;
    }
    
    char line[4096];
    size_t line_count = 0;
    
    /* 逐行读取 */
    while (fgets(line, sizeof(line), fp)) {
        /* 移除行尾换行符 */
        size_t len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) {
            line[--len] = '\0';
        }
        
        /* 跳过注释行和空行 */
        if (line[0] == '#' || line[0] == '\0') {
            continue;
        }
        
        /* 检查是否超出表大小 */
        if (line_count >= g_lang_table_size) {
            /* 行数超出，释放临时表并返回错误 */
            for (size_t i = 0; i < line_count; i++) {
                free(temp_table[i]);
            }
            free(temp_table);
            return false;
        }
        
        /* 复制字符串 */
        temp_table[line_count] = strdup(line);
        if (!temp_table[line_count]) {
            /* 内存分配失败 */
            for (size_t i = 0; i < line_count; i++) {
                free(temp_table[i]);
            }
            free(temp_table);
            return false;
        }
        
        /* 验证格式字符串（仅当 ID >= format_start 时） */
        const char* default_str = g_lang_table[line_count];
        if (default_str && g_format_start < g_lang_table_size && line_count >= g_format_start) {
            /* 该 ID 是格式字符串，校验格式符 */
            if (!compare_format_specs(default_str, temp_table[line_count])) {
                /* 格式符不匹配，释放并返回错误 */
                for (size_t i = 0; i <= line_count; i++) {
                    free(temp_table[i]);
                }
                free(temp_table);
                return false;
            }
        }
        
        line_count++;
    }
    
    /* 检查行数是否匹配 */
    if (line_count != g_lang_table_size) {
        for (size_t i = 0; i < line_count; i++) {
            free(temp_table[i]);
        }
        free(temp_table);
        return false;
    }
    
    /* 释放旧的加载表 */
    free_loaded_table();
    
    /* 设置新的加载表（lang_load_fp 的字符串是 strdup'd） */
    g_loaded_table = (const char**)temp_table;
    g_loaded_table_size = line_count;
    g_loaded_table_owned = true;
    
    return true;
}
