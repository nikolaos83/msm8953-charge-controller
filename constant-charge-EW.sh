#!/usr/bin/env bash
set -u

# ==============================================================================
# Smart PI Charge Controller v12 (Corrected LED & Safety Features)
# ==============================================================================
# GOAL: Dynamically adjust USB input current to maintain a target SoC, with
#       status feedback via a single-color LED and a shutdown safety net.
#
# Updates in v12:
# - Corrected LED logic to support a single 'white' indicator LED.
# - Feedback is now provided via brightness and blink rate, not color.
# - Simplified LED configuration.
# - Event-Weighted version
# ==============================================================================

# --- (1) --- C H A R G E   C O N T R O L L E R   C O N F I G ------------------

TARGET_SOC=60
CHARGE_CURRENT_PER_SOC_DEFICIT_UA=50000
MIN_INPUT_CURRENT_UA=80000
MAX_INPUT_CURRENT_UA=1750000
KP="0.08"
KI="0.01"
LOOP_SLEEP_S=10
MIN_STEP_UA=5000
DEBUG=1

# --- (2) --- P O W E R   S A V I N G   &   S A F E T Y   C O N F I G ----------

# --- Master Power Saving Switch ---
ENABLE_POWER_SAVING_ON_BATTERY=true

# --- Emergency Shutdown ---
ENABLE_EMERGENCY_SHUTDOWN=true
EMERGENCY_SHUTDOWN_THRESHOLD=5

# --- Staged Activation Thresholds (% SoC) ---
PS_STAGE1_ACTIVATE=50 # Warning Stage (e.g., Dim LED)
PS_STAGE2_ACTIVATE=40 # Critical Stage (e.g., Blinking LED)
PS_STAGE3_ACTIVATE=30
PS_STAGE4_ACTIVATE=20
PS_STAGE5_ACTIVATE=10
PS_RECOVER_THRESHOLD=55

# --- Action-to-Stage Mapping ---
PS_STAGE_FOR_CPU_GOVERNOR=2
PS_STAGE_FOR_CPU_FREQ_CAP=3
PS_STAGE_FOR_CPU_CORE_SHUTDOWN=4
PS_STAGE_FOR_WIFI_POWERSAVE=4
PS_STAGE_FOR_BACKLIGHT=0
PS_STAGE_FOR_VM_WRITEBACK=4
PS_STAGE_FOR_BLUETOOTH=5

# --- Mode Selectors & Parameters ---
INDICATOR_LED_MODE="auto" # "auto", "always_on", "always_off", "unmanaged"
WIFI_POWERSAVE_MODE="auto"
BLUETOOTH_MODE="auto"
BACKLIGHT_MODE="force_off"

CPU_PERFORMANCE_GOVERNOR="performance"
CPU_POWERSAVE_GOVERNOR="powersave"
CPU_MAX_FREQ_POWERSAVE="800000"
CPU_CORES_TO_SHUTDOWN=(3 2 1)

VM_DIRTY_WRITEBACK_NORMAL="1500"
VM_DIRTY_WRITEBACK_POWERSAVE="3000"

# --- (3) --- S Y S T E M   P A T H S ------------------------------------------
LED_INDICATOR_DIR="/sys/class/leds/white:indicator"

LIMIT_DIR="/sys/class/power_supply/qcom-smbchg-usb"; BATTERY_DIR="/sys/class/power_supply/qcom-battery"; BACKLIGHT_DIR="/sys/class/leds/lcd-backlight"
LIMIT_FILE="$LIMIT_DIR/input_current_limit"; ONLINE_FILE="$LIMIT_DIR/online"; BATTERY_CURRENT_FILE="$BATTERY_DIR/current_now"; CAPACITY_FILE="$BATTERY_DIR/capacity"
BACKLIGHT_FILE="$BACKLIGHT_DIR/brightness"; VM_DIRTY_WRITEBACK_FILE="/proc/sys/vm/dirty_writeback_centisecs"

# --- (4) --- G L O B A L   V A R I A B L E S ----------------------------------
integral_error=0
# PI state & saturation detection
prev_abs_error=0
saturation_until=0      # epoch seconds until which increases are inhibited (saturation observed)
last_applied_limit=0
last_bat_sample=0

declare -A POWER_SAVING_STATES=([governor]=0 [freq_cap]=0 [cores]=0 [wifi]=0 [backlight]=0 [vm]=0 [bt]=0)

