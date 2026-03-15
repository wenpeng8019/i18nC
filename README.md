# i18nC — 轻量级 C 国际化工具

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)
![Language](https://img.shields.io/badge/language-C-brightgreen)

基于 C 预处理器驱动的零外部依赖国际化系统。  
源码保留**可读的英文字面量**，字符串 ID 由工具自动回写。  
无 gettext，无额外运行时，开关 i18n 不需要修改业务代码。

---

## 文件说明

| 文件 | 用途 |
|---|---|
| `i18n.h` | 运行时头文件 — `LA_W`、`LA_S`、`LA_F` 宏 + `lang_str()` API |
| `i18n.c` | 运行时实现 — 字符串表查找、格式符校验、文件加载 |
| `i18n.sh` | 提取工具（Linux / macOS） |
| `i18n.bat` | 提取工具启动器（Windows — 优先找 bash，否则调用 PS） |
| `i18n.ps1` | 提取工具（Windows 原生 PowerShell 5.1+） |

---

## 快速上手

### 1. 在 C 源码中标注字符串

```c
#include <i18n.h>
// or: #include "LANG.h"   (after running i18n.sh once)

printf(LA_S("Connection established", LA_S0));
printf(LA_F("[%s] error %d\n", LA_F1), peer, code);
printf(LA_W("CONNECTED", LA_W2));
```

首次运行时可使用占位符 `0`，提取工具会自动回写正确的 ID 和 SID：

```c
printf(LA_S("Connection established", 0));
```

未定义 `I18N_ENABLED` 时，`LA_W` / `LA_S` / `LA_F` 在编译期直接展开为字面量——零开销，零链接依赖。

### 2. 运行提取工具

```sh
./i18n/i18n.sh p2p_server      # Linux / macOS
i18n\i18n.bat p2p_server       # Windows
```

生成：

- `p2p_server/.LANG.h` — 所有字符串 ID 的枚举（`LA_W0`、`LA_S3`、`LA_F12` …）
- `p2p_server/.LANG.c` — 英文字符串表 `lang_en[]`，每条带 `/* SID:N */` 注释
- `p2p_server/.i18n` — SID 计数器状态文件（`SID_NEXT=N`），用于跨版本稳定追踪
- 将源码中所有 `LA_*(str, 旧ID)` 回写为 `LA_*(str, LA_Xn, SID)`

### 3. 在构建中开启 i18n

```cmake
target_compile_definitions(my_target PRIVATE I18N_ENABLED)
target_include_directories(my_target PRIVATE ${PROJECT_SOURCE_DIR}/i18n)
```

```c
// In your main() or init function:
#include "LANG.h"   // user init, includes .LANG.h

lang_init();  // registers lang_en[] and sets LA_RID

// optionally load a translation:
lang_load_fp(LA_RID, fopen("lang.zh", "r"));
// or use embedded translation:
lang_cn();    // calls lang_load(LA_RID, s_lang_cn, LA_NUM)
```

---

## 宏参考

| 宏 | 用途 | 示例 |
|---|---|---|
| `LA_W(str, id, sid)` | 单词 / 短标记 | `LA_W("CONNECTED", LA_W2, 3)` |
| `LA_S(str, id, sid)` | 完整句子 | `LA_S("Server started", LA_S0, 17)` |
| `LA_F(fmt, id, ...)` | printf 格式字符串 | `LA_F("Port %d open\n", LA_F1, 33)` |
| `LA_ID(id, ...)` | 直接按 ID 查找（无字面量） | `LA_ID(LA_W2)` |

- **第 2 参数**（`LA_Xn`）：数组下标，由工具自动回写，开启 `I18N_ENABLED` 后类型检查自动居中
- **第 3 参数 SID**：字符串唯一序列号，纯数字常量，`LA_W/LA_S` 的 `...` 参数吸收并导致编译器完全忽略；不影响运行效率

未定义 `I18N_ENABLED` 时，`LA_W/S/F` 直接返回字面量——生成的二进制与从未使用 i18n 的代码完全一致。

---

## 提取工具选项

```
./i18n/i18n.sh <source_dir> [options]

选项：
  --ndebug          紧凑模式（Release 构建），连续编号，无空洞
  --export          同时输出 lang.en（翻译模板）
  --import SUFFIX   生成/更新 LANG.SUFFIX.h（保留已有译文，标记新增与变更条目）
  --debug           将所有中间临时文件保存到 ./i18n/debug/ 以供排查
```

### --ndebug 双模式

提取工具支持两种 ID 编号策略，通过 `--ndebug` 选项切换：

| 模式 | 枚举风格 | 数组布局 | 适用场景 |
|---|---|---|---|
| 默认 (Debug) | `LA_W5`, `LA_S26`, `LA_F96`（基于 SID） | 按 SID 排列，空洞用占位符 `_LA_N` 填充 | 开发期：增删条目不影响已有 ID，减少 diff 噪音 |
| `--ndebug` (Release) | `LA_W0`~`Wn`, `LA_S0`~`Sn`, `LA_F0`~`Fn`（连续） | 按类型分组紧凑排列，无空洞 | 发布构建：最小化内存占用 |

两种模式共用相同的 SID 追踪系统（`.i18n` 文件），切换无需重新初始化。

**CMake 集成示例**（根据构建类型自动选择模式）：

```cmake
if(CMAKE_BUILD_TYPE STREQUAL "Release" OR CMAKE_BUILD_TYPE STREQUAL "MinSizeRel")
    set(I18N_NDEBUG_FLAG "--ndebug")
else()
    set(I18N_NDEBUG_FLAG "")
endif()

add_custom_target(i18n_gen
    COMMAND bash ${PROJECT_SOURCE_DIR}/i18n/i18n.sh ${SOURCE_DIR} ${I18N_NDEBUG_FLAG}
)
```

### --export / --import 翻译工作流

```sh
# 1. 导出英文模板
./i18n/i18n.sh p2p_server --export
# -> p2p_server/lang.en

# 2. 翻译（手动编辑或借助翻译工具）
cp p2p_server/lang.en p2p_server/lang.zh
$EDITOR p2p_server/lang.zh

# 3. 导入 — 生成包含 s_lang_zh[] 表和 lang_zh() 函数的 LANG.zh.h
./i18n/i18n.sh p2p_server --import zh
# -> p2p_server/LANG.zh.h

# 4. 运行时激活
lang_load_fp(LA_RID, fopen("lang.zh", "r"));
// 或使用静态嵌入：
#include "LANG.zh.h"
lang_zh();   // 调用 lang_load(LA_RID, s_lang_zh, LA_NUM)
```

#### --import 三种情况

每次运行 `--import` 时，工具通过 SID 比对旧译文，自动处理三种情形：

| 情形 | 生成注释 | 含义 |
|---|---|---|
| 当前版本首次出现的字符串 | `/* SID:N new */` | 以英文原文作占位，等待翻译 |
| 英文内容较上次发生变化 | `/* [SID:N] UPDATED new: "新英文" */` | 旧译文被保留，需人工核对以更新译文 |
| 英文内容未变 | `/* SID:N */` | 直接沿用已有译文 |

每次运行时若有新增或变更条目，工具会打印提示：

```
  NOTE: 3 new string(s) added as English placeholders (marked /* new */)
  NOTE: 1 string(s) English changed — old translation kept, marked /* [SID:N] UPDATED new: ... */
```

---

## 运行时 API（`i18n.h` / `i18n.c`）

```c
// 注册默认（英文）字符串表 — 启动时调用一次，返回语言实例 ID
int  lang_def(const char* lang_table[], size_t num_lines, size_t format_start);

// 加载已翻译的表（静态指针 — 调用方负责生命周期）
int  lang_load(int la_id, const char* lang_table[], size_t num_lines);

// 从文本文件加载（每行一个字符串，# 开头为注释）
int  lang_load_fp(int la_id, FILE *fp);

// 从内存字符串加载（格式与文本文件相同）
int  lang_load_tx(int la_id, const char* text);

// 按 ID 查找字符串（I18N_ENABLED 时由 LA_W/S/F 内部调用）
const char* lang_str(int la_id, unsigned id);
```

### 多实例支持

每次调用 `lang_def()` 返回一个唯一的 `la_id`（语言实例 ID），
后续 `lang_load*` 和 `lang_str` 调用需传入此 ID。

生成的 `LANG.h` 会自动处理这些细节：
- `lang_init()` 调用 `lang_def()` 并将返回的 `la_id` 存入 `LA_RID`
- `LA_W/S/F` 宏内部使用 `LA_RID` 调用 `lang_str()`
- `lang_{suffix}()` 辅助函数（如 `lang_cn()`）调用 `lang_load(LA_RID, ...)`

这允许同一进程中多个项目各自维护独立的语言表，互不干扰。

`lang_load_fp` 和 `lang_load_tx` 会将翻译版本的格式符（`%s`、`%d` 等）与默认表逐一校验——格式符类型或数量不匹配的翻译会被拒绝（返回 -1）。

---

## 生成文件格式

### `.LANG.h`

```c
enum {
    LA_PRED = LA_PREDEFINED,   // 基础 ID（默认 -1；可通过 -DLA_PREDEFINED=N 重定义）

    /* Words */
    LA_W1,  /* "disabled"  [server.c] */
    LA_W2,  /* "enabled"   [server.c] */

    /* Strings */
    LA_S3,  /* "Server started"  [server.c] */

    /* Formats */
    LA_F4,  /* "Port %d\n" (%d)  [server.c] */

    LA_NUM
};

#define LA_FMT_START LA_F4
extern const char* lang_en[LA_NUM];

/* 语言实例 ID（多实例支持） */
#define LA_RID lang_rid
extern int lang_rid;
```

### `.LANG.c`（含 SID 注释）

```c
#include ".LANG.h"

int lang_rid;  // 语言实例 ID

const char* lang_en[LA_NUM] = {
    [LA_W1] = "disabled",       /* SID:1 */
    [LA_W2] = "enabled",        /* SID:2 */
    [LA_S3] = "Server started", /* SID:3 */
    [LA_F4] = "Port %d\n",      /* SID:4 */
};
```

SID（Serial ID）是每个字符串条目的唯一持久编号，写在注释中供工具读取，不影响 C 编译器。

### `.i18n`（SID 状态文件）

```
SID_NEXT=44
```

每次运行后自动更新，记录下一个可用 SID。各源码子目录独立计数，删除该文件将触发全量重新初始化（所有条目 SID 从 1 重新分配）。

### `LANG.zh.h`（--import 生成）

```c
#include ".LANG.h"

/* Embedded zh language table */
static const char* s_lang_zh[LA_NUM] = {
    [LA_W1] = "已禁用",          /* SID:1 */
    [LA_W2] = "已启用",          /* SID:2 */
    [LA_S3] = "服务器已启动",    /* SID:3 */
    [LA_S4] = "Server error",   /* SID:4 new */
    [LA_F5] = "端口 %d\n",      /* [SID:5] UPDATED new: "Port %d open\n" */
};

static inline int lang_zh(void) {
    return lang_load(LA_RID, s_lang_zh, LA_NUM);
}
```

### `lang.en`（--export 翻译模板）

```
# Language Table (one string per line)
# Lines starting with '#' are comments. No blank lines between entries.
disabled
enabled
Server started
Port %d\n
```

---

## 编译数据库支持

提取工具需要每个源文件的实际编译参数才能正确预处理。按以下优先级查找：

1. **`compile_commands.json`** — 在 `build_cmake/`、`cmake-build-debug/`、`build/`、`.` 中依次查找
2. **CMake 自动配置** — 存在 `CMakeLists.txt` 时自动运行 `cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -B build_cmake`
3. **bear** — 存在 `Makefile` 时运行 `bear -- make -n`（未安装时提示安装）
4. **`compile_flags.txt`** — 兜底，对所有文件使用相同参数

---

## 平台支持

| 平台 | 工具 | 依赖 |
|---|---|---|
| Linux / macOS | `i18n.sh` | bash、cc（gcc/clang）、awk、sort |
| Windows（有 bash） | `i18n.bat` → `i18n.sh` | WSL / Git Bash / MSYS2 / Cygwin |
| Windows（原生） | `i18n.bat` → `i18n.ps1` | PowerShell 5.1+（Win10 内置） |

无 Perl，无 Python，无任何额外运行时库。

---

## 设计目标

- **非侵入式** — 源码保持可读的英文字面量；关闭 i18n 时宏完全透明
- **运行时零扫描** — 运行时仅做数组下标查找，启动时无任何字符串解析开销
- **格式符安全** — 翻译版格式字符串在加载时与英文模板逐一校验，类型不匹配直接拒绝
- **确定性 ID** — 以 `LC_ALL=C` 排序，保证 macOS 与 Linux 生成相同的 ID 编号
- **稳定 SID** — 每个字符串持有唯一序列号，跨版本追踪英文内容变更，译文带 UPDATED 标柨提醒人工核对
- **最小工具链** — 提取仅依赖 `cc -E`、`awk`、`sort`，均为标准 POSIX 工具

---

## 已知限制

以下场景当前不支持自动处理：

| 场景 | 说明 |
|---|---|
| 间接宏别名 | `#define MSG LA_W` 后使用 `MSG("...", ...)` 无法被提取 |
| `#if 0` 代码块 | 被条件编译排除的字符串不会被提取（预期行为） |
| 宏拼接格式符 | `LA_F("%" PRIu64, ...)` 等涉及 `<inttypes.h>` 的调用会被自动重置为 `0, 0` |

详细技术说明请参见 [INTERNALS.md](INTERNALS.md)。

---

## 另请参阅

- [INTERNALS.md](INTERNALS.md) — 提取工具内部原理（Marker 注入、awk 解析器、#define 探测、源码回写）
