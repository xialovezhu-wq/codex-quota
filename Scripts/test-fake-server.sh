#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
temporary_dir="$(mktemp -d)"
audit_path="$temporary_dir/outbound-methods.txt"
app_pid=""

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  rm -rf "$temporary_dir"
}
trap cleanup EXIT

cd "$project_dir"
swift build --product CodexQuotaApp >/dev/null
CODEX_QUOTA_TEST_APP_SERVER="$project_dir/Tests/FakeAppServer/fake_app_server.py" \
CODEX_QUOTA_FAKE_AUDIT="$audit_path" \
  .build/debug/CodexQuotaApp &
app_pid=$!

for _ in {1..150}; do
  if [[ -f "$audit_path" ]] && [[ "$(wc -l < "$audit_path" | tr -d ' ')" -ge 4 ]]; then
    break
  fi
  sleep 0.1
done

if [[ ! -f "$audit_path" ]]; then
  print -u2 "FAIL: fake server received no requests"
  exit 1
fi

first_three="$(sed -n '1,3p' "$audit_path")"
expected_handshake=$'initialize\ninitialized\naccount/rateLimits/read'
if [[ "$first_three" != "$expected_handshake" ]]; then
  print -u2 "FAIL: handshake order was not initialize → initialized → read"
  exit 1
fi

methods="$(sort -u "$audit_path")"
unexpected="$(print -r -- "$methods" | grep -Ev '^(initialize|initialized|account/rateLimits/read)$' || true)"
if [[ -n "$unexpected" ]]; then
  print -u2 "FAIL: unexpected outbound method: $unexpected"
  exit 1
fi

read_count="$(grep -c '^account/rateLimits/read$' "$audit_path" || true)"
if [[ "$read_count" -lt 2 ]]; then
  print -u2 "FAIL: update notification did not trigger a full reread"
  exit 1
fi

print "PASS: fragmented JSONL, interleaved notification, reread, EOF handling, outbound audit"
