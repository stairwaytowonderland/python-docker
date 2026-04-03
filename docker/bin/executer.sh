#!/usr/bin/env bash

com=("$@")

if [ "${#com[@]}" -eq 0 ]; then
    echo "(!) No command to execute." >&2
    exit 1
fi

# Handle exit
__quit() { printf "🐬 %s 🐬\n" "So long, and thanks for all the fish" >&2; }

# Handle cancelled operations (e.g., Ctrl+C)
__control_c() {
    _err=$?
    trap __quit EXIT
    _bold="\033[1m"
    _color="\033[00;91m"
    _color_bold="\033[01;91m"
    _color_reset="\033[0m"
    echo -e "⛔ ${_color_bold}✗${_color_reset} ${_color}(${_err})${_color_reset} ${_color_bold}Operation cancelled by user${_color_reset} ⛔" >&2
    kill -INT 0 2> /dev/null
    # SIGINT expected to exit with 130 (128 + SIGINT(2)) — the conventional exit code for Ctrl+C termination — but some environments may return 143 or other codes
    exit $_err
}

trap __control_c INT

printf "\033[95;1m§ %s\033[0m\n" "${com[*]}" >&2

DEFAULT_TIME_MSG_LABEL="${DEFAULT_TIME_MSG_LABEL-}"
DEFAULT_TIME_MSG_PREFIX="${DEFAULT_TIME_MSG_PREFIX:-Elapsed time}"
TIME_MSG_LABEL="${TIME_MSG_LABEL:-$DEFAULT_TIME_MSG_LABEL}"
TIME_MSG_PREFIX="${TIME_MSG_PREFIX:-$DEFAULT_TIME_MSG_PREFIX}"
if command -v time > /dev/null 2>&1; then
    # TIMEFORMAT="Elapsed time: %lR seconds"
    TIMEFORMAT=$'\n'"${TIME_MSG_LABEL}"$'\033[7m ⏱ '"${TIME_MSG_PREFIX% }"$': %lR seconds \033[0m'
    time (
        set -x
        "${com[@]}"
    )
else
    SECONDS=0
    (
        set -x
        "${com[@]}"
    )
    # Calculate the duration
    duration=$SECONDS
    # Format the duration into hours, minutes, and seconds
    # Hours: (duration / 3600)
    # Minutes: ((duration % 3600) / 60)
    # Seconds: (duration % 60)
    printf "\n%s\033[7m ⏱ %s: %02d hours, %02d minutes, %02d seconds \033[0m\n" "${TIME_MSG_LABEL}" "${TIME_MSG_PREFIX% }" $((duration / 3600)) $((duration % 3600 / 60)) $((duration % 60)) >&2
fi

echo -e "\033[2m~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\033[0m" >&2
