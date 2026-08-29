#!/usr/bin/env bash
# Fails if anything that looks like a real Telegram bot token is about to be
# committed, or if the files that must stay out of git are tracked.
set -u

TOKEN_RE='[0-9]{8,12}:[A-Za-z0-9_-]{30,}'
FILES="flows.json README.md logs.md"
fail=0

for f in $FILES; do
  [ -f "$f" ] || continue
  if grep -Eq "$TOKEN_RE" "$f"; then
    echo "FAIL: token-like string found in $f"
    fail=1
  fi
done

for f in .env flows_cred.json; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    echo "FAIL: $f is tracked by git"
    fail=1
  fi
done

if [ -f .env.example ] && ! grep -q 'YOUR_TELEGRAM_TOKEN' .env.example; then
  echo "FAIL: .env.example lost its placeholder"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "OK: no secrets in tracked files"
exit "$fail"
