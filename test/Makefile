# i18n/test/Makefile
#
# 构建目标：
#   hello       字面量模式（无 i18n.c，零依赖演示）
#   hello-i18n  I18N 模式（默认英文表）
#   hello-cn    I18N + 静态中文嵌入（需先运行 import-cn）
#
# 工具目标：
#   gen          运行 i18n.sh（debug 模式：SID-based 稳定 ID + gap 占位符）
#   gen-ndebug   运行 i18n.sh --ndebug（release 模式：紧凑顺序 ID）
#   import-cn    生成/维护 LANG.cn.h（--import cn）
#   test         运行完整集成测试脚本 test.sh
#   clean        清理生成文件和可执行文件

CC      := cc
CFLAGS  := -Wall -Wextra -std=c11

# i18n 工具和公共源都在父目录
I18N_DIR  := ..
I18N_C    := $(I18N_DIR)/i18n.c
I18N_H    := $(I18N_DIR)/i18n.h

# 当前目录生成文件
GEN_H   := .LANG.h
GEN_C   := .LANG.c
I18N_RC := .i18n

.PHONY: all gen import-cn hello hello-i18n hello-cn test clean

all: hello hello-i18n hello-cn   ## build all three modes

# ----------------------------------------------------------------------------
# gen: call i18n.sh to scan hello.c and emit .LANG.h / .LANG.c / .i18n
#      NOTE: i18n.sh also writes back SIDs to hello.c; to avoid an infinite
#      dependency loop, gen is always .PHONY (run on demand, not auto-triggered).
#      Run "make gen" explicitly whenever you add or change i18n-annotated strings.
# ----------------------------------------------------------------------------
gen:
	@echo "[gen] Running i18n.sh on test/ (debug mode) ..."
	cd $(I18N_DIR) && bash i18n.sh test
	@echo "[gen] Done: .LANG.h .LANG.c .i18n generated (SID-based stable IDs)."

# ----------------------------------------------------------------------------
# gen-ndebug: same scan, but emit compact sequential IDs (release payload)
# ----------------------------------------------------------------------------
gen-ndebug:
	@echo "[gen-ndebug] Running i18n.sh --ndebug on test/ ..."
	cd $(I18N_DIR) && bash i18n.sh test --ndebug
	@echo "[gen-ndebug] Done: .LANG.h .LANG.c .i18n generated (compact IDs)."

# ----------------------------------------------------------------------------
# import-cn: generate/maintain LANG.cn.h (3-case: new / UPDATED / unchanged)
# ----------------------------------------------------------------------------
import-cn:
	@echo "[import-cn] Running i18n.sh --import cn ..."
	cd $(I18N_DIR) && bash i18n.sh test --import cn
	@echo "[import-cn] Done."

# ----------------------------------------------------------------------------
# Build: literal mode (no i18n.c, zero-dependency demo)
# ----------------------------------------------------------------------------
hello: hello.c $(I18N_H)
	@echo "[build] $@ (literal mode) ..."
	$(CC) $(CFLAGS) -I$(I18N_DIR) -o $@ hello.c
	@echo "[build] $@ done."

# ----------------------------------------------------------------------------
# Build: I18N English default mode
# ----------------------------------------------------------------------------
hello-i18n: hello.c $(GEN_H) $(GEN_C) $(I18N_C)
	@echo "[build] $@ (i18n, English default) ..."
	$(CC) $(CFLAGS) -I$(I18N_DIR) -I. \
	    -DI18N_ENABLED \
	    -o $@ hello.c $(I18N_C) $(GEN_C)
	@echo "[build] $@ done."

# ----------------------------------------------------------------------------
# Build: I18N + static embedded Chinese (requires LANG.cn.h)
# ----------------------------------------------------------------------------
hello-cn: hello.c $(GEN_H) $(GEN_C) $(I18N_C) LANG.cn.h
	@echo "[build] $@ (i18n, embedded Chinese) ..."
	$(CC) $(CFLAGS) -I$(I18N_DIR) -I. \
	    -DI18N_ENABLED -DUSE_CN \
	    -o $@ hello.c $(I18N_C) $(GEN_C)
	@echo "[build] $@ done."

# ----------------------------------------------------------------------------
# test: full integration test (test.sh covers gen → UPDATED → settle)
# ----------------------------------------------------------------------------
test:
	@echo "[test] Running integration test ..."
	bash test.sh

# ----------------------------------------------------------------------------
# clean
# ----------------------------------------------------------------------------
clean:
	@echo "[clean] Removing generated and built files ..."
	rm -f hello hello-i18n hello-cn
	rm -f $(GEN_H) $(GEN_C) $(I18N_RC)
	@echo "[clean] Done."
