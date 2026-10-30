#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/typecheck.sh —— OutdoorPhotoAssistant 的「类型检查闸门」。
#
# 用法: bash scripts/typecheck.sh
#       SOFT_TESTS=1 bash scripts/typecheck.sh   # 自测台失败降级为警告（默认关闭）
#
# 为什么需要这个脚本：
#   scripts/check_swift.py 只做 tree-sitter 语法检查（括号 / 结构平衡），
#   它看不见「未定义符号」「参数标签写错」「类型不匹配」「iOS 版本 API 不可用」
#   这类真正的语义错误；这些错误只会在后面的 xcodebuild 才炸出来，反馈慢。
#   `swiftc -typecheck` 只做语义分析、不产生任何产物，几秒内就能把这类错误挡在
#   「编译前源码」阶段。
#
# 五个步骤：
#   1. 选最新已安装的 Xcode，打印 xcodebuild 版本与 iphoneos SDK 路径
#   2. 对 app 全部 Swift 源码做 swiftc -typecheck（核心）
#   3. 跑仓库自查：scripts/check_swift.py（语法）+ scripts/verify.py（项目一致性）
#   4. 编译并运行全部 Foundation-only 自测台，任何一个编译/断言失败都算失败
#   5. 打印 == TYPECHECK SUMMARY ==，最后一行 RESULT: PASS 或 RESULT: FAIL
#
# 约定：
#   - 需要 macOS + 完整 Xcode；Linux / Windows 立刻 exit 2，绝不假装成功
#   - 脚本自己 cd 到仓库根，内部全部用仓库相对路径，可以在任意目录调用
#   - 不写死 /Users/xxx，不下载任何第三方工具（只用 Xcode 自带 + 已有 pip 依赖）
#   - 任何一项失败 -> 脚本最终非零退出（软降级只在 SOFT_TESTS=1 时对自测台生效）
# ---------------------------------------------------------------------------
set -euo pipefail

# 本脚本可以从任意目录调用：先锚定仓库根，再把它当工作目录。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ARTICLE_DIR="OutdoorPhotoAssistant"
BUILD_DIR="build"
LOG_DIR="${BUILD_DIR}/typecheck-logs"
TRIPLE="arm64-apple-ios17.6"
SOFT_TESTS="${SOFT_TESTS:-0}"

FAILED=0
SUMMARY_LINES=()
XCODE_VERSION="unknown"
XCODE_PATH="unknown"
SDK="unknown"
SDK_VERSION="unknown"
APP_FILE_COUNT=0

ok()  { SUMMARY_LINES+=("PASS  $1"); printf 'PASS  %s\n' "$1"; }
bad() { SUMMARY_LINES+=("FAIL  $1"); printf 'FAIL  %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }
warn() { SUMMARY_LINES+=("WARN  $1"); printf 'WARN  %s\n' "$1" >&2; }

# ---------------------------------------------------------------------------
# 0. 平台闸门：没有 Xcode 的环境必须明确退出（exit 2），不能静默成功。
# ---------------------------------------------------------------------------
if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]] \
   || ! command -v xcrun >/dev/null 2>&1 \
   || ! command -v xcodebuild >/dev/null 2>&1; then
  cat >&2 <<'MSG'
==============================================================
TYPECHECK BLOCKED: 需要 macOS + Xcode
--------------------------------------------------------------
swiftc -typecheck 只有装了完整 Xcode 的 macOS 才能跑：
  - Linux / Windows 上既没有 xcrun，也没有 iphoneos SDK
  - 本脚本不会在没有 Xcode 的机器上假装 PASS
在 macOS 上执行：
  bash scripts/typecheck.sh
或者推到 GitHub，看 ios-unsigned-build.yml 里的 typecheck job。
（Windows 开发机上只能跑 python scripts/verify.py 与 scripts/check_swift.py）
==============================================================
MSG
  exit 2
fi

mkdir -p "$BUILD_DIR" "$LOG_DIR"

echo "=============================================================="
echo "== 1/5 选择最新已安装的 Xcode"
echo "=============================================================="
XCODE_APP="$(find /Applications -maxdepth 1 -name 'Xcode*.app' 2>/dev/null | sort -V | tail -n 1 || true)"
if [[ -n "${XCODE_APP}" ]]; then
  echo "找到: ${XCODE_APP}"
else
  echo "!! /Applications 下没有 Xcode*.app，沿用当前 xcode-select 的选择" >&2
fi

