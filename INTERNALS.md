# i18n 内部原理

提取工具如何查找、校验并回写国际化字符串。

---

## 总体流程

提取管线分八个阶段：

```
源文件 .c / .h
        │
        ▼
[0] 初始化         →  读取 .i18n（SID_NEXT, LA_NAME）
        │
        ▼
[0.5] #define 探测 →  扫描 #define 中的 LA_，生成虚拟探测代码
        │
        ▼
[1] Marker 注入    →  临时 _marker_h   （将 LA_W/S/F 重定义为含 SID 的哨兵标记）
        │
        ▼
[2] cc -E 预处理   →  宏展开后的文本   （所有 #include 递归展开）
        │
        ▼
[3] awk 字符串解析 →  W|key|str|file|sid|line  （字符串 + SID + 行号）
        │
        ▼
[4] 去重 + 排序    →  TEMP_WORDS / TEMP_FORMATS / TEMP_STRINGS（携带 SID）
        │              TEMP_LINE_MAP（每个位置的 file|line|occ）
        ▼
[5] SID 分配 + 代码生成 →  .LANG.h  /  .LANG.c（含 SID）
        │
        ▼
[6] 源码回写       →  LA_W("str", 0) → LA_W("str", LA_W3, 5)
        │
        ▼
[7] 保存 .i18n     →  SID_NEXT=N
```

---

## 阶段 0.5 — #define 探测

### 问题背景

C 预处理器只在宏**调用点**展开，`#define` 定义体对预处理器是"透明"的：

```c
4:  #define LOG_SES(ID) LA_F("sid=%" PRIu64 "\n", 0, 0), ID
```

直接 `cc -E` 时，第 4 行的 `LA_F` 不会被展开，TEMP_LINE_MAP 没有该行记录。

### 解决方案

扫描源文件中 `#define` 行内的 `LA_C?[WSF](...)` 调用，
生成虚拟探测代码，强制预处理器展开它们。

#### Step 1: 扫描并合并续行

用 awk 状态机处理以 `\` 结尾的续行：

```c
// 会被正确识别为一个完整的 #define
#define F_MULTILINE \
    LA_F("multiline message", LA_F20, 20)