# --- (5) --- L O G G I N G   &   C O R E   H E L P E R S ----------------------
ESC="\033["; GREEN="${ESC}32m"; YELLOW="${ESC}33m"; RED="${ESC}31m"; BLUE="${ESC}34m"; BOLD="${ESC}1m"; RESET="${ESC}0m"
EMOJI_CHARGE="⚡"; EMOJI_BAT="🔋"; EMOJI_WARN="⚠️"; EMOJI_CPU="🧠"; EMOJI_LED="💡"; EMOJI_HALT="🛑"
log() { local c="$1"; shift; printf "%b%s%b\n" "$c" "$*" "$RESET"; }; info() { log "$GREEN" "  ${EMOJI_CHARGE} $*"; }; warn() { log "$YELLOW" "  ${EMOJI_WARN} $*"; }; crit() { log "$RED" "${EMOJI_HALT} $*"; }; debug() { [ "${DEBUG:-0}" -eq 1 ] && log "$BLUE" "  $*"; }
last_online_toggle=0; toggle_online() { now=$(date +%s); if [ $((now - last_online_toggle)) -lt 40 ]; then debug "Online toggle skipped."; return 1; fi; printf "0" > "$ONLINE_FILE" 2>/dev/null || { warn "can't write online=0"; return 1; }; sleep 1; printf "1" > "$ONLINE_FILE" 2>/dev/null || { warn "can't write online=1"; return 1; }; last_online_toggle=$now; info "Forced online cycle."; return 0; }
sample_median() { a=$(cat "$BATTERY_CURRENT_FILE" 2>/dev/null||echo 0); sleep 0.4; b=$(cat "$BATTERY_CURRENT_FILE" 2>/dev/null||echo 0); sleep 0.4; c=$(cat "$BATTERY_CURRENT_FILE" 2>/dev/null||echo 0); printf "%s\n%s\n%s\n" "$a" "$b" "$c"|sort -n|sed -n '2p'; }

# --- (6) --- P O W E R   &   L E D   F U N C T I O N S ------------------------

# --- Power Saving Action Helpers ---
set_cpu_governor() { local gov="$1"; info "${EMOJI_CPU} Setting CPU governor to: $gov"; for cpu in /sys/devices/system/cpu/cpu[0-9]*; do [ -w "$cpu/cpufreq/scaling_governor" ] && printf "%s" "$gov" > "$cpu/cpufreq/scaling_governor" 2>/dev/null; done; }
set_cpu_max_freq() { local freq="$1"; info "${EMOJI_CPU} Setting CPU max frequency to: $freq kHz"; for cpu in /sys/devices/system/cpu/cpu[0-9]*; do [ -w "$cpu/cpufreq/scaling_max_freq" ] && printf "%s" "$freq" > "$cpu/cpufreq/scaling_max_freq" 2>/dev/null; done; }
set_cpu_core_online() { local core="$1" state="$2"; local s=$([ "$2" -eq 1 ]&&echo "online"||echo "offline"); info "${EMOJI_CPU} Setting CPU core $core to $s"; f="/sys/devices/system/cpu/cpu$core/online"; [ -w "$f" ] && printf "%d" "$state" > "$f" 2>/dev/null || warn "Cannot set core $core state."; }
set_wifi_power() { if [[ "$WIFI_POWERSAVE_MODE" != "auto" ]]; then return; fi; local mode="$1"; info "Setting Wi-Fi power_save to '$mode'"; command -v iw >/dev/null && iw dev wlan0 set power_save "$mode" 2>/dev/null; }
set_backlight() { if [[ "$BACKLIGHT_MODE" != "auto" ]]; then return; fi; local state="$1"; info "${EMOJI_LED} Setting backlight to $state"; [ -w "$BACKLIGHT_FILE" ] && printf "%d" "$state" > "$BACKLIGHT_FILE" 2>/dev/null; }
set_vm_dirty_writeback() { local val="$1"; info "Setting VM dirty writeback to $val cs"; [ -w "$VM_DIRTY_WRITEBACK_FILE" ] && printf "%s" "$val" > "$VM_DIRTY_WRITEBACK_FILE" 2>/dev/null; }
set_bluetooth_rfkill() { if [[ "$BLUETOOTH_MODE" != "auto" ]]; then return; fi; local state="$1"; info "Setting Bluetooth radio to $state"; command -v rfkill >/dev/null && rfkill "$state" bluetooth 2>/dev/null; }

