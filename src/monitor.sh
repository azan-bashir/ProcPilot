#!/bin/bash

#refresh_process_state()
#{
#
#}

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

#For testing purposes:
#sleep 5 &
#get_process_info $!
#echo "$PP_PROCESS_PID $PP_PROCESS_CPU $PP_PROCESS_MEM $PP_PROCESS_STATUS $PP_PROCESS_COMMAND"

PP_RUNNING_COUNT=""
PP_COMPLETED_COUNT=""
PP_FAILED_COUNT=""
PP_STOPPED_COUNT=""

get_process_counts()
{

}