```

状态机逻辑：
- 遇到 `#define` 开头行，进入"收集"模式
- 行尾有 `\` 则继续收集下一行
- 行尾无 `\` 则结束收集，合并为单行后检测 `LA_C?[WSF]\(`

#### Step 2: 提取 LA_ 调用

对每个匹配行，用括号深度计数提取完整的 `LA_*(...)` 调用：

```
行 4: LA_F("sid=%" PRIu64 "\n", 0, 0)
```

#### Step 3: 生成虚拟探测代码

为每个调用生成一个内联函数，用 `#line` 指令设置正确行号：

```c
#include "/abs/path/to/example.c"
#line 4 "example.c"
static inline void __i18n_probe_4_1() { LA_F("sid=%" PRIu64 "\n", 0, 0); }
```

关键点：
- `#line 4` 使后续的 `__LINE__` 返回 4（原始定义行号）
- `#include` 原文件以继承编译环境和宏定义
- 只用于预处理，不要求可编译

### 路径转义

`#include` 路径中的特殊字符需要转义：
- `\` → `\\`（Windows 路径分隔符）
- `"` → `\"`（极罕见但存在）

### 效果

1. `#define` 中的 LA_ 也能获得正确的行号记录
2. Phase 6 回写时能命中 `#define` 行
3. 首次运行 SID=0 的调用也能正常工作

---

## 阶段 1 — Marker 注入

核心思路：**不自己解析 C 语法，而是让 C 预处理器代劳**，再从输出中识别已知哨兵标记。

临时头文件（`_marker_h`）将宏重定义为在字符串两侧插入哨兵标记，
**同时嵌入 SID 和行号信息**：

```c
// 通过 cc -E -P -include _marker_h source.c 注入

#define _I18N_SID(...) __VA_ARGS__

#ifndef LA_W
#define LA_W(WD, ...) _I18NW_ WD _I18NSID_ _I18N_SID(__VA_ARGS__) _I18NLINE_ __LINE__ _I18NW_END_
#endif
#ifndef LA_S
#define LA_S(STR, ...) _I18NS_ STR _I18NSID_ _I18N_SID(__VA_ARGS__) _I18NLINE_ __LINE__ _I18NS_END_
#endif
#ifndef LA_F
#define LA_F(FMT, ...) _I18NF_ FMT _I18NSID_ _I18N_SID(__VA_ARGS__) _I18NLINE_ __LINE__ _I18NF_END_
#endif
```

**关键设计**：
- `_I18NSID_` 分隔符后嵌入枚举名和 SID 参数
- `_I18NLINE_` 分隔符后嵌入 `__LINE__`（宏展开时的行号）
- `_I18N_SID(...)` 辅助宏用于原样传递可变参数

SID 和行号在 `cc -E` 展开后原样保留在输出中，使提取器能从同一条预处理输出中同时获得：
1. 字符串内容
2. 现有 SID（用于跨版本跟踪）
3. 源码行号（用于回写定位）

这样做的好处：
- 宏参数中的**相邻字符串拼接**由预处理器自动处理
- `#ifdef` 死分支中的字符串被正确排除
- 通过 `#include` 引入的字符串在每个翻译单元中只出现一次
- awk 无需理解任何 C 语法

`-P` 标志抑制 `#line` 指令，保持输出整洁。  
`-include` 标志注入临时头文件，不修改任何源文件。

### .h 文件处理

头文件需要 `-x c` 告知编译器按 C 源文件处理（而非 C++）。  
自动生成的文件（`.LANG.h`、`.LANG.c`、`LANG.*.h`）被排除在扫描之外，
避免重复收录已处理的字符串。

---

## 阶段 2 — 预处理器输出

对于如下源码片段：

```c
printf(LA_S("Connection to " SERVER_NAME " failed", LA_S0, 12), ...);
```

经 `cc -E -P` 处理后：

```
printf( _I18NS_  "Connection to " "myserver" " failed"  _I18NSID_ LA_S0, 12 _I18NLINE_ 5 _I18NS_END_ , ...);
```

预处理器完成了：
- 将 `SERVER_NAME` 替换为其定义
- 保留相邻字符串字面量为独立 token（尚未合并）
- `_I18NSID_` 后嵌入枚举名和 SID（`LA_S0, 12`）
- `_I18NLINE_` 后嵌入行号（`5`）

哨兵分隔符：
- `_I18NS_` 标记区域起点
- `_I18NSID_` 分隔字符串与参数
- `_I18NLINE_` 分隔参数与行号
- `_I18NS_END_` 标记区域终点

---

## 阶段 3 — awk 字符串解析器

awk 提取器将整个预处理输出作为一个文本块处理。

**片段状态机（每个 Marker 区域）：**

```
等待 _I18N[WSF]_ 哨兵
        │
        ▼
进入"收集"模式
提取 _I18N[WSF]_ ... _I18NSID_ 之间的内容作为字符串片段
提取 _I18NSID_ ... _I18NLINE_ 之间的内容取末尾数字作为 SID
提取 _I18NLINE_ ... _I18N[WSF]_END_ 之间的内容作为行号
        │
        ▼
对字符串片段：
    找下一个 '"' token
    逐字符读取直到闭合 '"'（处理 \" 和 \\）
    拼接到当前字符串
    统计字面量个数 nlit
        │
        ▼
nlit > 1（宏拼接如 PRIu64）→ 跳过该条目
nlit = 1 → 输出：TYPE|key|str|源文件名|sid|line|occ
```

**字符串前缀处理：**  
每个 `"` 前检查宽字符 / Unicode 前缀并跳过：
`L"..."`、`u"..."`、`U"..."`、`u8"..."` → 去掉前缀，提取内容。

**相邻字符串字面量拼接：**  
同一 Marker 区域内的多个引号片段按顺序拼接：
`"hello " "world"` → `hello world`。

**多段字符串字面量检测（PRIu64 等宏拼接）：**

当 `nlit > 1`（即同一区域内出现多个独立的字符串字面量）时，
说明涉及 C 宏拼接（如 `"timeout %" PRIu64 " ms"`，`PRIu64` 被预处理器展开为 `"ll" "u"`）。
这类字符串包含平台相关的格式说明符，不适合国际化追踪，因此被直接跳过。

源码回写阶段也会检测这种模式，将其 ID 和 SID 强制重置为 `0, 0`，
使 `LA_F` 在运行时直接使用字面量（正确行为）。

---

## 阶段 4 — 去重与排序

W、S、F 三种类型独立处理。

### Words（LA_W）

Key = `trim(lowercase(str))`

- 去除首尾空白
- 折叠为小写
- 多个变体（`"CLOSED"`、`" closed "`、`"Closed"`）共享同一 ID

存储值 = 首次出现的原始字符串（保留原始大小写和空格）。

### Strings（LA_S）

Key = `lowercase(str)`（不 trim）

仅大小写不同的字符串共享 ID；空白差异产生不同 ID。

### Formats（LA_F）

Key = `str`（完全匹配）

格式字符串精确匹配，哪怕空白不同也产生新 ID。
这是有意为之：格式参数的数量和类型必须完全一致。

### 排序

三张表均通过 `LC_ALL=C sort -t'|' -k2,2` 排序。

`LC_ALL=C` 至关重要：它强制按字节序排列，与系统 locale 无关。
若不设置，相同源码在 macOS（BSD libc）和 Linux（glibc）上会产生不同的 ID 编号。

---

## 阶段 5 — SID 分配与代码生成

SID（Serial ID）是每个字符串条目的唯一持久编号，写入源文件作为 `LA_*` 第三参数。

SID 的作用：
- 跨版本跟踪字符串变更（--import 变更检测的基础）
- LA_Wn ID 可能因新增/删除条目而重新分配，SID 不会变，其对应的译文也就不会丢失

### SID 提取方式（SID-in-marker 架构）

SID 在阶段 1 通过 `_I18NSID_` 分隔符嵌入预处理输出，
在阶段 3 与字符串一起从 `cc -E` 输出中提取。
聚合后的数据格式为五列：`TYPE|key|str|file|sid`。

**不再需要单独扫描原始源码来获取 SID**——
旧方案中从原始源码正则提取 SID 时，
`PRIu64` 等宏拼接的多段字符串会导致 key 不一致
（预处理输出与原始源码中的字符串形态不同），
造成 SID 每次运行都重新分配（"SID 漂移"）。

### .i18n 持久化文件

格式：`SID_NEXT=N`，每次运行后自动更新
位置：与源码目录同层（各子目录独立）

### 分配逻辑

```
1. 从阶段 4 的聚合结果中读取每个条目的已有 SID（第 5 列）

2. 为每个条目分配 SID：
   - 已有 SID > 0 → 沿用
   - 无已有 SID（新条目）→ SID_NEXT 自增

3. 如果 .i18n 不存在（I18N_REINIT=1）：
   - 忽略已有 SID，全量从 1 重新分配
   - 确保 SID 不被旧数据干扰
   - 如果已有 LANG.SUFFIX.h，备份到 .bak

4. 运行结束：max_sid = max(所有已分配 SID)
   如 max_sid >= SID_NEXT ，推高 SID_NEXT = max_sid + 1
   写入 .i18n
```

### --ndebug 双模式

SID 分配后，枚举 ID 名称的生成策略取决于运行模式：

| 模式 | id_name 规则 | 枚举排列 | 数组布局 |
|---|---|---|---|
| 默认 (Debug) | `LA_{T}{SID}`（如 `LA_W5`） | 按 SID 顺序，空洞用 `_LA_N` 占位符填充 | 可能有空洞（lang_str 对 NULL 返回 ""） |
| `--ndebug` (Release) | `LA_{T}{seq}`（如 `LA_W0`） | 按类型分组连续编号 | 紧凑无空洞 |

两种模式共用同一套 SID 追踪系统（`.i18n` 文件）。
Debug 模式下增删条目不影响已有项的 ID 值（减少 diff 噪音）；
`--ndebug` 模式下每次运行都可能重新分配 ID（追求最小内存占用）。

### 代码生成

#### .LANG.h

输出一个匿名枚举，包含三段连续的块：

```
LA_PRED  (= LA_PREDEFINED，默认 -1)
LA_W0 … LA_Wn
LA_S0 … LA_Sm
LA_F0 … LA_Fk
LA_NUM
```

每个枚举项的注释记录字符串内容和使用该字符串的源文件名。
`LA_FMT_START` 定义为 `LA_F0`（无格式字符串时为 `LA_NUM`），供运行时确定格式校验起始位置。

### .LANG.c

输出与枚举顺序完全对齐的 `const char* lang_en[LA_NUM]` 数组，
每个元素是规范化的 C 字符串字面量，**并附带 `/* SID:N */` 注释**。

```c
    [LA_W2] = "CONNECTED",  /* SID:3 */
    [LA_S0] = "Connection failed",  /* SID:12 */
```

`//import` 机制在达到当前 `.LANG.c` 内容之前就读取它，
建立旧英文内容映射 TEMP_OLD_SID_MAP：`SID → en_string`，
用于后续的内容变更检测。

### 预定义 ID（LANG.h / PRED_NUM）

若项目存在手工维护的 `LANG.h`（其中 `PRED_NUM` 之前有预定义枚举项），
提取器会读取这些项，并在 `.LANG.c` 顶部和 `lang.en` 中插入占位注释，
使数组下标保持对齐。

---

## 阶段 6 — 源码回写

生成枚举后，提取器将源目录下所有 `.c` 和 `.h` 文件中的
`LA_*(str, 占位符)` 调用替换为正确的 `LA_*(str, LA_Xn, SID)`。

**算法（纯 awk，逐字符扫描）：**

1. 对每一行，扫描 `LA_W`、`LA_S`、`LA_F`
2. 确认其后（跳过空白）是 `(`
3. 解析带引号的字符串参数（处理 `\"`  和 `\\`）
4. 按阶段 4 的规则计算规范化 key
5. 在 TEMP_MAP 中查找对应的 id_name 和 SID
6. 将原有 ID token（如 `0` 或旧的 `LA_Wn`）替换为新 id_name
7. 如果已有数字形式的第三参数，跳过它，写入新 SID

结果写入临时文件，再通过 `mv` 覆盖原文件。
若 awk 失败，原文件不会被修改。

**多段字符串字面量清理：**

回写前先检测含宏拼接的调用（如 `LA_F("..." PRIu64 "...", ...)`），
将其 ID 和 SID 强制重置为 `0, 0`。
这确保不可追踪的字符串不会残留旧的 ID 值。

#### 为什么不用正则表达式？

朴素的正则如 `s/LA_W("...", \w+)/LA_W("...", LA_W3, 5)/` 在以下情况会失败：
- 字符串内包含 `)` 或 `,`
- 宏调用跨多行
- 字符串内有转义引号

字符扫描器能正确处理所有这些情况。

PowerShell 版本的源码回写使用 `[Regex]::Replace` + `[MatchEvaluator]`，
先通过正则处理多段字符串清理，再用三个分类正则（W/S/F）替换标准调用。

---

## `--import` 三种情况处理

`--import SUFFIX` 在生成 `LANG.SUFFIX.h` 时，需要跟踪已有译文与英文变更情况。  
临时数据结构：

```
TEMP_OLD_IMPORT_MAP： SID → 旧译文（解析旷程序本就已有的 LANG.SUFFIX.h）
TEMP_OLD_SID_MAP：    SID → 旧英文（解析被覆写前的 .LANG.c）
```

**处理逻辑（每个条目）：**

```
if TEMP_OLD_IMPORT_MAP 中无此 SID：
    → 新增条目：写英文占位 + /* SID:N new */

elif TEMP_OLD_SID_MAP[此SID] != 当前英文：
    → 英文变更：保留旧译文 + /* [SID:N] UPDATED new: "新英文" */

else：
    → 未变更：保留旧译文 + /* SID:N */
```

同时对新增 / 变更数量进行计数并打印 NOTE 提示译者。

---

## compile_commands.json 解析

使用 awk 解析（无需 `jq`）。

CMake 生成的 JSON 每个字段单独占一行：

```json
{
  "directory": "...",
  "command": "cc -Iinclude -DFOO=1 -c src/foo.c -o foo.o",
  "file": "src/foo.c"
}
```

awk 解析器：
1. 遇到 `{` 时重置状态
2. 提取 `"file"` 和 `"command"` / `"arguments"` 字段值
3. 遇到 `}` 时，通过后缀比较判断是否匹配目标文件（容忍路径前缀不同）
4. 剥离输出相关标志（`-c`、`-o`、`-MF`、`-MT`、`-MD`、源文件本身）
5. 将剩余标志作为该文件的编译上下文返回

---

## Windows（PowerShell）

`i18n.ps1` 原生实现相同的流程，包含完整的 SID 机制：

- `compile_commands.json` 通过 `ConvertFrom-Json`（PS 3+ 内置）解析
- MSVC 预处理器：`/EP`（输出到 stdout，无 `#line`）+ `/FI<file>`（强制包含）
- GCC/Clang：与 bash 版本相同的 `-E -P -include`
- SID 状态：`$I18NFile`、`$I18NReinit`、`$SidNext`、`$SidNextStart`，逻辑与 sh 版一致
- 字符串提取：awk 片段状态机的 PowerShell 实现
- 源码回写：`[Regex]::Replace` 配合显式 `[MatchEvaluator]` 委托，同时写入 id_name 和 SID
- `--import`：三种情况处理进 `$oldImportMap` / `$oldSidMap` / `Add-ImportEntry` 函数
- 排序等价：对 key 字段执行 `Sort-Object`，在去重之后进行

`i18n.bat` 优先尝试可用的 bash 环境（WSL → Git Bash → MSYS2 → Cygwin）
并委托给 `i18n.sh`，仅在无可用 bash 时才回退到 `i18n.ps1`。

---

## 临时文件布局（--debug 模式）

```
i18n/debug/
├── all.txt             # 提取器原始输出（W|key|str|file|sid，每行一条）
├── words.txt           # 去重 + 排序后的 LA_W 条目（含 SID）
├── formats.txt         # 去重 + 排序后的 LA_F 条目（含 SID）
├── strings.txt         # 去重 + 排序后的 LA_S 条目（含 SID）
├── map.txt             # W|key|LA_Wn|SID …（四列 TEMP_MAP）
├── old_sid_map.txt     # 解析自旧 .LANG.c： SID|英文内容
└── old_import_map.txt  # 解析自旧 LANG.SUFFIX.h： SID|旧译文
```

当提取结果不符合预期时，加 `--debug` 参数运行即可检查各阶段中间结果。

---

## 特殊情况处理

以下场景需要额外处理逻辑，已在提取器中实现。

### 1. 多行 `#define` 续行符

C 预处理器支持用 `\` 将长行分割为多行：

```c
#define F_MULTILINE \
    LA_F("multiline message", LA_F20, 20)
```

**处理方式**：阶段 0.5 使用 awk 状态机，在扫描 `#define` 时将续行合并为完整行后再匹配 `LA_C?[WSF]\(`。

### 2. 路径特殊字符转义

阶段 0.5 生成的虚拟探测代码包含 `#include "绝对路径"` 指令，路径中可能包含 C 字符串的特殊字符：

| 字符 | 转义 | 说明 |
|-----|-----|-----|
| `\` | `\\` | Windows 路径分隔符 |
| `"` | `\"` | 极罕见，但需要处理 |

**处理方式**：在生成 `#include` 前对路径进行转义（bash 用 `sed`，PowerShell 用 `.Replace()`）。

### 3. 字符串字面量拼接

C 允许相邻字符串字面量自动拼接：

```c
LA_S("hello " "world", S_TEST, 1);  // 等价于 "hello world"
```

**处理方式**：阶段 3 的 awk 解析器在同一 Marker 区域内收集所有引号片段并拼接。

### 4. 宽字符前缀

支持 C11 字符前缀：

```c
LA_W(L"宽字符", W_WIDE, 1);
LA_W(u"UTF-16", W_UTF16, 2);
LA_W(U"UTF-32", W_UTF32, 3);
LA_W(u8"UTF-8", W_UTF8, 4);
```

**处理方式**：阶段 3 解析器在遇到 `L`、`u`、`U`、`u8` 后跟 `"` 时跳过前缀，只提取字符串内容。

### 5. 多段宏拼接字符串（PRIu64）

涉及 `<inttypes.h>` 格式宏的字符串：

```c
LA_F("id=%" PRIu64 "\n", 0, 0);  // PRIu64 展开为 "llu"
```

预处理后变为多个字面量片段（`nlit > 1`），无法统一追踪。

**处理方式**：
- 阶段 3 检测 `nlit > 1` 时跳过该条目
- 阶段 6 回写时将 ID 和 SID 重置为 `0, 0`，确保运行时直接使用字面量

### 6. 同行多个 LA_ 调用

单行可能有多个调用：

```c
printf("%s %s", LA_W("A", W_A, 1), LA_W("B", W_B, 2));
```

**处理方式**：用 `occ`（occurrence）字段记录同一行的第几次出现，回写时按 `(file, line, occ)` 三元组精确匹配。

---

## 已知限制

以下场景当前无法自动处理，需要应用层避免使用。

### 1. 间接宏别名

当 `LA_W/S/F` 通过宏别名间接调用时，阶段 0.5 无法识别：

```c
// ❌ 不支持：无法被提取
#define MSG LA_W
#define GREETING MSG("Hello", 0, 0)
```

`MSG("Hello", ...)` 不匹配正则 `LA_C?[WSF]\(`，因此不会被检测。

**规避方式**：直接使用 `LA_W/S/F`，不要定义别名。

### 2. `#if 0` 注释块

被 `#if 0` 或未满足的条件编译包裹的代码不会被提取：

```c
#if 0
// ❌ 不会被提取（预期行为）
LA_W("disabled", W_DISABLED, 1);
#endif
```

这是**预期行为**——死代码中的字符串不应进入国际化流程。
如果确实需要保留，请移除 `#if 0` 或改用注释。

### 3. 嵌套宏作为 LA_ 的第一参数

当字符串参数本身是宏调用时：

```c
#define MSG "Hello"
// ⚠️ 可能有问题
#define GREETING LA_W(MSG, W_GREETING, 1)
```

**当前行为**：`MSG` 会被预处理器展开，实际字符串 `"Hello"` 会被正确提取，但取决于 `MSG` 的定义是否可见。

**建议**：优先使用字符串字面量作为第一参数。
