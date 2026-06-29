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
SERVER_PORT=43748
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

    for IP in $(grep -i 'Address\s*=\s*' keys/*/*.conf | sed 's/\/[0-9]\+$//' | grep -Po '\d+$')
    do
        IP_EXISTS[$IP]=1
    done

    for IP in {2..255}
    do
        [ ${IP_EXISTS[$IP]} ] || break
    done

    if [ $IP -eq 255 ]; then
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
AllowedIPs = ${USER_IP}
PresharedKey = ${USER_PSK_KEY}
# END ${USER}
EOF

    ip -4 route add ${USER_IP}/32 dev ${SERVER_NAME} || true
}

function remove_user_from_server {
    sed -i "/# BEGIN ${USER}$/,/# END ${USER}$/d" "$SERVER_NAME.conf"
    if [ -f "keys/${USER}/${USER}.conf" ]; then
        local USER_IP=$(grep -i Address "keys/${USER}/${USER}.conf" | sed 's/Address\s*=\s*//i; s/\/.*//')
        ip -4 route del ${USER_IP}/32 dev ${SERVER_NAME} || true
    fi
}

function generate_awg_params {
    # Generate random H1-H4 Parameters
    AWG_H1=$(od -vAn -N4 -tu4 < /dev/urandom | tr -d ' \n')
    AWG_H2=$(od -vAn -N4 -tu4 < /dev/urandom | tr -d ' \n'); while [ "$AWG_H2" = "$AWG_H1" ]; do AWG_H2=$(od -vAn -N4 -tu4 < /dev/urandom | tr -d ' \n'); done
    AWG_H3=$(od -vAn -N4 -tu4 < /dev/urandom | tr -d ' \n'); while [ "$AWG_H3" = "$AWG_H1" ] || [ "$AWG_H3" = "$AWG_H2" ]; do AWG_H3=$(od -vAn -N4 -tu4 < /dev/urandom | tr -d ' \n'); done
    AWG_H4=$(od -vAn -N4 -tu4 < /dev/urandom | tr -d ' \n'); while [ "$AWG_H4" = "$AWG_H1" ] || [ "$AWG_H4" = "$AWG_H2" ] || [ "$AWG_H4" = "$AWG_H3" ]; do AWG_H4=$(od -vAn -N4 -tu4 < /dev/urandom | tr -d ' \n'); done

    # Generate random S1-S4 Parameters
    AWG_S1=$(( RANDOM % 65 ))
    AWG_S2=$(( RANDOM % 65 ))
    AWG_S3=$(( RANDOM % 65 ))
    AWG_S4=$(( RANDOM % 33 ))

    local DOMAINS=(
        "captive.apple.com" "time.apple.com" "connectivitycheck.gstatic.com"
        "clients3.google.com" "msftconnecttest.com" "dns.msftncsi.com" "ntp.ubuntu.com"
        "cloudflare.com" "ajax.googleapis.com" "cdn.jsdelivr.net" "fonts.gstatic.com"
        "s3.amazonaws.com" "fastly.net" "google-analytics.com" "graph.instagram.com"
        "api.twitter.com" "push.apple.com" "ya.ru" "vk.com" "mail.ru" "ok.ru"
        "wechat.com" "qq.com" "baidu.com" "taobao.com" "aljazeera.net" "binance.com"
    )

    local RANDOM_DOMAIN=${DOMAINS[$RANDOM % ${#DOMAINS[@]}]}

    # Random transaction ID (2 bytes)
    local TRANS_ID=$(od -vAn -N2 -tx1 < /dev/urandom | tr -d ' \n')

    # DNS Response flags: 0x8180 (Standard response, recursion desired+available)
    local DNS_FLAGS="8180"

    # Header: QDCOUNT=1, ANCOUNT=1, NSCOUNT=0, ARCOUNT=0
    local DNS_HEADER="${TRANS_ID}${DNS_FLAGS}00010001000000000000"

    # Encode QNAME
    local QNAME_HEX=""
    local IFS='.'
    read -ra ADDR <<< "$RANDOM_DOMAIN"
    for part in "${ADDR[@]}"; do
        local len_hex=$(printf "%02x" ${#part})
        local str_hex=$(echo -n "$part" | od -vAn -tx1 | tr -d ' \n')
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

    generate_awg_params

cat <<EOF > "$SERVER_NAME.conf"
[Interface]
Address = ${SERVER_IP_PREFIX}.1/32
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PVT_KEY}
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_INTERFACE} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_INTERFACE} -j MASQUERADE
Jc = 3
Jmin = 10
Jmax = 50
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

    # Read generated AmneziaWG parameters from the server config so the client matches
    AWG_H1=$(grep -Po '(?<=^H1 = )\d+' "$SERVER_NAME.conf")
    AWG_H2=$(grep -Po '(?<=^H2 = )\d+' "$SERVER_NAME.conf")
    AWG_H3=$(grep -Po '(?<=^H3 = )\d+' "$SERVER_NAME.conf")
    AWG_H4=$(grep -Po '(?<=^H4 = )\d+' "$SERVER_NAME.conf")
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
Jc = 3
Jmin = 10
Jmax = 50
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
