#!/usr/bin/env bash
# AuraWall Master E2E Test Runner
# Compatible with macOS default GNU bash 3.2.57 (no Bash 4+ features).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
E2E_DIR="${ROOT_DIR}/Tests/E2E"
FIXTURES_DIR="${E2E_DIR}/fixtures"
TESTING_MACROS_DYLIB="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

MODE="full"
TIER="all"
NO_LIVE="0"

usage() {
  cat <<'EOF'
Usage: bash scripts/e2e_run.sh [--pre-bundle | --full] [--tier 1|2|3|4|all] [--no-live]

Options:
  --pre-bundle      Gracefully skip M1-M4 build/bundle checks if Package.swift or build/AuraWall.app is absent
  --full            Enforce full verification including Swift build/tests, SwiftE2E, bundle.sh & app launch (default)
  --tier <1..4|all> Run only the specified tier or all tiers (default: all)
  --no-live         Skip live external internet smoke checks (offline mock server + fixtures only)
  -h, --help        Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pre-bundle)
      MODE="pre-bundle"
      shift
      ;;
    --full)
      MODE="full"
      shift
      ;;
    --tier)
      if [ $# -lt 2 ]; then
        echo "Error: --tier requires an argument (1|2|3|4|all)" >&2
        exit 2
      fi
      TIER="$2"
      shift 2
      ;;
    --no-live)
      NO_LIVE="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$TIER" in
  1|2|3|4|all) ;;
  *)
    echo "Error: Invalid --tier value '$TIER' (expected 1|2|3|4|all)" >&2
    exit 2
    ;;
esac

if [ -d "${HOME}/.gemini/antigravity/scratch" ]; then
  TMP_PARENT="${HOME}/.gemini/antigravity/scratch/teamwork_tmp/e2e_runs"
else
  TMP_PARENT="${ROOT_DIR}/.build/e2e_runs"
fi
mkdir -p "${TMP_PARENT}"
E2E_RUN_TMP="$(mktemp -d "${TMP_PARENT}/run.XXXXXX")"
READY_FILE="${E2E_RUN_TMP}/mock_server.ready"
MOCK_LOG="${E2E_RUN_TMP}/mock_server.log"
E2E_TMP_HOME="${E2E_RUN_TMP}/isolated_home"
mkdir -p "${E2E_TMP_HOME}/Library/Application Support" "${E2E_TMP_HOME}/Library/Caches"

MOCK_PID=""
ACTIVE_CHILD_PID=""
CLEANUP_DONE="0"

kill_pid_tree() {
  local pid="$1"
  local sig="${2:-TERM}"
  local children=""
  local child=""
  if [ -z "${pid}" ]; then
    return 0
  fi
  children="$(pgrep -P "${pid}" 2>/dev/null || true)"
  for child in ${children}; do
    kill_pid_tree "${child}" "${sig}"
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill "-${sig}" "${pid}" 2>/dev/null || true
  fi
}