# --- LED Control Helpers ---
set_led_state() {
    local state=$1 # "solid_bright", "solid_dim", "blinking", "off"
    local blink_speed=${2:-500} # Default blink speed if not provided

    if [ ! -d "$LED_INDICATOR_DIR" ]; then return; fi

    # First, reset trigger to none to control brightness directly
    [ -w "$LED_INDICATOR_DIR/trigger" ] && echo "none" > "$LED_INDICATOR_DIR/trigger"

    case "$state" in
        solid_bright)
            [ -w "$LED_INDICATOR_DIR/brightness" ] && echo 255 > "$LED_INDICATOR_DIR/brightness"
            ;;;
        solid_dim)
            [ -w "$LED_INDICATOR_DIR/brightness" ] && echo 50 > "$LED_INDICATOR_DIR/brightness"
            ;;;
        blinking)
            if [ -w "$LED_INDICATOR_DIR/trigger" ]; then
                echo "timer" > "$LED_INDICATOR_DIR/trigger"
                echo "$blink_speed" > "$LED_INDICATOR_DIR/delay_on"
                echo "$blink_speed" > "$LED_INDICATOR_DIR/delay_off"
            fi
            ;;;
        off)
            [ -w "$LED_INDICATOR_DIR/brightness" ] && echo 0 > "$LED_INDICATOR_DIR/brightness"
            ;;;
    esac
}

# --- Main Power State & Feedback Logic ---
update_system_state() {
    local capacity=$1 online_val=$2
    
    local current_stage=0
    if $ENABLE_POWER_SAVING_ON_BATTERY && (( online_val == 0 )); then
        if   (( capacity < PS_STAGE5_ACTIVATE )); then current_stage=5
        elif (( capacity < PS_STAGE4_ACTIVATE )); then current_stage=4
        elif (( capacity < PS_STAGE3_ACTIVATE )); then current_stage=3
        elif (( capacity < PS_STAGE2_ACTIVATE )); then current_stage=2
        elif (( capacity < PS_STAGE1_ACTIVATE )); then current_stage=1
        fi
    fi
    if (( POWER_SAVING_STATES[governor] > 0 && capacity > PS_RECOVER_THRESHOLD )); then
        current_stage=0
    fi

    # (Power setting logic remains the same as v11)
    declare -A targets; targets[governor]=$(( current_stage >= PS_STAGE_FOR_CPU_GOVERNOR && PS_STAGE_FOR_CPU_GOVERNOR > 0 ? 1 : 0 )); targets[freq_cap]=$(( current_stage >= PS_STAGE_FOR_CPU_FREQ_CAP && PS_STAGE_FOR_CPU_FREQ_CAP > 0 ? 1 : 0 )); targets[cores]=$(( current_stage >= PS_STAGE_FOR_CPU_CORE_SHUTDOWN && PS_STAGE_FOR_CPU_CORE_SHUTDOWN > 0 ? 1 : 0 )); targets[wifi]=$(( current_stage >= PS_STAGE_FOR_WIFI_POWERSAVE && PS_STAGE_FOR_WIFI_POWERSAVE > 0 ? 1 : 0 )); targets[backlight]=$(( current_stage >= PS_STAGE_FOR_BACKLIGHT && PS_STAGE_FOR_BACKLIGHT > 0 ? 1 : 0 )); targets[vm]=$(( current_stage >= PS_STAGE_FOR_VM_WRITEBACK && PS_STAGE_FOR_VM_WRITEBACK > 0 ? 1 : 0 )); targets[bt]=$(( current_stage >= PS_STAGE_FOR_BLUETOOTH && PS_STAGE_FOR_BLUETOOTH > 0 ? 1 : 0 ))
    if (( targets[governor] != POWER_SAVING_STATES[governor] )); then set_cpu_governor $((targets[governor]==1?$CPU_POWERSAVE_GOVERNOR:$CPU_PERFORMANCE_GOVERNOR)); POWER_SAVING_STATES[governor]=${targets[governor]}; fi
    if (( targets[freq_cap] != POWER_SAVING_STATES[freq_cap] )); then max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq); set_cpu_max_freq $((targets[freq_cap]==1?$CPU_MAX_FREQ_POWERSAVE:$max_freq)); POWER_SAVING_STATES[freq_cap]=${targets[freq_cap]}; fi
    if (( targets[cores] != POWER_SAVING_STATES[cores] )); then for core in "${CPU_CORES_TO_SHUTDOWN[@]}"; do set_cpu_core_online "$core" $((targets[cores]==1?0:1)); done; POWER_SAVING_STATES[cores]=${targets[cores]}; fi
    if (( targets[wifi] != POWER_SAVING_STATES[wifi] )); then set_wifi_power $((targets[wifi]==1?"on":"off")); POWER_SAVING_STATES[wifi]=${targets[wifi]}; fi
    if (( targets[backlight] != POWER_SAVING_STATES[backlight] )); then set_backlight $((targets[backlight]==1?0:255)); POWER_SAVING_STATES[backlight]=${targets[backlight]}; fi
    if (( targets[vm] != POWER_SAVING_STATES[vm] )); then set_vm_dirty_writeback $((targets[vm]==1?$VM_DIRTY_WRITEBACK_POWERSAVE:$VM_DIRTY_WRITEBACK_NORMAL)); POWER_SAVING_STATES[vm]=${targets[vm]}; fi
    if (( targets[bt] != POWER_SAVING_STATES[bt] )); then set_bluetooth_rfkill $((targets[bt]==1?"block":"unblock")); POWER_SAVING_STATES[bt]=${targets[bt]}; fi

    # Update Indicator LED based on the determined state
    if [[ "$INDICATOR_LED_MODE" == "auto" ]]; then
        if (( online_val == 1 )); then
            set_led_state "solid_bright"
        else
            if (( current_stage == 0 )); then
                set_led_state "solid_bright"
            elif (( current_stage == 1 )); then
                set_led_state "solid_dim"
            else # Stages 2 and higher
                local blink_speed=$(( 100 + (capacity - 5) * 25 ))
                [ $blink_speed -lt 100 ] && blink_speed=100
                set_led_state "blinking" "$blink_speed"
            fi
        fi
    fi
}

