#!/bin/bash
# ============================================================
# Pier — Security Audit Script
# ============================================================
# Verifies App Sandbox, Hardened Runtime, entitlements, and
# code-level security practices.
#
# Usage:
#   ./scripts/security_audit.sh [path/to/Pier.app]
# ============================================================

set -euo pipefail

APP_PATH="${1:-build/Release/Pier.app}"
PASS=0
WARN=0
FAIL=0

pass()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
warn()  { WARN=$((WARN + 1)); echo "  ⚠️  $1"; }
fail()  { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

echo "========================================"
echo "  Pier Security Audit"
echo "========================================"
echo ""

# ── 1. Code Signature ──
echo "1. Code Signature"
if codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
    pass "Code signature valid"
else
    fail "Invalid or missing code signature"
fi

# ── 2. Hardened Runtime ──
echo "2. Hardened Runtime"
FLAGS=$(codesign -d --verbose "$APP_PATH" 2>&1 || true)
if echo "$FLAGS" | grep -q "runtime"; then
    pass "Hardened Runtime enabled"
else
    fail "Hardened Runtime NOT enabled"
fi

# ── 3. App Sandbox ──
echo "3. App Sandbox Entitlements"
ENTITLEMENTS=$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || echo "")
if echo "$ENTITLEMENTS" | grep -q "com.apple.security.app-sandbox"; then
    pass "App Sandbox enabled"
else
    warn "App Sandbox NOT enabled (acceptable for dev builds)"
fi

# ── 4. Network Permissions ──
echo "4. Network Permissions"
if echo "$ENTITLEMENTS" | grep -q "network.client"; then
    pass "Outgoing network permission declared"
else
    warn "No outgoing network entitlement (SSH/HTTP may fail)"
fi
if echo "$ENTITLEMENTS" | grep -q "network.server"; then
    warn "Incoming network server permission detected (review if needed)"
else
    pass "No incoming network server permission"
fi

# ── 5. File Access ──
echo "5. File System Access"
if echo "$ENTITLEMENTS" | grep -q "files.user-selected"; then
    pass "User-selected file access declared"
else
    warn "No user-selected file access"
fi
if echo "$ENTITLEMENTS" | grep -q "files.all"; then
    warn "Full file system access detected — review scope"
else
    pass "No unrestricted file system access"
fi

# ── 6. Keychain Access ──
echo "6. Keychain Access"
KEYCHAIN_GROUPS=$(echo "$ENTITLEMENTS" | grep -c "keychain-access-groups" || true)
if [ "$KEYCHAIN_GROUPS" -gt 0 ]; then
    pass "Keychain access groups declared"
else
    pass "No keychain access groups (using default)"
fi

# ── 7. Source Code Checks ──
echo "7. Source Code Security Checks"
SRC_DIR="PierApp/Sources"

# Check for hardcoded secrets
SECRETS=$(grep -rn "password\|api_key\|secret" "$SRC_DIR" --include="*.swift" \
    | grep -v "// MARK" | grep -v "localized" | grep -v "Keychain" \
    | grep -v "placeholder" | grep -v "passphrase" | grep -v "enum" || true)
if [ -z "$SECRETS" ]; then
    pass "No hardcoded secrets detected"
else
    warn "Potential hardcoded secrets found — review:"
    echo "$SECRETS" | head -5
fi

# Check for force unwraps
FORCE_UNWRAPS=$(grep -rn "!" "$SRC_DIR" --include="*.swift" \
    | grep -v "IBOutlet\|IBAction\|//\|import\|.isEmpty\|!=\|guard" \
    | grep "\![^=]" | wc -l | tr -d ' ')
if [ "$FORCE_UNWRAPS" -gt 20 ]; then
    warn "$FORCE_UNWRAPS potential force unwraps — consider safer patterns"
else
    pass "Force unwraps within acceptable range ($FORCE_UNWRAPS)"
fi

# ── Summary ──
echo ""
echo "========================================"
echo "  Results: $PASS pass, $WARN warnings, $FAIL failures"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
