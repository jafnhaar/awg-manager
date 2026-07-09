#!/bin/bash -e

APP=$(basename $0)
LOCKFILE="/tmp/$APP.lock"

trap "rm -f ${LOCKFILE}; exit" INT TERM EXIT
if ! ln -s $APP $LOCKFILE 2>/dev/null; then
    echo "ERROR: script LOCKED" >&2
    exit 15
fi

function usage {
  echo "Usage: $0 [<options>] [command [arg]]"
  echo "Options:"
  echo " -i : Init (Create server keys and configs)"
  echo " -c : Create new user"
  echo " -d : Delete user"
  echo " -L : Lock user"
  echo " -U : Unlock user"
  echo " -p : Print user config"
  echo " -q : Print user QR code"
  echo " -u <user> : User identifier (uniq field for vpn account)"
  echo " -s <server> : Server host for user connection"
  echo " -I : Interface (default auto)"
  echo " -h : Usage"
  exit 1
}

unset USER
umask 0077

HOME_DIR="/etc/amnezia/amneziawg"
SERVER_NAME="awg0"
SERVER_IP_PREFIX="10.10.10"
SERVER_INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

while getopts ":icdpqhLUu:I:s:" opt; do
  case $opt in
     i) INIT=1 ;;
     c) CREATE=1 ;;
     d) DELETE=1 ;;
     L) LOCK=1 ;;
     U) UNLOCK=1 ;;
     p) PRINT_USER_CONFIG=1 ;;
     q) PRINT_QR_CODE=1 ;;
     u) USER="$OPTARG" ;;
     I) SERVER_INTERFACE="$OPTARG" ;;
     h) usage ;;
     s) SERVER_ENDPOINT="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" ; exit 1 ;;
     :) echo "Option -$OPTARG requires an argument" ; exit 1 ;;
  esac
done

