#!/bin/bash
# Observe activity only. Gate-style hooks (preToolUse, beforeSubmitPrompt, subagentStart)
# receive no output at all: Cursor documents silent exit 0 as "no decision", whereas any
# JSON would be parsed as a permission response. No decision is ever returned.
event="${1:-}"
port_file="${AGENTDOCK_PORT_FILE:-$HOME/Library/Application Support/AgentDock/bridge-port}"
# The app publishes its port and a per-launch secret. Without both, the app is not running
# (or this is a stale file), so nothing is sent: events must never reach another local process.
token_file="${port_file%/*}/bridge-token"
port= token=
IFS= read -r port 2>/dev/null < "$port_file" || :
IFS= read -r token 2>/dev/null < "$token_file" || :
surface=ide
pid_header=()
if [ -n "${TERM_PROGRAM:-}" ]; then
    surface=cli
    # The app resolves the agent process from this parent PID (see ProcessLineage).
    pid_header=(-H "X-AgentDock-Ppid: $PPID")
fi
# Hooks run synchronously inside the agent, so delivery is capped well under a second.
if [[ "$port" =~ ^[0-9]+$ && "$token" =~ ^[0-9A-Fa-f-]+$ ]]; then
    /usr/bin/curl --silent --output /dev/null --connect-timeout 0.3 --max-time 0.5 \
      --noproxy '*' -H 'Content-Type: application/json' -H "X-AgentDock-Token: $token" "${pid_header[@]}" --data-binary @- \
      "http://127.0.0.1:$port/cursor-event/$surface" 2>/dev/null
else
    cat >/dev/null
fi
case "$event" in
    preToolUse|beforeSubmitPrompt|subagentStart) ;;
    *) printf '{}\n' ;;
esac
exit 0
