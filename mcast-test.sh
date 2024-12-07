#!/bin/bash

# If you need to strip the color tags from output file, use the below sed:
# sed -r "s/[[:cntrl:]]\[[0-9]{1,3}m//g"

function usage
{
    echo
    echo -e "\t-A\tALL.\t\tUse all network interfaces excluding 'lo'"
    echo -e "\t-f\tFILENAME.\tPath of the plaintext or xml config file to be parsed for target addresses"
    echo -e "\t-h\tHELP.\t\tPrint this help menu"
    echo -e "\t-I\tIFS.\t\tAlter the IFS delimiter character between the IP and Port for the config file you are parsing"
    echo -e "\t-p\tPLAINTEXT.\tSpecify that the supplied filename is in plaintext, a.k.a. simply one IP and one Port per line (Default without flag intended to parse xml file)"
    echo -e "\t-t\tTIMEOUT.\tSpecify the numbers of seconds you want to wait on mdump to return data before killing the process (Default 5s)"
    echo
    exit 1
}

TIMEOUT=5

while getopts "Af:hI:pt:" opt; do
    case $opt in
        A) ALL=true;;
        f) FILENAME=$OPTARG;;
        h) print_help;;
        I) NEW_IFS=$OPTARG;;
        p) PLAINTEXT=true;;
        t) TIMEOUT=$OPTARG;;
        *) usage; exit 1;;
    esac
done
shift $((OPTIND-1)) # shift arguments so as not to break positionals
#-----------------------------------------------------------------
if [ -z $FILENAME ]; then
    echo -e "\033[91mError\033[0m: Required flag '-f' is missing. You must provide a filename";
    usage
    exit 1
fi
#-----------------------------------------------------------------
if [ -z $PLAINTEXT ]; then
    echo "Parsing XML file:" $FILENAME
    probability=$(grep -c "<?xml" $FILENAME)
    if [ $probability -eq 0 ]; then
        echo "Could not find xml header in file provided -- did you mean to use plaintext option (-p)?"
    fi
    IP_REGEX='(([0-9]|[0-9]{2}|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[0-9]{2}|1[0-9]{2}|2[0-4][0-9]|25[0-5]):[0-9]{1,5}'
    egrep -o "primary-mc-channel=\"$IP_REGEX\"" $FILENAME | awk -F\" '{print $2}' > targets.out
    egrep -o "secondary-mc-channel=\"$IP_REGEX\"" $FILENAME | awk -F\" '{print $2}' >> targets.out
    FILENAME="targets.out" # This is necessary to keep the input to the following loop generic
else
    echo "Parsing PLAINTEXT file:" $FILENAME
fi

if [ -z $ALL ]; then
    if [ $# -lt 1 ]; then
        echo "Error: If flag '-A' is not triggered, you MUST provide at least 1 interface name as a positional argument";
        usage
    fi
    interfaces="${@}"
else
    interfaces=$(ls /sys/class/net | grep -v lo | grep -v bonding_masters) $ pull all interfaces on host
fi
ips=$(for i in $interfaces; do ip=$(ifconfig $i | grep -e 'inet\b' | awk '{print $2}'); if [ -z $ip ]; then echo "0.0.0.0"; else echo $ip; fi; done)
ips=$(echo $ips | sed -e "s/ /${NEW_IFS}/g") # Need to determine why this can't be done in one step above

declare -A TABS
TABS[0]="\t"
TABS[1]="\t"

echo "***IP Addresses need to be in the multicast range (224.0.0.0 to 239.255.255.255) or they will always fail***"
echo -ne "Address\t\tPort\t"
i=2
for int in $interfaces; do
    tmp=""
    numtabs=$(($((${#int} / 8)) + 1))
    for x in $(seq $numtabs); do
        tmp="$tmp\t";
    done
    TABS[$i]=$tmp
    echo -ne "$int\t"
    ((i++))
done
#for int in $interfaces; do echo -ne "$(echo -ne "$(echo $int | cut -c1-7)\t"; done
echo

IFS=$NEW_IFS
while read -r addr port; do
    i=0
    if [ -z $port ]; then
        echo -e "\033[91mError:\033[0m Could not resolve port from this line: $addr"
        echo "Please check that you have set IFS (-I) correctly"
        echo "Exiting..."
        exit 1
    fi
    out="$addr\t$port"
    echo -ne "\r$out"
    for intfc in $ips; do
        ((i++))
        echo -ne "\033[96m${TABS[$i]}WORKING\033[0m"
        if [ $intfc == "0.0.0.0" ]; then # we have hardcoded 0.0.0.0 above to imply that there is no address associated with this interface
            out="$out\033[91m${TABS[$i]}NO-ADDR\033[0m"
            echo -ne "\r$out"
            continue
        fi
        resp=$(timeout $TIMEOUT mdump -Q1 $addr $port $intfc)
        lines=$(echo "$resp" | wc -l) # count up lines of stdout from cmd
        if [ $lines -gt 1 ]; then # mdump always prints 1 line to stdout of the "equivalent cmd", so if there's any more than 1, that means we got data successfully
            out="$out\033[92m${TABS[$i]}SUCCESS\033[0m"
        else
            out="$out\033[91m${TABS[$i]}FAILURE\033[0m"
        fi
        echo -ne "\r$out"
    done
    echo # echo newline for next target address
done < $FILENAME

if [ -z $PLAINTEXT ]; then
    rm $FILENAME
fi
