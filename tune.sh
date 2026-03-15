#!/bin/bash

echo "===== VPN PRODUCTION TUNING v3 ====="

SYSCTL="/etc/sysctl.conf"
LIMITS="/etc/security/limits.conf"
SYSTEMD="/etc/systemd/system.conf"

BACKUP="/etc/sysctl.conf.backup.$(date +%F-%H%M)"

echo "Backup sysctl → $BACKUP"
cp $SYSCTL $BACKUP

# detect interface
IFACE=$(ip -o -4 route show to default | awk '{print $5}')

# detect cpu
CPU=$(nproc)

# cpu mask
MASK=$(printf "%x" $((2**CPU - 1)))

# RPS values
RPS_FLOW=$((CPU * 2048))
GLOBAL_FLOW=$((CPU * 4096))

echo "Interface: $IFACE"
echo "CPU cores: $CPU"
echo "RPS mask: $MASK"
echo "rps_flow_cnt: $RPS_FLOW"
echo "rps_sock_flow_entries: $GLOBAL_FLOW"

update_sysctl () {

KEY=$1
VALUE=$2

if grep -q "^$KEY" $SYSCTL; then
sed -i "s|^$KEY.*|$KEY = $VALUE|" $SYSCTL
else
echo "$KEY = $VALUE" >> $SYSCTL
fi

}

echo "Applying sysctl tuning..."

update_sysctl net.core.somaxconn 65535
update_sysctl net.core.netdev_max_backlog 250000

update_sysctl net.core.rmem_max 67108864
update_sysctl net.core.wmem_max 67108864

update_sysctl net.ipv4.tcp_rmem "4096 87380 33554432"
update_sysctl net.ipv4.tcp_wmem "4096 65536 33554432"

update_sysctl net.ipv4.tcp_mtu_probing 1

update_sysctl net.ipv4.tcp_fastopen 3
update_sysctl net.ipv4.tcp_slow_start_after_idle 0

update_sysctl net.ipv4.tcp_max_syn_backlog 65535
update_sysctl net.ipv4.tcp_fin_timeout 15
update_sysctl net.ipv4.tcp_tw_reuse 1

update_sysctl net.ipv4.tcp_keepalive_time 600
update_sysctl net.ipv4.tcp_keepalive_intvl 30
update_sysctl net.ipv4.tcp_keepalive_probes 5

update_sysctl net.ipv4.ip_local_port_range "10240 65535"

update_sysctl net.core.rps_sock_flow_entries $GLOBAL_FLOW

echo "Conntrack tuning..."

update_sysctl net.netfilter.nf_conntrack_max 1048576
update_sysctl net.netfilter.nf_conntrack_tcp_timeout_established 600
update_sysctl net.netfilter.nf_conntrack_tcp_timeout_time_wait 30
update_sysctl net.netfilter.nf_conntrack_tcp_timeout_close_wait 30

echo "Enable BBR..."

update_sysctl net.core.default_qdisc fq
update_sysctl net.ipv4.tcp_congestion_control bbr

echo "Apply sysctl..."
sysctl -p

echo "Increase file descriptors..."

if ! grep -q "nofile 1000000" $LIMITS; then

cat <<EOF >> $LIMITS
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF

fi

echo "systemd limits..."

if grep -q "^#DefaultLimitNOFILE=" $SYSTEMD; then
sed -i "s/^#DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1000000/" $SYSTEMD
elif grep -q "^DefaultLimitNOFILE=" $SYSTEMD; then
sed -i "s/^DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1000000/" $SYSTEMD
else
echo "DefaultLimitNOFILE=1000000" >> $SYSTEMD
fi

systemctl daemon-reexec

echo "Install tools..."

apt --fix-broken install -y
apt update -y
apt install irqbalance ethtool iptables sysstat -y

systemctl enable irqbalance || true
systemctl start irqbalance || true

echo "Enable RPS..."

RX="/sys/class/net/$IFACE/queues/rx-0"

if [ -d "$RX" ]; then

echo $MASK > $RX/rps_cpus
echo $RPS_FLOW > $RX/rps_flow_cnt

fi

echo "Persistent RPS..."

cat <<EOF > /etc/systemd/system/network-rps.service
[Unit]
Description=Enable RPS
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo $MASK > /sys/class/net/$IFACE/queues/rx-0/rps_cpus'
ExecStart=/bin/bash -c 'echo $RPS_FLOW > /sys/class/net/$IFACE/queues/rx-0/rps_flow_cnt'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable network-rps.service

echo ""
echo "===== SERVER STATUS ====="

echo ""
echo "CPU:"
nproc

echo ""
echo "TCP:"
ss -s

echo ""
echo "Conntrack:"
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max

echo ""
echo "RPS:"
cat /sys/class/net/$IFACE/queues/rx-0/rps_cpus 2>/dev/null

echo ""
echo "Congestion control:"
sysctl net.ipv4.tcp_congestion_control

echo ""
echo "Interface:"
ip route | grep default

echo ""
echo "Tuning complete."
