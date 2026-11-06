#!/bin/sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH
if ! command -v node >/dev/null 2>&1; then echo '需要 Node.js 18 或更新版本。'; exit 1; fi
if ! command -v "${AI_MEMORY_CLI:-ai-memory}" >/dev/null 2>&1; then echo '找不到 ai-memory，请先配置 CLI 或 AI_MEMORY_CLI。'; exit 1; fi
if [ "${1:-}" = "--open" ] && command -v open >/dev/null 2>&1; then
  (sleep 1; open "http://127.0.0.1:${PORT:-47890}") &
fi
exec node server.js
