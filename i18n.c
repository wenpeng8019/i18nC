/*
 * 多语言国际化支持 - 实现（多实例模式）
 */

#include "i18n.h"
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* 词表实例结构 */
typedef struct {
    const char**    lang_table;         /* 默认语言表（fallback） */
    size_t          table_size;         /* 字符串数量 */
    size_t          format_start;       /* 格式字符串起始位置 */
    const char**    loaded_table;       /* 加载的语言表（优先使用） */
    size_t          loaded_table_size;
    bool            loaded_table_owned; /* true = strdup'd，需要释放 */
} lang_instance_t;

/* 动态实例数组 */
static lang_instance_t* g_instances = NULL;
static int              g_instance_count = 0;
static int              g_instance_capacity = 0;

/* 提取格式字符串中的格式符（%s, %d 等） */
static char* extract_format_specs(const char* str) {
    static char specs[256];
    int pos = 0;
    const char* p = str;
    
    specs[0] = '\0';
    
    /* 跳过 stdc print() 的 "% " 前缀（表示无格式参数的字符串） */
    if (p[0] == '%' && p[1] == ' ') {
        p += 2;
    }
    
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

/* 释放指定实例的已加载语言表 */
static void free_loaded_table(lang_instance_t* inst) {
    if (inst->loaded_table) {
        if (inst->loaded_table_owned) {
            for (size_t i = 0; i < inst->loaded_table_size; i++) {
                free((void*)inst->loaded_table[i]);
            }
            free(inst->loaded_table);
        }
        inst->loaded_table = NULL;
        inst->loaded_table_size = 0;
        inst->loaded_table_owned = false;
    }
}

/* 获取实例指针（返回 NULL 表示无效 la_id） */
static lang_instance_t* get_instance(int la_id) {
    if (la_id < 0 || la_id >= g_instance_count) {
        return NULL;
    }
    return &g_instances[la_id];
}

const char* lang_str(int la_id, unsigned id) {
    lang_instance_t* inst = get_instance(la_id);
    if (!inst) return "";
    
    /* 优先返回加载的语言表 */
    if (inst->loaded_table && id < (unsigned)inst->loaded_table_size && inst->loaded_table[id]) {
        return inst->loaded_table[id];
    }
    
    /* fallback 到默认语言表 */
    if (inst->lang_table && id < inst->table_size && inst->lang_table[id]) {
        return inst->lang_table[id];
    }
    
    return "";
}

int lang_def(const char* lang_table[], size_t num_lines, size_t format_start) {
    /* 扩容检查 */
    if (g_instance_count >= g_instance_capacity) {
        int new_cap = g_instance_capacity == 0 ? 4 : g_instance_capacity * 2;
        lang_instance_t* new_arr = realloc(g_instances, new_cap * sizeof(lang_instance_t));
        if (!new_arr) return -1;
        g_instances = new_arr;
        g_instance_capacity = new_cap;
    }
    
    /* 初始化新实例 */
    int la_id = g_instance_count++;
    lang_instance_t* inst = &g_instances[la_id];
    memset(inst, 0, sizeof(*inst));
    inst->lang_table = lang_table;
    inst->table_size = num_lines;
    inst->format_start = format_start;
    
    return la_id;
}

int lang_load(int la_id, const char* lang_table[], size_t num_lines) {
    lang_instance_t* inst = get_instance(la_id);
    if (!inst || !inst->lang_table || num_lines != inst->table_size) {
        return -1;
    }
    
    /* 校验格式字符串 */
    if (inst->format_start < inst->table_size) {
        for (size_t i = inst->format_start; i < num_lines; i++) {
            if (inst->lang_table[i] && lang_table[i]) {
                if (!compare_format_specs(inst->lang_table[i], lang_table[i])) {
                    return -1;
                }
            }
        }
    }
    
    /* 直接引用数组，不复制（调用方负责生命周期） */
    free_loaded_table(inst);
    inst->loaded_table = (const char**)lang_table;
    inst->loaded_table_size = num_lines;
    inst->loaded_table_owned = false;
    return 0;
}

int lang_load_tx(int la_id, const char* text) {
    lang_instance_t* inst = get_instance(la_id);
    if (!inst || !text || !inst->lang_table) {
        return -1;
    }
    
    /* 复制文本以便修改（strtok 会破坏原字符串） */
    char* buf = strdup(text);
    if (!buf) {
        return -1;
    }
    
    /* 临时存储读取的行 */
    char** temp_table = calloc(inst->table_size, sizeof(char*));
    if (!temp_table) {
        free(buf);
        return -1;
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
            if (line_count >= inst->table_size) {
                /* 行数超出 */
                for (size_t i = 0; i < line_count; i++) free(temp_table[i]);
                free(temp_table);
                free(buf);
                return -1;
            }
            
            temp_table[line_count] = strdup(p);
            if (!temp_table[line_count]) {
                for (size_t i = 0; i < line_count; i++) free(temp_table[i]);
                free(temp_table);
                free(buf);
                return -1;
            }
            
            /* 校验格式字符串 */
            const char* default_str = inst->lang_table[line_count];
            if (default_str && inst->format_start < inst->table_size && line_count >= inst->format_start) {
                if (!compare_format_specs(default_str, temp_table[line_count])) {
                    for (size_t i = 0; i <= line_count; i++) free(temp_table[i]);
                    free(temp_table);
                    free(buf);
                    return -1;
                }
            }
            
            line_count++;
        }
        
        if (!next_char) break;
        p = end + 1;
    }
    
    free(buf);
    
    /* 检查行数是否匹配 */
    if (line_count != inst->table_size) {
        for (size_t i = 0; i < line_count; i++) free(temp_table[i]);
        free(temp_table);
        return -1;
    }
    
    free_loaded_table(inst);
    inst->loaded_table = (const char**)temp_table;
    inst->loaded_table_size = line_count;
    inst->loaded_table_owned = true;
    return 0;
}