# --- (7) --- C H A R G E   &   S A F E T Y   F U N C T I O N S ----------------

run_pi_controller() {
    # Params
    local capacity=$1
    # compute desired target battery current (negative = charging)
    local soc_deficit=$(( TARGET_SOC - capacity ))
    local target_current_ua=0
    if [ "$soc_deficit" -gt 0 ]; then
        target_current_ua=$(( -1 * soc_deficit * CHARGE_CURRENT_PER_SOC_DEFICIT_UA ))
    fi

    # read smoothed battery current (median-of-3)
    local actual_current_ua=$(sample_median); [ -z "$actual_current_ua" ] && actual_current_ua=0

    # error = target - actual (same sign rules as before)
    local error=$(( target_current_ua - actual_current_ua ))

    # absolute error for detection
    local abs_error=$(( error<0 ? -error : error ))

    # --- Leaky / event-weighted integrator ---
    # If |error| is increasing we give the integrator full effect (helps react faster to growing deviation).
    # If |error| is shrinking we decay the integral (prevents windup & chasing noise).
    if (( abs_error > prev_abs_error )); then
        # weight_upscale gives stronger integration when deviation grows
        integral_error=$(echo "scale=6; $integral_error + ($error * $LOOP_SLEEP_S)" | bc -l)
    else
        # leaky decay: decay by 10% each loop (adjust factor if you want slower/faster decay)
        integral_error=$(echo "scale=6; $integral_error * 0.9" | bc -l)
        # still allow a small accumulation of present error (prevent losing long-term offset entirely)
        integral_error=$(echo "scale=6; $integral_error + ($error * $LOOP_SLEEP_S * 0.1)" | bc -l)
    fi

    # clamp integral (anti-windup)
    local max_integral=2000000
    local min_integral=-2000000
    integral_error=$(awk -v v="$integral_error" -v mn="$min_integral" -v mx="$max_integral" 'BEGIN{ if(v>mx) print mx; else if(v<mn) print mn; else print v }')

    # compute P and I terms
    local p_term=$(echo "scale=6; $KP * $error" | bc -l)
    local i_term=$(echo "scale=6; $KI * $integral_error" | bc -l)

    # total adjustment (float) then rounded: positive adjustment -> decrease input limit
    local adj_float=$(echo "scale=6; $p_term + $i_term" | bc -l)
    local adjustment=$(printf "%.0f" "$adj_float")

    # read current limit and prepare candidate
    local current_input_limit=$(cat "$LIMIT_FILE" 2>/dev/null || echo 0)
    local new_input_limit=$(( current_input_limit - adjustment ))

    # clamp
    if [ "$new_input_limit" -gt "$MAX_INPUT_CURRENT_UA" ]; then new_input_limit=$MAX_INPUT_CURRENT_UA; fi
    if [ "$new_input_limit" -lt "$MIN_INPUT_CURRENT_UA" ]; then new_input_limit=$MIN_INPUT_CURRENT_UA; fi

    # delta between proposed and current
    local diff=$(( new_input_limit > current_input_limit ? new_input_limit - current_input_limit : current_input_limit - new_input_limit ))

    # decide asymmetric min-step thresholds
    # increases = asking for MORE current (new_input_limit > current_input_limit)
    # decreases = asking for LESS current (new_input_limit < current_input_limit)
    local min_step_increase=$MIN_STEP_UA
    local min_step_decrease=$MIN_STEP_UA
    # prefer bigger steps when increasing to get out of negotiation deadzones
    if [ "$min_step_increase" -lt 20000 ]; then min_step_increase=20000; fi  # at least 20mA step to raise
    if [ "$min_step_decrease" -lt 5000 ]; then min_step_decrease=5000; fi   # allow finer decreases

    # saturation gating: if we recently detected saturation, skip increases until timeout
    local now=$(date +%s)
    if (( saturation_until > now )) && [ "$new_input_limit" -gt "$current_input_limit" ]; then
        debug "Saturation active until $saturation_until; blocking increases this loop."
        # collapse new_input_limit to current (no increase)
        new_input_limit=$current_input_limit
        diff=0
    fi

    debug "SoC=${capacity}% TargetCurr=${target_current_ua}uA BatCurr=${actual_current_ua}uA Err=${error} AbsErr=${abs_error} Adj=${adjustment} CurrLimit=${current_input_limit} NewLimitCandidate=${new_input_limit} Diff=${diff}"

    # If diff is minor, skip write (but respect min-step asymmetry)
    if [ "$new_input_limit" -gt "$current_input_limit" ]; then
        # increase path: ensure change at least min_step_increase
        if (( new_input_limit - current_input_limit < min_step_increase )); then
            new_input_limit=$(( current_input_limit + min_step_increase ))
            # clamp again
            if [ "$new_input_limit" -gt "$MAX_INPUT_CURRENT_UA" ]; then new_input_limit=$MAX_INPUT_CURRENT_UA; fi
            diff=$(( new_input_limit - current_input_limit ))
        fi
    else
        # decrease path: ensure change at least min_step_decrease
        if (( current_input_limit - new_input_limit < min_step_decrease )); then
            new_input_limit=$(( current_input_limit - min_step_decrease ))
            # clamp
            if [ "$new_input_limit" -lt "$MIN_INPUT_CURRENT_UA" ]; then new_input_limit=$MIN_INPUT_CURRENT_UA; fi
            diff=$(( current_input_limit - new_input_limit ))
        fi
    fi

    # If still too small change, skip write
    if [ "$diff" -lt "$MIN_STEP_UA" ]; then
        debug "Delta ${diff} < effective MIN_STEP (${MIN_STEP_UA}); skipping write."
        # update prev_abs_error then exit
        prev_abs_error=$abs_error
        last_bat_sample=$actual_current_ua
        return 0
    fi

    # Prepare to write. For increases, we will do a staged write + check for effect (saturation detection).
    if [ "$new_input_limit" -gt "$current_input_limit" ]; then
        # Staged increase (ask loudly)
        info "Increasing input limit: ${current_input_limit} -> ${new_input_limit} (request)"
        if ! printf "%d" "$new_input_limit" > "$LIMIT_FILE" 2>/dev/null; then
            echo "$new_input_limit" | sudo tee "$LIMIT_FILE" >/dev/null || warn "Failed to write increased limit."
        fi
        # allow PMIC/USB to settle and sample
        sleep 1.5
        local after_now=$(sample_median)
        # compare change in battery current (we expect more negative charging current)
        # compute magnitude change (abs)
        local before_abs=$(( actual_current_ua<0 ? -actual_current_ua : actual_current_ua ))
        local after_abs=$(( after_now<0 ? -after_now : after_now ))
        local delta_abs=$(( after_abs > before_abs ? after_abs - before_abs : before_abs - after_abs ))
        debug "After increase: before_abs=${before_abs}uA after_abs=${after_abs}uA delta_abs=${delta_abs}uA"
        # If the observed absolute current did not increase meaningfully, mark saturation
        local SAT_THRESHOLD=15000   # 15 mA threshold to consider the increase effective
        if [ "$delta_abs" -lt "$SAT_THRESHOLD" ]; then
            warn "Increase did not materially change battery current (delta ${delta_abs}uA < ${SAT_THRESHOLD}uA). Marking saturation and reverting."
            # revert to previous limit (safe)
            if ! printf "%d" "$current_input_limit" > "$LIMIT_FILE" 2>/dev/null; then
                echo "$current_input_limit" | sudo tee "$LIMIT_FILE" >/dev/null || warn "Failed to revert after failed increase."
            fi
            # set saturation timeout (do not attempt increases again for a while)
            saturation_until=$(( now + 60 ))   # 60s backoff; tune as needed
            debug "Saturation set until ${saturation_until} (epoch)."
            # do not update last_applied_limit to the failed value
            last_applied_limit=$current_input_limit
            # update prev_abs_error and exit
            prev_abs_error=$abs_error
            last_bat_sample=$after_now
            return 0
        else
            # increase succeeded in changing observed current; accept it
            info "Increase effective (delta ${delta_abs}uA). Keeping new limit."
            last_applied_limit=$new_input_limit
            prev_abs_error=$abs_error
            last_bat_sample=$after_now
            return 0
        fi
    else
        # Decrease: apply directly (we allow smaller steps and quicker reaction)
        info "Decreasing input limit: ${current_input_limit} -> ${new_input_limit}"
        if ! printf "%d" "$new_input_limit" > "$LIMIT_FILE" 2>/dev/null; then
            echo "$new_input_limit" | sudo tee "$LIMIT_FILE" >/dev/null || warn "Failed to write decreased limit."
        fi
        last_applied_limit=$new_input_limit
        prev_abs_error=$abs_error
        last_bat_sample=$actual_current_ua
        return 0
    fi
}

