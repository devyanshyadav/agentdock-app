#!/bin/bash
# Neutral native hook observer: never grant approvals, block work, or inject context.
port_dir="$HOME/Library/Application Support/AgentDock"
port= token=
{ IFS= read -r port < "$port_dir/bridge-port"; } 2>/dev/null
{ IFS= read -r token < "$port_dir/bridge-token"; } 2>/dev/null
surface=desktop
pid_header=()
if [ -n "${TERM_PROGRAM:-}" ]; then
    surface=cli
    # The app resolves the agent process from this parent PID (see ProcessLineage).
    pid_header=(-H "X-AgentDock-Ppid: $PPID")
fi
# Without the app's port and secret nothing is sent; delivery is capped well under a second
# because hooks run synchronously inside the agent.
if [[ "$port" =~ ^[0-9]+$ && "$token" =~ ^[0-9A-Fa-f-]+$ ]]; then
    /usr/bin/curl --silent --output /dev/null --connect-timeout 0.3 --max-time 0.5 --noproxy '*' \
        -H 'Content-Type: application/json' -H "X-AgentDock-Token: $token" "${pid_header[@]}" \
        --data-binary @- "http://127.0.0.1:$port/codex-event/$surface" 2>/dev/null
else
    cat >/dev/null
fi
printf '{}\n'
exit 0