[ $# -lt 1 ] && usage

function reload_server {
    awg syncconf ${SERVER_NAME} <(awg-quick strip ${SERVER_NAME})
}

function get_new_ip {
    declare -A IP_EXISTS

    for conf in keys/*/*.conf; do
        [ -e "$conf" ] || continue
        for IP in $(grep -h -i 'Address\s*=\s*' "$conf" | sed 's/\/[0-9]\+$//' | grep -Po '\d+$' || true); do
            IP_EXISTS[$IP]=1
        done
    done

    for IP in {2..255}; do
        [ -n "${IP_EXISTS[$IP]}" ] || break
    done

    if [ $IP -eq 255 ] && [ -n "${IP_EXISTS[$IP]}" ]; then
        echo "ERROR: can't determine new address" >&2
        exit 3
    fi

    echo "${SERVER_IP_PREFIX}.${IP}/32"
}

function add_user_to_server {
    if [ ! -f "keys/${USER}/public.key" ]; then
        echo "ERROR: User not exists" >&2
        exit 1
    fi

    local USER_PUB_KEY=$(cat "keys/${USER}/public.key")
    local USER_PSK_KEY=$(cat "keys/$USER/psk.key")
    local USER_IP=$(grep -i Address "keys/${USER}/${USER}.conf" | sed 's/Address\s*=\s*//i; s/\/.*//')

    if grep "# BEGIN ${USER}$" "$SERVER_NAME.conf" >/dev/null ; then
        echo "User already exists"
        exit 0
    fi

cat <<EOF >> "$SERVER_NAME.conf"
# BEGIN ${USER}
[Peer]
PublicKey = ${USER_PUB_KEY}
AllowedIPs = ${USER_IP}/32
PresharedKey = ${USER_PSK_KEY}
# END ${USER}
EOF
}

function remove_user_from_server {
    sed -i "/# BEGIN ${USER}$/,/# END ${USER}$/d" "$SERVER_NAME.conf"
}

function generate_awg_params {

    # Random number of junk packets between 1 - 10
    AWG_JC=$(( (RANDOM % 9 ) + 1 ))
    # Randomize minimum size between 64 - 163
    AWG_JMIN=$(( (RANDOM % 100) + 64 ))
    # Randomize maximum size between 500 - 999
    AWG_JMAX=$(( (RANDOM % 500) + 500 ))

    gen_h_range() {
        local MIN_BOUND=$1
        local MAX_BOUND=$2
        local RANGE=$(( MAX_BOUND - MIN_BOUND + 1 ))

        # Combine two 15-bit $RANDOMs to create a secure 30-bit random number
        local r1=$(( (RANDOM << 15) | RANDOM ))
        local r2=$(( (RANDOM << 15) | RANDOM ))

        local val1=$(( (r1 % RANGE) + MIN_BOUND ))
        local val2=$(( (r2 % RANGE) + MIN_BOUND ))

        if [ "$val1" -lt "$val2" ]; then
            echo "$val1-$val2"
        elif [ "$val1" -gt "$val2" ]; then
            echo "$val2-$val1"
        else
            echo "$val1-$(( val1 + 100 ))"
        fi
    }

    AWG_H1=$(gen_h_range 5          499999999)
    AWG_H2=$(gen_h_range 500000000  999999999)
    AWG_H3=$(gen_h_range 1000000000 1499999999)
    AWG_H4=$(gen_h_range 1500000000 2147483647)

    # Generate random S1-S4 Parameters
    AWG_S1=$(( RANDOM % 65 ))
    AWG_S2=$(( RANDOM % 65 ))
    AWG_S3=$(( RANDOM % 65 ))
    AWG_S4=$(( RANDOM % 33 ))

local DOMAINS=(
    "cloudflare.com" "ajax.googleapis.com" "cdn.jsdelivr.net" "fonts.gstatic.com"
    "s3.amazonaws.com" "fastly.net" "akamai.net" "akamaized.net"
    "googleapis.com" "gstatic.com" "googleusercontent.com"
    "cloudfront.net" "azureedge.net" "windowsupdate.com"

    "captive.apple.com" "time.apple.com" "connectivitycheck.gstatic.com"
    "clients3.google.com" "msftconnecttest.com" "dns.msftncsi.com"
    "ntp.ubuntu.com" "pool.ntp.org" "push.apple.com"

    "microsoft.com" "apple.com" "amazon.com" "google.com"
    "facebook.com" "whatsapp.net" "office.com"
    "icloud.com" "outlook.com" "live.com"

    "yandex.ru" "ya.ru" "mail.ru" "vk.com" "ok.ru"
    "sberbank.ru" "gosuslugi.ru" "wildberries.ru"
    "st.ozone.ru" "ir.ozone.ru" "p.ozon.ru"
    "a.wb.ru" "basket-19.wbbasket.ru" "basket-38.wbbasket.ru"
    "statcheker.yandex.ru" "static.dzeninfra.ru" "yastatic.net"

    "baidu.com" "qq.com" "wechat.com" "taobao.com"
    "aljazeera.net" "binance.com"
)

    local RANDOM_DOMAIN=${DOMAINS[$RANDOM % ${#DOMAINS[@]}]}

    # Random transaction ID (16 bits) created purely with bash math
    local TRANS_ID=$(printf "%04x" $(( (RANDOM << 1) | (RANDOM & 1) )))

    # DNS Response flags: 0x8180 (Standard response, recursion desired+available)
    local DNS_FLAGS="8180"

    # Header: QDCOUNT=1, ANCOUNT=1, NSCOUNT=0, ARCOUNT=0
    local DNS_HEADER="${TRANS_ID}${DNS_FLAGS}00010001000000000000"

    local QNAME_HEX=""
    local IFS='.'
    read -ra ADDR <<< "$RANDOM_DOMAIN"
    for part in "${ADDR[@]}"; do
        local len_hex=$(printf "%02x" ${#part})
        local str_hex=""
        for (( i=0; i<${#part}; i++ )); do
            printf -v hex_char "%02x" "'${part:$i:1}"
            str_hex+="$hex_char"
        done
        QNAME_HEX="${QNAME_HEX}${len_hex}${str_hex}"
    done
    QNAME_HEX="${QNAME_HEX}00"

    # Question section tail: QTYPE=A (0x0001), QCLASS=IN (0x0001)
    local DNS_QTAIL="00010001"

    # Answer section:
    # Name pointer back to offset 12 (0xc00c)
    local ANS_NAME="c00c"
    # TYPE=A, CLASS=IN
    local ANS_TYPE_CLASS="00010001"
    # TTL: randomized between ~60s and ~3600s
    local TTL_VAL=$(( (RANDOM % 3541) + 60 ))
    local ANS_TTL=$(printf "%08x" $TTL_VAL)
    # RDLENGTH=4
    local ANS_RDLEN="0004"
    # RDATA: random IPv4 (avoiding 0.x and 255.x)
    local IP1=$(( (RANDOM % 223) + 1 ))
    local IP2=$(( RANDOM % 256 ))
    local IP3=$(( RANDOM % 256 ))
    local IP4=$(( (RANDOM % 254) + 1 ))
    local ANS_RDATA=$(printf "%02x%02x%02x%02x" $IP1 $IP2 $IP3 $IP4)

    local DNS_ANSWER="${ANS_NAME}${ANS_TYPE_CLASS}${ANS_TTL}${ANS_RDLEN}${ANS_RDATA}"

    # Export the final I1 variable
    AWG_I1="<b 0x${TRANS_ID}${DNS_FLAGS}><r 2><b 0x00010001000000000000${QNAME_HEX}${DNS_QTAIL}${DNS_ANSWER}>"
}

function init {
    if [ -z "$SERVER_ENDPOINT" ]; then
        echo "ERROR: Server required" >&2
        exit 1
    fi

    if [ -z "$SERVER_INTERFACE" ]; then
        echo "ERROR: Can't determine server interface" >&2
        echo "DEBUG: 'ip route':"
        ip route
        exit 1
    fi

    echo "Interface: $SERVER_INTERFACE"

    mkdir -p "keys/${SERVER_NAME}"
    echo -n "$SERVER_ENDPOINT" > "keys/.server"

    if [ ! -f "keys/${SERVER_NAME}/private.key" ]; then
        awg genkey | tee "keys/${SERVER_NAME}/private.key" | awg pubkey > "keys/${SERVER_NAME}/public.key"
    fi

    if [ -f "$SERVER_NAME.conf" ]; then
        echo "Server already initialized"
        exit 0
    fi

    SERVER_PVT_KEY=$(cat "keys/$SERVER_NAME/private.key")

    SERVER_PORT=$(( (RANDOM % 55000) + 10000 ))

    generate_awg_params

cat <<EOF > "$SERVER_NAME.conf"
[Interface]
Address = ${SERVER_IP_PREFIX}.1/24
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PVT_KEY}
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_INTERFACE} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_INTERFACE} -j MASQUERADE
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
I1 = ${AWG_I1}

EOF

    echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf
    sysctl -p

    systemctl enable awg-quick@${SERVER_NAME}
    awg-quick up ${SERVER_NAME} || true

    echo "Server initialized successfully"
    exit 0
}

function create {
    if [ -f "keys/${USER}/${USER}.conf" ]; then
        echo "WARNING: key ${USER}.conf already exists" >&2
        return 0
    fi

    SERVER_ENDPOINT=$(cat "keys/.server")
    USER_IP=$( get_new_ip )

    mkdir "keys/${USER}"
    awg genkey | tee "keys/${USER}/private.key" | awg pubkey > "keys/${USER}/public.key" | awg genpsk > "keys/${USER}/psk.key"

    USER_PVT_KEY=$(cat "keys/${USER}/private.key")
    USER_PUB_KEY=$(cat "keys/${USER}/public.key")
    USER_PSK_KEY=$(cat "keys/${USER}/psk.key")
    SERVER_PUB_KEY=$(cat "keys/$SERVER_NAME/public.key")

    SERVER_PORT=$(grep -Po '(?<=^ListenPort = )\d+' "$SERVER_NAME.conf")
    AWG_JC=$(grep -Po '(?<=^Jc = )\d+' "$SERVER_NAME.conf")
    AWG_JMIN=$(grep -Po '(?<=^Jmin = )\d+' "$SERVER_NAME.conf")
    AWG_JMAX=$(grep -Po '(?<=^Jmax = )\d+' "$SERVER_NAME.conf")
    AWG_H1=$(grep -Po '(?<=^H1 = )[0-9\-]+' "$SERVER_NAME.conf")
    AWG_H2=$(grep -Po '(?<=^H2 = )[0-9\-]+' "$SERVER_NAME.conf")
    AWG_H3=$(grep -Po '(?<=^H3 = )[0-9\-]+' "$SERVER_NAME.conf")
    AWG_H4=$(grep -Po '(?<=^H4 = )[0-9\-]+' "$SERVER_NAME.conf")
    AWG_S1=$(grep -Po '(?<=^S1 = )\d+' "$SERVER_NAME.conf")
    AWG_S2=$(grep -Po '(?<=^S2 = )\d+' "$SERVER_NAME.conf")
    AWG_S3=$(grep -Po '(?<=^S3 = )\d+' "$SERVER_NAME.conf")
    AWG_S4=$(grep -Po '(?<=^S4 = )\d+' "$SERVER_NAME.conf")
    AWG_I1=$(grep -Po '(?<=^I1 = ).*' "$SERVER_NAME.conf")

cat <<EOF > "keys/${USER}/${USER}.conf"
[Interface]
PrivateKey = ${USER_PVT_KEY}
Address = ${USER_IP}
DNS = 8.8.8.8, 8.8.4.4
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
I1 = ${AWG_I1}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
Endpoint = ${SERVER_ENDPOINT}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 20
PresharedKey = ${USER_PSK_KEY}
EOF
    add_user_to_server
    reload_server
}

cd $HOME_DIR

if [ $INIT ]; then
    init
    exit 0;
fi

if [ ! -f "keys/$SERVER_NAME/public.key" ]; then
    echo "ERROR: Run init script before" >&2
    exit 2
fi

if [ -z "${USER}" ]; then
    echo "ERROR: User required" >&2
    exit 1
fi

if [ $CREATE ]; then
    create
fi

if [ $DELETE ]; then
    remove_user_from_server
    reload_server
    rm -rf "keys/${USER}"
    exit 0
fi

if [ $LOCK ]; then
    remove_user_from_server
    reload_server
    exit 0
fi

if [ $UNLOCK ]; then
    add_user_to_server
    reload_server
    exit 0
fi

if [ $PRINT_USER_CONFIG ]; then
    cat "keys/${USER}/${USER}.conf"
elif [ $PRINT_QR_CODE ]; then
    qrencode -t ansiutf8 < "keys/${USER}/${USER}.conf"
fi

exit 0