check_for_emergency_shutdown() {
    local capacity=$1 online_val=$2
    if $ENABLE_EMERGENCY_SHUTDOWN && (( online_val == 0 )) && (( capacity <= EMERGENCY_SHUTDOWN_THRESHOLD )); then
        crit "CRITICAL: Battery at ${capacity}%. Triggering emergency shutdown NOW."
        set_led_state "blinking" 100 # Fast blink as a final warning
        sleep 5
        shutdown -h now
        exit 0
    fi
}

# --- (8) --- M A I N   E X E C U T I O N --------------------------------------

initial_setup() {
    info "Performing initial setup based on configuration..."
    case "$WIFI_POWERSAVE_MODE" in always_on) iw dev wlan0 set power_save on 2>/dev/null;; always_off) iw dev wlan0 set power_save off 2>/dev/null;; esac
    case "$BLUETOOTH_MODE" in always_on) rfkill unblock bluetooth 2>/dev/null;; always_off|force_off) rfkill block bluetooth 2>/dev/null;; esac
    case "$BACKLIGHT_MODE" in force_off) [ -w "$BACKLIGHT_FILE" ] && printf "0" > "$BACKLIGHT_FILE" 2>/dev/null;; always_on) [ -w "$BACKLIGHT_FILE" ] && printf "255" > "$BACKLIGHT_FILE" 2>/dev/null;; always_off) [ -w "$BACKLIGHT_FILE" ] && printf "0" > "$BACKLIGHT_FILE" 2>/dev/null;; esac
    case "$INDICATOR_LED_MODE" in always_on) set_led_state "solid_bright";; always_off) set_led_state "off";; esac
}

main() {
    initial_setup
    info "Starting Smart PI Charge Controller. Target SoC=${TARGET_SOC}%"
    
    while true; do
        local capacity=$(cat "$CAPACITY_FILE" 2>/dev/null || echo 0); capacity=${capacity//[^0-9]/}; [ -z "$capacity" ] && capacity=0
        local online_val=$(cat "$ONLINE_FILE" 2>/dev/null || echo 0)

        check_for_emergency_shutdown "$capacity" "$online_val"
        update_system_state "$capacity" "$online_val"
        run_pi_controller "$capacity"

        sleep "$LOOP_SLEEP_S"
    done
}

main