# CI runner 上 sudo 免密；本地如果没权限就沿用当前选择，不因为切换失败而中断。
if [[ -n "${XCODE_APP}" ]]; then
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    xcode-select --switch "${XCODE_APP}/Contents/Developer"
  elif sudo -n true >/dev/null 2>&1; then
    sudo xcode-select --switch "${XCODE_APP}/Contents/Developer"
  elif ! xcode-select --switch "${XCODE_APP}/Contents/Developer" 2>/dev/null; then
    echo "!! 无 sudo 权限切换 Xcode，沿用当前选择" >&2
  fi
fi

XCODE_PATH="$(xcode-select -p)"
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
echo "xcodebuild : ${XCODE_VERSION}"
echo "Developer  : ${XCODE_PATH}"
echo "SDK        : ${SDK} (${SDK_VERSION})"

echo
echo "=============================================================="
echo "== 2/5 类型检查 app 全部 Swift 源码（swiftc -typecheck）"
echo "=============================================================="
# 用 while read 收集而不是 mapfile：macOS 自带的 bash 3.2 没有 mapfile。
# 用数组而不是未加引号的 $(find ...)：路径带空格也不会被拆词。
APP_SOURCES=()
while IFS= read -r swift_file; do
  APP_SOURCES+=("${swift_file}")
done < <(find "${ARTICLE_DIR}" -name '*.swift' -print 2>/dev/null | sort)
APP_FILE_COUNT="${#APP_SOURCES[@]}"

if [[ "${APP_FILE_COUNT}" -eq 0 ]]; then
  bad "app 源码列表为空（${ARTICLE_DIR} 下没有 .swift）"
else
  echo "待检查文件: ${APP_FILE_COUNT} 个（目标 ${TRIPLE}，SDK ${SDK_VERSION}）"
  TYPE_LOG="${LOG_DIR}/typecheck-app.log"
  if xcrun swiftc -typecheck -sdk "${SDK}" -target "${TRIPLE}" \
       -swift-version 5 "${APP_SOURCES[@]}" >"${TYPE_LOG}" 2>&1; then
    ok "类型检查 app 源码（${APP_FILE_COUNT} 个文件，swiftc -typecheck）"
  else
    ERROR_COUNT="$(grep -c ': error:' "${TYPE_LOG}" 2>/dev/null || true)"
    echo "类型检查失败，错误行数: ${ERROR_COUNT:-?}（完整日志：${TYPE_LOG}）" >&2
    sed -n '1,120p' "${TYPE_LOG}" >&2 || true
    # Warnings can fill the first 120 lines. Print actual errors as well so
    # cloud logs always retain the actionable failure locations.
    grep ': error:' "${TYPE_LOG}" >&2 || true
    bad "类型检查 app 源码（${APP_FILE_COUNT} 个文件，swiftc -typecheck）"
  fi
fi

echo
echo "=============================================================="
echo "== 3/5 仓库自查脚本（check_swift.py + verify.py）"
echo "=============================================================="
PYTHON=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON="python"
fi

if [[ -z "${PYTHON}" ]]; then
  bad "找不到 python3 / python，自查脚本无法运行"
else
  # requirements-check.txt 里有依赖时先装上（CI 里前面已经装过，这里是本地兜底）。
  if [[ -f scripts/requirements-check.txt ]] \
     && ! "${PYTHON}" -c 'import tree_sitter_swift, tree_sitter, yaml, pbxproj' >/dev/null 2>&1; then
    echo "安装 Python 检查依赖: ${PYTHON} -m pip install -r scripts/requirements-check.txt"
    if ! "${PYTHON}" -m pip install -r scripts/requirements-check.txt; then
      warn "pip install 失败，自查脚本可能因缺依赖而失败"
    fi
  fi

  if "${PYTHON}" scripts/check_swift.py "${ARTICLE_DIR}"; then
    ok "tree-sitter 语法检查（scripts/check_swift.py）"
  else
    bad "tree-sitter 语法检查（scripts/check_swift.py）"
  fi

  if "${PYTHON}" scripts/verify.py; then
    ok "项目一致性检查（scripts/verify.py）"
  else
    bad "项目一致性检查（scripts/verify.py）"
  fi
fi

