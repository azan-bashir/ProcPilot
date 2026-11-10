#!/bin/bash

refresh_process_state()
{
    local PID=$1 a b

    a=$(kill -0 "$PID")
    if (( a==0 )); then
      wait "$PID"
      b=$?
      return "$b"
    fi

    return 1
}

PP_PROCESS_PID=""
PP_PROCESS_CPU=""
PP_PROCESS_MEM=""
PP_PROCESS_STATUS=""
PP_PROCESS_COMMAND=""

get_process_info() #Syntax: get_process_info <Process-PID>
{
    PID=$1

    IFS=" " read -r PP_PROCESS_PID PP_PROCESS_CPU PP_PROCESS_MEM PP_PROCESS_STATUS cmd <<< "$(ps -p $PID -o pid=,%cpu=,%mem=,stat=,cmd=)"

    PP_PROCESS_COMMAND="'$cmd'" #The command is enclosed in single quotes so whitespaces don't cause problem.

}

PP_RUNNING_COUNT=""
PP_COMPLETED_COUNT=""
PP_FAILED_COUNT=""
PP_STOPPED_COUNT=""

get_process_counts()
{
    PP_RUNNING_COUNT="$(jobs -r | wc -l)"
    PP_COMPLETED_COUNT="$(jobs -s | wc -l)"
    PP_FAILED_COUNT=""
    PP_STOPPED_COUNT=""
}

