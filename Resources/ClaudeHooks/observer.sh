#!/bin/bash
# Neutral native hook observer: never grant approvals, block work, or inject context.
port_dir="$HOME/Library/Application Support/AgentDock"
port= token=
{ IFS= read -r port < "$port_dir/bridge-port"; } 2>/dev/null
{ IFS= read -r token < "$port_dir/bridge-token"; } 2>/dev/null
surface=desktop
if [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "claude-vscode" ] || [ -n "${VSCODE_PID:-}${CURSOR_TRACE_ID:-}" ]; then
    surface=ide
elif [ -n "${TERM_PROGRAM:-}${SSH_TTY:-}" ] || [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "cli" ]; then
    surface=cli
fi
# The app resolves the agent process from this parent PID (see ProcessLineage).
pid_header=(-H "X-AgentDock-Ppid: $PPID")
# Without the app's port and secret nothing is sent; delivery is capped well under a second
# because hooks run synchronously inside the agent.
payload=$(cat)
# Cursor's "Third-party skills" setting loads ~/.claude/settings.json and runs Claude hooks with
# Cursor payloads ("cursor_version"). Exit silently so Cursor's native hook handles it cleanly.
case "$payload" in *'"cursor_version"'*) exit 0 ;; esac
endpoint="claude-event/$surface"
if [ "${1:-}" = StatusLine ]; then endpoint=claude-usage; fi
if [[ "$port" =~ ^[0-9]+$ && "$token" =~ ^[0-9A-Fa-f-]+$ ]]; then
    printf '%s' "$payload" | /usr/bin/curl --silent --output /dev/null --connect-timeout 0.3 --max-time 0.5 --noproxy '*' \
        -H 'Content-Type: application/json' -H "X-AgentDock-Token: $token" "${pid_header[@]}" \
        --data-binary @- "http://127.0.0.1:$port/$endpoint" 2>/dev/null
fi
if [ "${1:-}" = StatusLine ]; then
    if [ -n "${2:-}" ]; then printf '%s' "$payload" | /bin/sh -c "$2"; fi
    exit 0
fi
printf '{}\n'
exit 0
