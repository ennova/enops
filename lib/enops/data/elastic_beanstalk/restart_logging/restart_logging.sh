#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

STATE_FILE=/var/lib/awslogs/agent-state
LOG_FILE=/var/log/eb-docker/containers/eb-current-app/stdouterr.log

SOURCE_ID="$(sqlite3 "$STATE_FILE" "SELECT v FROM stream_state WHERE k = '$LOG_FILE'" | jq -r .source_id)"
sqlite3 "$STATE_FILE" "DELETE FROM push_state WHERE k = '$SOURCE_ID'"

service awslogs restart
