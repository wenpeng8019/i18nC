# i18n/test/CMakeLists.txt
#
# Standalone build for the i18n Hello World example and integration tests.
#
# Three build modes (separate executables):
#   hello       -- literal mode (no i18n runtime, zero-dependency demo)
#   hello-i18n  -- I18N mode with default English table
#   hello-cn    -- I18N mode with static embedded Chinese
#
# Two codegen modes (same executables, different enum layout):
#   gen         -- debug mode: SID-based stable IDs with gap placeholders
#   gen-ndebug  -- release mode: compact sequential IDs (--ndebug)
#
# Workflow:
#   cmake -S . -B build           # configure
#   cmake --build build -t gen    # run i18n.sh (generates .LANG.h/.LANG.c/LANG.h)
#   cmake --build build           # compile all targets
#   ctest --test-dir build        # run tests
#
# Or, to also get Chinese support:
#   cmake --build build -t import-cn   # generate/refresh LANG.cn.h
#   cmake --build build -t hello-cn    # compile Chinese variant
#
# NOTE: The 'gen' target writes back SIDs to hello.c (idempotent after the first
# run). Re-running 'gen' after adding new i18n-annotated strings is all that is
# needed to update IDs and rebuild.

cmake_minimum_required(VERSION 3.14)
project(i18n_test C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------
set(I18N_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(I18N_C   "${I18N_DIR}/i18n.c")

# Generated files live in the SOURCE directory (i18n.sh writes there)
set(LANG_H   "${CMAKE_CURRENT_SOURCE_DIR}/.LANG.h")
set(LANG_C   "${CMAKE_CURRENT_SOURCE_DIR}/.LANG.c")

# --------------------------------------------------------------------------
# gen: run i18n.sh to (re)generate .LANG.h / .LANG.c / LANG.h / .i18n
#      (debug mode: SID-based stable IDs with gap placeholders)
#
# Output files are declared so dependent targets know when to rebuild.
# Run manually whenever you add or change i18n-annotated strings:
#   cmake --build <builddir> -t gen
# --------------------------------------------------------------------------
add_custom_command(
    OUTPUT  "${LANG_H}" "${LANG_C}"
    COMMAND bash "${I18N_DIR}/i18n.sh" test --name hello
    WORKING_DIRECTORY "${I18N_DIR}"
    COMMENT "i18n: generating .LANG.h, .LANG.c, LANG.h (debug mode)"
    VERBATIM
)

add_custom_target(gen
    DEPENDS "${LANG_H}" "${LANG_C}"
    COMMENT "i18n codegen (debug mode)"
)

# --------------------------------------------------------------------------
# gen-ndebug: compact sequential IDs for release builds (--ndebug)
#   cmake --build <builddir> -t gen-ndebug
# --------------------------------------------------------------------------
add_custom_target(gen-ndebug
    COMMAND bash "${I18N_DIR}/i18n.sh" test --name hello --ndebug
    WORKING_DIRECTORY "${I18N_DIR}"
    COMMENT "i18n: generating .LANG.h, .LANG.c, LANG.h (ndebug/release mode)"
    VERBATIM
)

# --------------------------------------------------------------------------
# import-cn: generate / maintain LANG.cn.h  (3-case: new / UPDATED / unchanged)
#   cmake --build <builddir> -t import-cn
# --------------------------------------------------------------------------
add_custom_target(import-cn
    COMMAND bash "${I18N_DIR}/i18n.sh" test --name hello --import cn
    WORKING_DIRECTORY "${I18N_DIR}"
    COMMENT "i18n: refreshing LANG.cn.h"
    VERBATIM
)

# --------------------------------------------------------------------------
# hello — literal mode
#   Macros expand to English string literals; no i18n.c linked.
#   Does NOT depend on gen (works without generated files).
# --------------------------------------------------------------------------
add_executable(hello hello.c)
target_include_directories(hello PRIVATE "${I18N_DIR}")
target_compile_options(hello PRIVATE -Wall -Wextra)

# --------------------------------------------------------------------------
# hello-i18n — I18N mode, English default table
# --------------------------------------------------------------------------
add_executable(hello-i18n hello.c "${I18N_C}" "${LANG_C}")
target_include_directories(hello-i18n PRIVATE
    "${I18N_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_definitions(hello-i18n PRIVATE I18N_ENABLED)
target_compile_options(hello-i18n PRIVATE -Wall -Wextra)
add_dependencies(hello-i18n gen)

# --------------------------------------------------------------------------
# hello-cn — I18N mode, static embedded Chinese (requires LANG.cn.h)
# --------------------------------------------------------------------------
add_executable(hello-cn hello.c "${I18N_C}" "${LANG_C}")
target_include_directories(hello-cn PRIVATE
    "${I18N_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_definitions(hello-cn PRIVATE I18N_ENABLED USE_CN)
target_compile_options(hello-cn PRIVATE -Wall -Wextra)
add_dependencies(hello-cn gen)

# --------------------------------------------------------------------------
# CTest
# --------------------------------------------------------------------------
enable_testing()

add_test(NAME hello-literal   COMMAND hello)
add_test(NAME hello-i18n-en   COMMAND hello-i18n)
add_test(NAME hello-cn-static COMMAND hello-cn)
