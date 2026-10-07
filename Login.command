#!/bin/zsh
# Use Claude Code's own browser login; this app never handles passwords or refresh tokens.
for claude_cli in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    if [[ -x "$claude_cli" ]]; then
        "$claude_cli" auth login
        exit $?
    fi
done
printf '%s\n' 'Claude Code не найден. Установите его с https://code.claude.com/docs/en/setup'
read -r '?Нажмите Enter, чтобы закрыть окно.'
