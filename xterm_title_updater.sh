#!/bin/bash
while true; do

	STATE_FILE="/root/.cache/batt-state"
	source $STATE_FILE
        echo -ne "\033]0;${POW_SOURCE}${POW_LEVEL}% $USER@$HOSTNAME: $PWD${POW_ICON}\007" > /dev/tty
	sleep 5

done