echo
echo "=============================================================="
echo "== 4/5 编译并运行自测台（编译失败/断言失败都算失败）"
echo "=============================================================="
# run_test <名字> <swiftc 参数...>
# 编译参数第一个是名字，其余原样传给 xcrun swiftc（源文件顺序不影响语义）。
run_test() {
  local name="${1:-}"
  if [[ -z "${name}" ]]; then
    bad "run_test 调用缺少名字"
    return 0
  fi
  shift || true

  local bin="${BUILD_DIR}/${name}-tests"
  local log="${LOG_DIR}/${name}.log"
  local missing=0
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == *.swift && ! -f "${arg}" ]]; then
      printf '   FAIL 自测台 %s 缺少源文件: %s\n' "${name}" "${arg}" >&2
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    bad "自测台 ${name}（源文件缺失）"
    return 0
  fi

  printf -- '-- 自测台 %s\n   xcrun swiftc %s -o %s\n' "${name}" "$*" "${bin}"
  if xcrun swiftc "$@" -o "${bin}" >"${log}" 2>&1; then
    if "${bin}" >>"${log}" 2>&1; then
      ok "自测台 ${name}"
    else
      printf '   FAIL 自测台 %s 运行期断言失败（日志：%s）\n' "${name}" "${log}" >&2
      tail -n 40 "${log}" >&2 || true
      if [[ "${SOFT_TESTS}" == "1" ]]; then
        warn "自测台 ${name} 断言失败（SOFT_TESTS=1 已降级为警告）"
      else
        bad "自测台 ${name}（断言失败）"
      fi
    fi
  else
    printf '   FAIL 自测台 %s 编译失败（日志：%s）\n' "${name}" "${log}" >&2
    sed -n '1,80p' "${log}" >&2 || true
    if [[ "${SOFT_TESTS}" == "1" ]]; then
      warn "自测台 ${name} 编译失败（SOFT_TESTS=1 已降级为警告）"
    else
      bad "自测台 ${name}（编译失败）"
    fi
  fi
  return 0
}

# --- 以下命令与 .github/workflows/ios-unsigned-build.yml 里现有的测试 step 逐字对应 ---
# 快门决策（tests/main.swift）
run_test shutter \
  "${ARTICLE_DIR}/Core/Analysis/SmartShutterEngine.swift" tests/main.swift

# 导演决策与偏好（tests/director）
run_test director \
  "${ARTICLE_DIR}/Core/Analysis/DirectorEngine.swift" tests/director/main.swift

# 取景布局（tests/layout）
run_test layout \
  "${ARTICLE_DIR}/Features/Capture/CaptureLayout.swift" tests/layout/main.swift

# 分析评分（FrameScoring + DirectorEngine，tests/analysis）
run_test analysis \
  "${ARTICLE_DIR}/Core/Analysis/FrameScoring.swift" \
  "${ARTICLE_DIR}/Core/Analysis/DirectorEngine.swift" \
  tests/analysis/main.swift

# 云端 API 契约（tests/cloud，带 @main，所以要 -parse-as-library）
run_test cloud -parse-as-library \
  "${ARTICLE_DIR}/Core/Cloud/CloudAPI.swift" \
  "${ARTICLE_DIR}/Core/Cloud/CloudConfiguration.swift" \
  tests/cloud/main.swift

# Lightroom XMP 预设解析（tests/lightroom，用 TEST_STUBS 顶替 app 内模型）
run_test lightroom -D TEST_STUBS \
  tests/lightroom/main.swift \
  "${ARTICLE_DIR}/Core/CommercialRetouch/LightroomPresetParser.swift"

# ACR Develop 引擎复刻（tests/acrdevelop，CoreImage 行为断言 15 组）
run_test acrdevelop \
  "${ARTICLE_DIR}/Core/CommercialRetouch/ACRDevelopEngine.swift" \
  tests/acrdevelop/main.swift

# ACR 外围引擎（tests/acrlens：镜头/几何/修补/AI 替代，12 组断言）
run_test acrlens \
  "${ARTICLE_DIR}/Core/CommercialRetouch/ACRLensRepairEngine.swift" \
  tests/acrlens/main.swift
echo "=============================================================="
echo "== 5/5 TYPECHECK SUMMARY"
echo "=============================================================="
echo "== TYPECHECK SUMMARY =="
printf 'Xcode        : %s\n' "${XCODE_VERSION}"
printf 'Xcode 路径   : %s\n' "${XCODE_PATH}"
printf 'SDK          : %s (%s)\n' "${SDK}" "${SDK_VERSION}"
printf '目标三元组   : %s\n' "${TRIPLE}"
printf 'app 源文件数 : %s\n' "${APP_FILE_COUNT}"
printf '日志目录     : %s\n' "${LOG_DIR}"
if [[ "${#SUMMARY_LINES[@]}" -gt 0 ]]; then
  for line in "${SUMMARY_LINES[@]}"; do
    printf '%s\n' "${line}"
  done
fi
if [[ "${FAILED}" -eq 0 ]]; then
  printf 'RESULT: PASS\n'
  exit 0
fi
printf 'RESULT: FAIL（%d 项失败）\n' "${FAILED}"
exit 1
