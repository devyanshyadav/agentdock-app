#!/bin/bash
# Observe lifecycle; PreToolUse is registered only for native request-prompt tools.
event="${1:-}"
case "$event" in PreInvocation|PreToolUse|PostToolUse|Stop|StatusLine) ;; *) printf '{}\n'; exit 0 ;; esac
port_dir="$HOME/Library/Application Support/AgentDock"
port= token=
{ IFS= read -r port < "$port_dir/bridge-port"; } 2>/dev/null
{ IFS= read -r token < "$port_dir/bridge-token"; } 2>/dev/null
ready=
[[ "$port" =~ ^[0-9]+$ && "$token" =~ ^[0-9A-Fa-f-]+$ ]] && ready=1
# The app resolves the agent process from this parent PID (GUI app parents are ignored).
ppid_header=(-H "X-AgentDock-Ppid: $PPID")
# Without the app's port and secret nothing is sent; delivery is capped well under a second
# because hooks run synchronously inside the agent.
send() {
    if [ -n "$ready" ]; then
        /usr/bin/curl --silent --output /dev/null --connect-timeout 0.3 --max-time 0.5 --noproxy '*' \
            -H 'Content-Type: application/json' -H "X-AgentDock-Token: $token" "${ppid_header[@]}" \
            --data-binary @- "http://127.0.0.1:$port/antigravity-event/$event" 2>/dev/null
    else
        cat >/dev/null
    fi
}
if [ "$event" = StatusLine ]; then
    payload=$(cat)
    printf '%s' "$payload" | send
    if [ -n "${2:-}" ]; then printf '%s' "$payload" | /bin/sh -c "$2"; fi
elif [ "$event" = Stop ]; then
    send
    printf '{"decision":"stop"}\n'
else
    send
    if [ "$event" = PreToolUse ]; then printf '{"decision":"allow"}\n'; else printf '{}\n'; fi
fi
exit 0
