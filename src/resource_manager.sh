
PP_SYSTEM_CPU=""
PP_SYSTEM_RAM_TOTAL=""
PP_SYSTEM_RAM_USED=""
PP_SYSTEM_RAM_PERCENT=""

cpu_perc()
{
    local total idle running perc t1 t2 i1 i2
    local -a a b

    read -r -a a <<< "$(grep '^cpu ' /proc/stat)"
    t1=$(( a[1]+a[2]+a[3]+a[4]+a[5]+a[6]+a[7]+a[8] ))
    i1=$(( a[4]+a[5] ))

    sleep 0.2

    read -r -a b <<< "$(grep '^cpu ' /proc/stat)"
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
    local total avail
    total=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    avail=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)

    PP_SYSTEM_CPU="$( cpu_perc )"
    PP_SYSTEM_RAM_TOTAL="$total"
    PP_SYSTEM_RAM_USED=$(( total - avail ))
    PP_SYSTEM_RAM_PERCENT=$(( PP_SYSTEM_RAM_USED * 100 / PP_SYSTEM_RAM_TOTAL ))
}

