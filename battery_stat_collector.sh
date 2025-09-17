#!/bin/bash

BAT_PATH="/sys/class/power_supply/qcom-battery"
STATE_FILE="/root/.cache/batt-state"
LOG_FILE="/root/.cache/batt-log.csv"

mkdir -p "$(dirname "$STATE_FILE")"
[ -f "$LOG_FILE" ] || echo "timestamp,voltage(V),current(mA),capacity(%),status" > "$LOG_FILE"

while true; do

    BAT_V=$(awk '{printf "%.2f", $1/1e6}' "$BAT_PATH/voltage_now" 2>/dev/null || echo "0")
    BAT_I=$(awk '{printf "%.0f", $1/1e3}' "$BAT_PATH/current_now" 2>/dev/null || echo "0")
    BAT_C=$(cat "$BAT_PATH/capacity" 2>/dev/null || echo "0")
    BAT_S=$(cat "$BAT_PATH/status" 2>/dev/null || echo "Unknown")

	if [ "$BAT_C" -ge 80 ]; then
		icon="🟢"
	elif [ "$BAT_C" -ge 50 ]; then
		icon="🟡"
	elif [ "$BAT_C" -ge 20 ]; then
		icon="🟠"
	elif [ "$BAT_C" -ge 10 ]; then
		icon="🔴"
	else
		icon="⚠️"
	fi

	if [ "$BAT_S" = "Charging" ]; then
		power_source="⚡"
	else
		power_source="🔋"
	fi

    {
	echo -e "POW_SOURCE=\"$power_source"\"
	echo -e "POW_ICON=\"$icon"\"
	echo -e "POW_LEVEL=\"$BAT_C"\"
    } > "$STATE_FILE"

    echo "$(date +%s),$BAT_V,$BAT_I,$BAT_C,$icon,$BAT_S,$power_source" >> "$LOG_FILE"
    sleep 5

done
