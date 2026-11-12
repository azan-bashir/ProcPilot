
PP_SYSTEM_CPU=""
PP_SYSTEM_RAM_TOTAL=""
PP_SYSTEM_RAM_USED=""
PP_SYSTEM_RAM_PERCENT=""

cpu_perc()
{
    local total idle running perc t1 t2 i1 i2
    local -a a b

    read -r -a a <<< "$(grep '^cpu ' /proc/stat)" || return 1

    (( ${#a[@]} >= 9 )) || return 1

    t1=$(( a[1]+a[2]+a[3]+a[4]+a[5]+a[6]+a[7]+a[8] ))
    i1=$(( a[4]+a[5] ))

    sleep 0.2

    read -r -a b <<< "$(grep '^cpu ' /proc/stat)" || return 1

    (( ${#b[@]} >= 9 )) || return 1

    t2=$(( b[1]+b[2]+b[3]+b[4]+b[5]+b[6]+b[7]+b[8] ))
    i2=$(( b[4]+b[5] ))

    total=$(( t2-t1 ))
    idle=$(( i2-i1 ))

    if (( total > 0 )); then
        running=$(( total-idle ))
        perc=$(( running*100/total ))
        echo "$perc"
    else
        echo "0"
    fi
}

get_system_resources()
{
    local total avail cpu

    total=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo) || return 1
    avail=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo) || return 1

    [[ "$total" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ ]] || return 1
    (( total > 0 && avail <= total )) || return 1

    cpu=$(cpu_perc) || return 1
    [[ "$cpu" =~ ^[0-9]+$ ]] || return 1

    PP_SYSTEM_CPU="$cpu"
    PP_SYSTEM_RAM_TOTAL="$total"
    PP_SYSTEM_RAM_USED=$(( total - avail ))
    PP_SYSTEM_RAM_PERCENT=$(( PP_SYSTEM_RAM_USED * 100 / PP_SYSTEM_RAM_TOTAL ))

    return 0
}

PP_RESOURCE_WARNING=""

check_resources()
{
    local max_cpu max_ram

    max_cpu="$PP_CPU_WARNING_THRESHOLD"
    max_ram="$PP_RAM_WARNING_THRESHOLD"

    [[ "$max_cpu" =~ ^[0-9]+$ && "$max_ram" =~ ^[0-9]+$ ]] || return 1

    PP_RESOURCE_WARNING=""

    get_system_resources || return 1

    if (( PP_SYSTEM_RAM_PERCENT > max_ram )); then
        PP_RESOURCE_WARNING+="RAM almost full. "
    fi

    if (( PP_SYSTEM_CPU > max_cpu )); then
        PP_RESOURCE_WARNING+="CPU almost full. "
    fi

    return 0
}