stop_pid_gracefully() {
  local pid="$1"
  local tries=0
  if [ -z "${pid}" ]; then
    return 0
  fi
  kill_pid_tree "${pid}" TERM
  while kill -0 "${pid}" 2>/dev/null && [ "${tries}" -lt 10 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill_pid_tree "${pid}" KILL
  fi
  wait "${pid}" 2>/dev/null || true
}

cleanup() {
  if [ "${CLEANUP_DONE}" = "1" ]; then
    return 0
  fi
  CLEANUP_DONE="1"
  if [ -n "${ACTIVE_CHILD_PID}" ]; then
    stop_pid_gracefully "${ACTIVE_CHILD_PID}"
    ACTIVE_CHILD_PID=""
  fi
  if [ -n "${MOCK_PID}" ]; then
    stop_pid_gracefully "${MOCK_PID}"
    MOCK_PID=""
  fi
  if [ -n "${E2E_RUN_TMP:-}" ] && [ -d "${E2E_RUN_TMP}" ]; then
    rm -rf "${E2E_RUN_TMP}"
  fi
}

on_int() {
  trap - EXIT INT TERM
  cleanup
  exit 130
}

on_term() {
  trap - EXIT INT TERM
  cleanup
  exit 143
}

trap cleanup EXIT
trap on_int INT
trap on_term TERM

run_step() {
  local workdir="$1"
  shift
  local rc=0
  (
    cd "${workdir}" && exec "$@"
  ) &
  ACTIVE_CHILD_PID=$!
  if wait "${ACTIVE_CHILD_PID}"; then
    rc=0
  else
    rc=$?
  fi
  ACTIVE_CHILD_PID=""
  return "${rc}"
}

# Bash 3.2-compatible summary tracking via indexed arrays
SUMMARY_NAMES=()
SUMMARY_STATUSES=()
SUMMARY_DETAILS=()
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

record_result() {
  local name="$1"
  local status="$2"
  local detail="$3"
  SUMMARY_NAMES[${#SUMMARY_NAMES[@]}]="${name}"
  SUMMARY_STATUSES[${#SUMMARY_STATUSES[@]}]="${status}"
  SUMMARY_DETAILS[${#SUMMARY_DETAILS[@]}]="${detail}"
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    SKIPPED) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
  esac
}

echo "=== AuraWall E2E Runner (mode=${MODE}, tier=${TIER}, no_live=${NO_LIVE}) ==="

# 1. Start Mock HTTP Server
python3 "${E2E_DIR}/e2e_support.py" --serve --ready-file "${READY_FILE}" >"${MOCK_LOG}" 2>&1 &
MOCK_PID=$!

WAIT_TRIES=0
while [ ! -s "${READY_FILE}" ]; do
  if ! kill -0 "${MOCK_PID}" 2>/dev/null; then
    echo "Error: Mock HTTP server exited prematurely:" >&2
    cat "${MOCK_LOG}" >&2 || true
    exit 1
  fi
  WAIT_TRIES=$((WAIT_TRIES + 1))
  if [ "${WAIT_TRIES}" -ge 100 ]; then
    echo "Error: Timed out waiting for Mock HTTP server ready file" >&2
    exit 1
  fi
  sleep 0.1
done

MOCK_URL="$(tr -d '\r\n' < "${READY_FILE}")"
export AURAWALL_E2E_MOCK_URL="${MOCK_URL}"
export AURAWALL_E2E_FIXTURES_DIR="${FIXTURES_DIR}"
export AURAWALL_E2E_MODE="${MODE}"
export AURAWALL_E2E_NO_LIVE="${NO_LIVE}"
if [ "${NO_LIVE}" = "0" ]; then
  export AURAWALL_RUN_LIVE_SMOKE="1"
else
  export AURAWALL_RUN_LIVE_SMOKE="0"
fi

echo "Mock HTTP Server listening at: ${AURAWALL_E2E_MOCK_URL}"

APP_BUNDLE="${ROOT_DIR}/build/AuraWall.app"
BUNDLE_SCRIPT="${ROOT_DIR}/scripts/bundle.sh"

# In --full mode, ensure build/AuraWall.app exists via scripts/bundle.sh BEFORE Track A runs
# (clean checkouts delete build/AuraWall.app, and Tier 1/2 Track A tests inspect and re-run bundle.sh).
if [ "${MODE}" = "full" ]; then
  if [ -f "${BUNDLE_SCRIPT}" ] && [ -f "${ROOT_DIR}/Package.swift" ]; then
    echo ""
    echo "--- Running scripts/bundle.sh (pre-Track-A clean-checkout guarantee) ---"
    if run_step "${ROOT_DIR}" bash "${BUNDLE_SCRIPT}"; then
      record_result "Bundle Script (scripts/bundle.sh)" "PASS" "produced build/AuraWall.app"
    else
      record_result "Bundle Script (scripts/bundle.sh)" "FAIL" "bundle.sh failed"
    fi
  else
    echo "Bundle Script: FAIL (scripts/bundle.sh or Package.swift absent in --full mode)" >&2
    record_result "Bundle Script (scripts/bundle.sh)" "FAIL" "scripts/bundle.sh or Package.swift missing"
  fi
fi

# 2. Run Track A Python suites matching --tier
run_track_a_tier() {
  local tier_num="$1"
  local test_file="$2"
  local module_name="${test_file%.py}"
  local label="Track A Tier ${tier_num} (${test_file})"
  echo ""
  echo "--- Running ${label} ---"
  if run_step "${E2E_DIR}" env PYTHONPATH="${E2E_DIR}" python3 -m unittest -v "${module_name}"; then
    record_result "${label}" "PASS" "unittest passed"
  else
    record_result "${label}" "FAIL" "unittest failed"
  fi
}

case "$TIER" in
  1) run_track_a_tier 1 "test_tier1_features.py" ;;
  2) run_track_a_tier 2 "test_tier2_boundaries.py" ;;
  3) run_track_a_tier 3 "test_tier3_combinations.py" ;;
  4) run_track_a_tier 4 "test_tier4_scenarios.py" ;;
  all)
    run_track_a_tier 1 "test_tier1_features.py"
    run_track_a_tier 2 "test_tier2_boundaries.py"
    run_track_a_tier 3 "test_tier3_combinations.py"
    run_track_a_tier 4 "test_tier4_scenarios.py"
    ;;
esac

# 3. Swift Package Build, Unit Tests & Track B (SwiftE2E)
MACROS_ARGS=()
if [ -f "${TESTING_MACROS_DYLIB}" ]; then
  MACROS_ARGS=(-Xswiftc -load-plugin-library -Xswiftc "${TESTING_MACROS_DYLIB}")
fi

if [ ! -f "${ROOT_DIR}/Package.swift" ]; then
  if [ "${MODE}" = "pre-bundle" ]; then
    echo "Swift Build & Unit Tests: SKIPPED (pre-bundle: Package.swift absent)"
    echo "Track B (SwiftE2E): SKIPPED (pre-bundle: Package.swift absent)"
    record_result "Swift Build & Unit Tests" "SKIPPED" "pre-bundle: Package.swift absent"
    record_result "Track B (SwiftE2E)" "SKIPPED" "pre-bundle: Package.swift absent"
  else
    echo "Swift Build & Unit Tests: FAIL (Package.swift absent in --full mode)" >&2
    record_result "Swift Build & Unit Tests" "FAIL" "Package.swift absent in --full mode"
    record_result "Track B (SwiftE2E)" "FAIL" "Package.swift absent in --full mode"
  fi
else
  echo ""
  echo "--- Running swift build --disable-sandbox ---"
  if run_step "${ROOT_DIR}" swift build --disable-sandbox; then
    record_result "Swift Build" "PASS" "swift build --disable-sandbox exited 0"
  else
    record_result "Swift Build" "FAIL" "swift build --disable-sandbox failed"
  fi

  echo ""
  echo "--- Running swift test --disable-sandbox ---"
  if run_step "${ROOT_DIR}" swift test --disable-sandbox ${MACROS_ARGS[@]+"${MACROS_ARGS[@]}"}; then
    record_result "Swift Unit Tests (AuraWallCoreTests)" "PASS" "swift test exited 0"
  else
    record_result "Swift Unit Tests (AuraWallCoreTests)" "FAIL" "swift test failed"
  fi

  SWIFTE2E_PKG="${E2E_DIR}/SwiftE2E/Package.swift"
  if [ ! -f "${SWIFTE2E_PKG}" ]; then
    if [ "${MODE}" = "pre-bundle" ]; then
      echo "Track B (SwiftE2E): SKIPPED (pre-bundle: Tests/E2E/SwiftE2E/Package.swift absent)"
      record_result "Track B (SwiftE2E)" "SKIPPED" "pre-bundle: SwiftE2E/Package.swift absent"
    else
      echo "Track B (SwiftE2E): FAIL (Tests/E2E/SwiftE2E/Package.swift absent)" >&2
      record_result "Track B (SwiftE2E)" "FAIL" "SwiftE2E/Package.swift absent in --full mode"
    fi
  elif [ "${MODE}" = "pre-bundle" ] && { [ ! -d "${ROOT_DIR}/Sources/AuraWallCore/Providers" ] || [ ! -d "${ROOT_DIR}/Sources/AuraWallCore/Power" ] || [ ! -d "${ROOT_DIR}/Sources/AuraWallCore/Engine" ]; }; then
    echo "Track B (SwiftE2E): SKIPPED (pre-bundle: M2/M3 AuraWallCore modules not yet present)"
    record_result "Track B (SwiftE2E)" "SKIPPED" "pre-bundle: M2/M3 AuraWallCore modules absent"
  else
    echo ""
    echo "--- Running Track B (SwiftE2E) ---"
    FILTER_ARGS=()
    if [ "${TIER}" != "all" ]; then
      FILTER_ARGS=(--filter "Tier${TIER}")
    fi
    if run_step "${ROOT_DIR}" swift test --package-path "${E2E_DIR}/SwiftE2E" --scratch-path "${ROOT_DIR}/.build/swift-e2e" --disable-sandbox ${MACROS_ARGS[@]+"${MACROS_ARGS[@]}"} ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"}; then
      record_result "Track B (SwiftE2E)" "PASS" "tier=${TIER}"
    else
      record_result "Track B (SwiftE2E)" "FAIL" "SwiftE2E failed (tier=${TIER})"
    fi
  fi
fi

# 4. App Launch Verification (bundle.sh already ran before Track A in --full mode)
if [ ! -d "${APP_BUNDLE}" ]; then
  if [ "${MODE}" = "pre-bundle" ]; then
    echo "Bundle & App Launch: SKIPPED (pre-bundle: build/AuraWall.app absent)"
    record_result "Bundle & App Launch" "SKIPPED" "pre-bundle: build/AuraWall.app absent"
  else
    echo "Bundle & App Launch: FAIL (build/AuraWall.app absent in --full mode)" >&2
    record_result "Bundle & App Launch" "FAIL" "build/AuraWall.app missing"
  fi
else
  echo ""
  echo "--- Verifying build/AuraWall.app (arm64, plutil, codesign, isolated launch + SIGTERM) ---"
  if run_step "${ROOT_DIR}" env PYTHONPATH="${E2E_DIR}" python3 -c '
import sys
from pathlib import Path
from e2e_support import (
    validate_plist,
    validate_macho_arm64,
    validate_codesign,
    launch_app_and_verify_sigterm,
)

app = Path(sys.argv[1])
tmp_home = Path(sys.argv[2])
plist_data = validate_plist(app / "Contents" / "Info.plist")
arch_info = validate_macho_arm64(app / "Contents" / "MacOS" / "AuraWall")
cs_info = validate_codesign(app)
launch_res = launch_app_and_verify_sigterm(app, tmp_home)
exec_name = plist_data["CFBundleExecutable"]
lipo_arch = arch_info["lipo"]
launch_rc = launch_res["returncode"]
print(f"Bundle verified: exec={exec_name} arch={lipo_arch} launch_rc={launch_rc}")
' "${APP_BUNDLE}" "${E2E_TMP_HOME}"; then
    record_result "Bundle & App Launch" "PASS" "arm64, plutil, codesign, SIGTERM OK"
  else
    record_result "Bundle & App Launch" "FAIL" "bundle or app launch check failed"
  fi
fi

# 5. Summary Table
echo ""
echo "============================================================================"
printf "%-42s | %-8s | %s\n" "Step" "Status" "Details"
echo "----------------------------------------------------------------------------"
IDX=0
TOTAL=${#SUMMARY_NAMES[@]}
while [ "${IDX}" -lt "${TOTAL}" ]; do
  printf "%-42s | %-8s | %s\n" "${SUMMARY_NAMES[$IDX]}" "${SUMMARY_STATUSES[$IDX]}" "${SUMMARY_DETAILS[$IDX]}"
  IDX=$((IDX + 1))
done
echo "============================================================================"
echo "Totals: PASS=${PASS_COUNT}  FAIL=${FAIL_COUNT}  SKIPPED=${SKIP_COUNT}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
