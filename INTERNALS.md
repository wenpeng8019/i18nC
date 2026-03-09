# i18n 内部原理

提取工具如何查找、校验并回写国际化字符串。

---

## 总体流程

提取管线分八个阶段：

```
源文件 .c / .h
        │
        ▼
[1] Marker 注入    →  临时 _marker_h   （将 LA_W/S/F 重定义为哨兵标记）
        │
        ▼
[2] cc -E 预处理   →  宏展开后的文本   （所有 #include 递归展开）
        │
        ▼
[3] awk 字符串解析 →  W|key|str|file  /  S|key|str|file  /  F|key|str|file
        │
        ▼
[4] 去重 + 排序    →  TEMP_WORDS / TEMP_FORMATS / TEMP_STRINGS
        │
        ▼
[5] SID 扫描 + 分配  →  TEMP_EXISTING_SIDS（旧 SID）/ 新 SID 自 .i18n 分配
        │
        ▼
[6] 代码生成       →  .LANG.h  /  .LANG.c（含 SID）/  lang.en
        │
        ▼
[7] 源码回写       →  LA_W("str", 0) → LA_W("str", LA_W3, 5)
        │
        ▼
[8] 保存 .i18n     →  SID_NEXT=N
```

---

## 阶段 1 — Marker 注入

核心思路：**不自己解析 C 语法，而是让 C 预处理器代劳**，再从输出中识别已知哨兵标记。

临时头文件（`_marker_h`）将宏重定义为在字符串两侧插入唯一哨兵：

```c
// 通过 cc -E -P -include _marker_h source.c 注入

#undef LA_W
#define LA_W(WD, ID, ...)  _I18NW_  WD  _I18NW_END_

#undef LA_S
#define LA_S(STR, ID, ...) _I18NS_  STR  _I18NS_END_

#undef LA_F
#define LA_F(FMT, ...)     _I18NF_  FMT  _I18NF_END_
```

`LA_W` / `LA_S` 采用 `...` 吸收第三参数 SID，使当源文件带着 SID 第三参数时也能正常预处理。

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
printf(LA_S("Connection to " SERVER_NAME " failed", LA_S0), ...);
```

经 `cc -E -P` 处理后：

```
printf( _I18NS_  "Connection to " "myserver" " failed"  _I18NS_END_ , ...);
```

预处理器完成了：
- 将 `SERVER_NAME` 替换为其定义
- 保留相邻字符串字面量为独立 token（尚未合并）

哨兵 `_I18NS_` 标记区域起点，`_I18NS_END_` 标记区域终点。

---

## 阶段 3 — awk 字符串解析器

awk 提取器将整个预处理输出作为一个文本块处理。

**片段状态机（每个 Marker 区域）：**

```
等待 _I18N[WSF]_ 哨兵
        │
        ▼
进入"收集"模式
循环直到 _I18N[WSF]_END_：
    找下一个 '"' token
    逐字符读取直到闭合 '"'（处理 \" 和 \\）
    拼接到当前字符串
        │
        ▼
输出：TYPE|key|str|源文件名
```

**字符串前缀处理：**  
每个 `"` 前检查宽字符 / Unicode 前缀并跳过：
`L"..."`、`u"..."`、`U"..."`、`u8"..."` → 去掉前缀，提取内容。

**相邻字符串字面量拼接：**  
同一 Marker 区域内的多个引号片段按顺序拼接：
`"hello " "world"` → `hello world`。

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

## 阶段 5 — SID 扫描与分配

SID（Serial ID）是每个字符串条目的唯一持久编号，写入源文件作为 `LA_*` 第三参数。

SID 的作用：
- 跨版本跟踪字符串变更（-- import 变更检测的基础）
- LA_Wn ID 可能因新增/删除条目而重新分配，SID 不会变，其对应的译文也就不会丢失

### .i18n 持久化文件

格式：`SID_NEXT=N`，每次运行后自动更新
位置：与源码目录同层（各子目录独立）

### 扫描 + 分配逻辑

```
1. 扫描源文件中现有 LA_X(str, id, SID) 的第三参数
   → 建立 TEMP_EXISTING_SIDS： type|key|SID

2. 对字面量生成 TEMP_WORDS/STRINGS/FORMATS 后，为每个条目分配 SID：
   - 可从 TEMP_EXISTING_SIDS 查到已有 SID → 居用
   - 查不到（新条目） → SID_NEXT 自增，写入 TEMP_MAP（字段 4）

3. 如果 .i18n 不存在（I18N_REINIT=1）：
   - 跳过 TEMP_EXISTING_SIDS 查找，全量从 1 重新分配
   - 确保 SID 不被旧数据干扰
   - 如果已有 LANG.SUFFIX.h，备份到 .bak

4. 运行结束： SID_NEXT 取与现有最大 SID+1 的较大值，写入 .i18n
```

### TEMP_MAP 格式（四列）

```
type | key | id_name | SID
  W  | connected | LA_W2 | 3
  S  | connection failed | LA_S0 | 12
  F  | port %d open\n | LA_F0 | 33
```

---

## 阶段 6 — 代码生成

### .LANG.h

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

## 阶段 7 — 源码回写

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

#### 为什么不用正则表达式？

朴素的正则如 `s/LA_W("...", \w+)/LA_W("...", LA_W3, 5)/` 在以下情况会失败：
- 字符串内包含 `)` 或 `,`
- 宏调用跨多行
- 字符串内有转义引号

字符扫描器能正确处理所有这些情况。

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
├── all.txt             # 提取器原始输出（W|key|str|file，每行一条）
├── words.txt           # 去重 + 排序后的 LA_W 条目
├── formats.txt         # 去重 + 排序后的 LA_F 条目
├── strings.txt         # 去重 + 排序后的 LA_S 条目
├── map.txt             # W|key|LA_Wn|SID …（四列 TEMP_MAP）
├── existing_sids.txt   # 提取自源码第三参数的现有 SID： type|key|SID
├── old_sid_map.txt     # 解析自旧 .LANG.c： SID|英文内容
└── old_import_map.txt  # 解析自旧 LANG.SUFFIX.h： SID|旧译文
```

当提取结果不符合预期时，加 `--debug` 参数运行即可检查各阶段中间结果。