int lang_load_fp(int la_id, FILE *fp) {
    lang_instance_t* inst = get_instance(la_id);
    if (!inst || !fp || !inst->lang_table) {
        return -1;
    }
    
    /* 临时存储读取的行 */
    char** temp_table = calloc(inst->table_size, sizeof(char*));
    if (!temp_table) {
        return -1;
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
        if (line_count >= inst->table_size) {
            /* 行数超出，释放临时表并返回错误 */
            for (size_t i = 0; i < line_count; i++) {
                free(temp_table[i]);
            }
            free(temp_table);
            return -1;
        }
        
        /* 复制字符串 */
        temp_table[line_count] = strdup(line);
        if (!temp_table[line_count]) {
            /* 内存分配失败 */
            for (size_t i = 0; i < line_count; i++) {
                free(temp_table[i]);
            }
            free(temp_table);
            return -1;
        }
        
        /* 验证格式字符串（仅当 ID >= format_start 时） */
        const char* default_str = inst->lang_table[line_count];
        if (default_str && inst->format_start < inst->table_size && line_count >= inst->format_start) {
            /* 该 ID 是格式字符串，校验格式符 */
            if (!compare_format_specs(default_str, temp_table[line_count])) {
                /* 格式符不匹配，释放并返回错误 */
                for (size_t i = 0; i <= line_count; i++) {
                    free(temp_table[i]);
                }
                free(temp_table);
                return -1;
            }
        }
        
        line_count++;
    }
    
    /* 检查行数是否匹配 */
    if (line_count != inst->table_size) {
        for (size_t i = 0; i < line_count; i++) {
            free(temp_table[i]);
        }
        free(temp_table);
        return -1;
    }
    
    /* 释放旧的加载表 */
    free_loaded_table(inst);
    
    /* 设置新的加载表（lang_load_fp 的字符串是 strdup'd） */
    inst->loaded_table = (const char**)temp_table;
    inst->loaded_table_size = line_count;
    inst->loaded_table_owned = true;
    
    return 0;
}
