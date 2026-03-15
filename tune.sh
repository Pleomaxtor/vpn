#!/bin/bash

echo "===== VPN AUTO OPTIMIZATION ====="

SYSCTL_FILE="/etc/sysctl.conf"
LIMITS_FILE="/etc/security/limits.conf"
SYSTEMD_FILE="/etc/systemd/system.conf"

BACKUP="/etc/sysctl.conf.backup.$(date +%F-%H%M)"

echo "Creating sysctl backup: $BACKUP"
cp $SYSCTL_FILE $BACKUP

IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

CPU=$(nproc)
MASK=$(printf "%x" $((2**CPU - 1)))

echo "Detected interface: $IFACE"
echo "CPU cores: $CPU"
echo "RPS mask: $MASK"

update_sysctl() {

KEY=$1
VALUE=$2

if grep -q "^$KEY" $SYSCTL_FILE; then
sed -i "s|^$KEY.*|$KEY = $VALUE|" $SYSCTL_FILE
else
echo "$KEY = $VALUE" >> $SYSCTL_FILE
fi

}

echo "Applying network tuning..."

update_sysctl net.core.somaxconn 65535
update_sysctl net.core.netdev_max_backlog 250000

update_sysctl net.core.rmem_max 67108864
update_sysctl net.core.wmem_max 67108864

update_sysctl net.ipv4.tcp_rmem "4096 87380 33554432"
update_sysctl net.ipv4.tcp_wmem "4096 65536 33554432"
update_sysctl net.ipv4.tcp_mtu_probing 1

update_sysctl net.ipv4.tcp_max_syn_backlog 65535
update_sysctl net.ipv4.tcp_fin_timeout 15
update_sysctl net.ipv4.tcp_tw_reuse 1

update_sysctl net.ipv4.tcp_keepalive_time 600
update_sysctl net.ipv4.tcp_keepalive_intvl 30
update_sysctl net.ipv4.tcp_keepalive_probes 5

update_sysctl net.ipv4.ip_local_port_range "10240 65535"

echo "Tuning conntrack..."

update_sysctl net.netfilter.nf_conntrack_max 1048576
update_sysctl net.netfilter.nf_conntrack_tcp_timeout_established 600
update_sysctl net.netfilter.nf_conntrack_tcp_timeout_time_wait 30
update_sysctl net.netfilter.nf_conntrack_tcp_timeout_close_wait 30

echo "Enabling BBR..."

update_sysctl net.core.default_qdisc fq
update_sysctl net.ipv4.tcp_congestion_control bbr

echo "Applying sysctl..."
sysctl -p

echo "Increasing file descriptors..."

if ! grep -q "nofile 1000000" $LIMITS_FILE; then

cat <<EOF >> $LIMITS_FILE
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF

fi

echo "Updating systemd limits..."

if grep -q "^#DefaultLimitNOFILE=" $SYSTEMD_FILE; then
sed -i "s/^#DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1000000/" $SYSTEMD_FILE
elif grep -q "^DefaultLimitNOFILE=" $SYSTEMD_FILE; then
sed -i "s/^DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1000000/" $SYSTEMD_FILE
else
echo "DefaultLimitNOFILE=1000000" >> $SYSTEMD_FILE
fi

systemctl daemon-reexec

echo "Installing irqbalance..."

apt update -y
apt install irqbalance ethtool -y

systemctl enable irqbalance
systemctl start irqbalance

echo "Enabling RPS..."

RX="/sys/class/net/$IFACE/queues/rx-0/rps_cpus"

if [ -f "$RX" ]; then
echo $MASK > $RX
echo "RPS enabled"
fi

echo "Creating persistent RPS service..."

cat <<EOF > /etc/systemd/system/network-rps.service
[Unit]
Description=Enable RPS
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo $MASK > /sys/class/net/$IFACE/queues/rx-0/rps_cpus'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable network-rps.service

echo ""
echo "===== SERVER STATUS ====="

ss -s

echo ""
echo "Conntrack usage:"
cat /proc/sys/net/netfilter/nf_conntrack_count

echo ""
echo "Congestion control:"
sysctl net.ipv4.tcp_congestion_control

echo ""
echo "Optimization finished."
