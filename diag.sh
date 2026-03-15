#!/usr/bin/env bash
# =============================================================================
#  diagnose.sh — Диагностика сервера перед установкой 3x-ui / Xray
#  Использование: bash diagnose.sh [--no-speedtest] [--no-color]
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Параметры
# ---------------------------------------------------------------------------
RUN_SPEEDTEST=true
USE_COLOR=true
LOG_FILE="$(dirname "$0")/diagnose_$(date +%Y%m%d_%H%M%S).log"

for arg in "$@"; do
  case "$arg" in
    --no-speedtest) RUN_SPEEDTEST=false ;;
    --no-color)     USE_COLOR=false ;;
  esac
done

# ---------------------------------------------------------------------------
# Цвета и вывод
# ---------------------------------------------------------------------------
if $USE_COLOR && [ -t 1 ]; then
  C_RESET='\033[0m'; C_BOLD='\033[1m'
  C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'
  C_CYAN='\033[0;36m'; C_WHITE='\033[1;37m'
else
  C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_WHITE=''
fi

OK()   { echo -e "${C_GREEN}  [OK]${C_RESET}    $*"; }
WARN() { echo -e "${C_YELLOW}  [WARN]${C_RESET}  $*"; }
FAIL() { echo -e "${C_RED}  [FAIL]${C_RESET}  $*"; }
INFO() { echo -e "${C_CYAN}  [INFO]${C_RESET}  $*"; }
HDR()  { echo -e "\n${C_BOLD}${C_WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"; \
         echo -e "${C_BOLD}${C_WHITE}  $*${C_RESET}"; \
         echo -e "${C_BOLD}${C_WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"; }

# Счётчики для финального вердикта
PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0
declare -a VERDICT_LINES=()

verdict() {
  local status="$1"; local section="$2"; local detail="$3"
  case "$status" in
    OK)   PASS_COUNT=$((PASS_COUNT+1)); VERDICT_LINES+=("${C_GREEN}[PASS]${C_RESET} $section — $detail") ;;
    WARN) WARN_COUNT=$((WARN_COUNT+1)); VERDICT_LINES+=("${C_YELLOW}[WARN]${C_RESET} $section — $detail") ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT+1)); VERDICT_LINES+=("${C_RED}[FAIL]${C_RESET} $section — $detail") ;;
  esac
}

# Tee в лог
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------------------
# Заголовок
# ---------------------------------------------------------------------------
echo
echo -e "${C_BOLD}${C_WHITE}  VPN Server Diagnostic v1.0${C_RESET}"
echo -e "  Дата: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo -e "  Лог:  $LOG_FILE"

if [ "$EUID" -ne 0 ]; then
  WARN "Запущен без root. Некоторые проверки могут быть недоступны."
fi

# ===========================================================================
# 1. СИСТЕМА
# ===========================================================================
HDR "1. Система"

# ОС
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_NAME="${PRETTY_NAME:-$NAME $VERSION_ID}"
else
  OS_NAME="$(uname -s)"
fi
INFO "ОС:           $OS_NAME"

# Ядро
KERNEL="$(uname -r)"
INFO "Ядро:         $KERNEL"

# Архитектура
ARCH="$(uname -m)"
INFO "Архитектура:  $ARCH"
if [[ "$ARCH" == "x86_64" ]]; then
  OK "Архитектура x86_64 — поддерживается"
  verdict OK "Архитектура" "$ARCH"
else
  WARN "Архитектура $ARCH — убедитесь что xray-core собран для этой платформы"
  verdict WARN "Архитектура" "$ARCH — проверьте совместимость"
fi

# Аптайм
UPTIME="$(uptime -p 2>/dev/null || uptime)"
INFO "Аптайм:       $UPTIME"

# ===========================================================================
# 2. РЕСУРСЫ
# ===========================================================================
HDR "2. Ресурсы CPU / RAM / Диск"

# CPU
CPU_MODEL="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//' || echo 'N/A')"
CPU_CORES="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)"
INFO "CPU:          $CPU_MODEL"
INFO "Ядер:         $CPU_CORES"

if [ "$CPU_CORES" -ge 2 ]; then
  OK "CPU — $CPU_CORES ядра (рекомендуется 2+)"
  verdict OK "CPU" "$CPU_CORES ядра"
elif [ "$CPU_CORES" -eq 1 ]; then
  WARN "CPU — 1 ядро (минимум достигнут, может быть медленно при высокой нагрузке)"
  verdict WARN "CPU" "1 ядро — может быть мало при высокой нагрузке"
else
  FAIL "Не удалось определить количество ядер CPU"
  verdict FAIL "CPU" "не определено"
fi

# RAM
RAM_TOTAL_KB="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
RAM_FREE_KB="$(grep MemAvailable /proc/meminfo | awk '{print $2}')"
RAM_TOTAL_MB=$((RAM_TOTAL_KB / 1024))
RAM_FREE_MB=$((RAM_FREE_KB / 1024))
INFO "RAM всего:    ${RAM_TOTAL_MB} MB"
INFO "RAM свободно: ${RAM_FREE_MB} MB"

if [ "$RAM_TOTAL_MB" -ge 1024 ]; then
  OK "RAM ${RAM_TOTAL_MB} MB (рекомендуется 1+ GB)"
  verdict OK "RAM" "${RAM_TOTAL_MB} MB"
elif [ "$RAM_TOTAL_MB" -ge 512 ]; then
  WARN "RAM ${RAM_TOTAL_MB} MB (минимум 512 MB достигнут)"
  verdict WARN "RAM" "${RAM_TOTAL_MB} MB — минимальный порог"
else
  FAIL "RAM ${RAM_TOTAL_MB} MB — недостаточно (минимум 512 MB)"
  verdict FAIL "RAM" "${RAM_TOTAL_MB} MB — мало"
fi

# Диск
DISK_AVAIL_KB="$(df -k / | awk 'NR==2 {print $4}')"
DISK_TOTAL_KB="$(df -k / | awk 'NR==2 {print $2}')"
DISK_AVAIL_GB=$((DISK_AVAIL_KB / 1024 / 1024))
DISK_TOTAL_GB=$((DISK_TOTAL_KB / 1024 / 1024))
INFO "Диск (/):     ${DISK_TOTAL_GB} GB всего, ${DISK_AVAIL_GB} GB свободно"

if [ "$DISK_AVAIL_GB" -ge 10 ]; then
  OK "Диск: ${DISK_AVAIL_GB} GB свободно"
  verdict OK "Диск" "${DISK_AVAIL_GB} GB свободно"
elif [ "$DISK_AVAIL_GB" -ge 5 ]; then
  WARN "Диск: ${DISK_AVAIL_GB} GB свободно (рекомендуется 10+ GB)"
  verdict WARN "Диск" "${DISK_AVAIL_GB} GB — мало"
else
  FAIL "Диск: только ${DISK_AVAIL_GB} GB свободно — недостаточно"
  verdict FAIL "Диск" "${DISK_AVAIL_GB} GB — критически мало"
fi

# ===========================================================================
# 3. СЕТЬ
# ===========================================================================
HDR "3. Сеть"

# Внешний IPv4
EXT_IPV4=""
if command -v curl &>/dev/null; then
  EXT_IPV4="$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || \
              curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || \
              echo '')"
fi
if [ -n "$EXT_IPV4" ]; then
  INFO "Внешний IPv4: $EXT_IPV4"
  OK "IPv4 доступен — $EXT_IPV4"
  verdict OK "IPv4" "$EXT_IPV4"
else
  FAIL "Внешний IPv4 не определён — нет интернета или curl не установлен"
  verdict FAIL "IPv4" "не определён"
fi

# Внешний IPv6
EXT_IPV6=""
if command -v curl &>/dev/null; then
  EXT_IPV6="$(curl -6 -s --max-time 5 https://ifconfig.me 2>/dev/null || echo '')"
fi
if [ -n "$EXT_IPV6" ]; then
  INFO "Внешний IPv6: $EXT_IPV6"
  OK "IPv6 доступен"
  verdict OK "IPv6" "$EXT_IPV6"
else
  WARN "IPv6 недоступен (не критично, но желательно)"
  verdict WARN "IPv6" "недоступен"
fi

# Сетевые интерфейсы
INFO "Интерфейсы:"
if command -v ip &>/dev/null; then
  ip -brief addr show | grep -v '^lo' | while read -r line; do
    INFO "  $line"
  done
elif command -v ifconfig &>/dev/null; then
  ifconfig | grep -E '^[a-z]|inet ' | grep -v 'lo' | while read -r line; do
    INFO "  $line"
  done
fi

# MTU основного интерфейса
MAIN_IFACE="$(ip route 2>/dev/null | grep '^default' | awk '{print $5}' | head -1)"
if [ -n "$MAIN_IFACE" ]; then
  MTU="$(ip link show "$MAIN_IFACE" 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}')"
  INFO "MTU ($MAIN_IFACE): $MTU"
  if [ "${MTU:-0}" -ge 1500 ]; then
    OK "MTU $MTU — оптимально"
    verdict OK "MTU" "$MTU"
  elif [ "${MTU:-0}" -ge 1280 ]; then
    WARN "MTU $MTU — пониженное, возможны проблемы с производительностью"
    verdict WARN "MTU" "$MTU — пониженное"
  else
    FAIL "MTU $MTU — слишком низкое"
    verdict FAIL "MTU" "$MTU — слишком низкое"
  fi
fi

# DNS
INFO "DNS серверы:"
grep '^nameserver' /etc/resolv.conf 2>/dev/null | while read -r _ ns; do
  INFO "  $ns"
done

# Проверка DNS разрешения
if command -v curl &>/dev/null; then
  for HOST in google.com cloudflare.com; do
    if curl -s --max-time 5 "https://$HOST" -o /dev/null 2>/dev/null; then
      OK "DNS + HTTP: $HOST доступен"
    else
      WARN "DNS / HTTP: $HOST недоступен"
    fi
  done
fi

# ===========================================================================
# 4. СКОРОСТЬ И ЗАДЕРЖКА
# ===========================================================================
HDR "4. Скорость и задержка"

# Ping
for TARGET in "1.1.1.1" "8.8.8.8"; do
  if command -v ping &>/dev/null; then
    RTT="$(ping -c 3 -W 3 "$TARGET" 2>/dev/null | grep 'rtt\|round-trip' | grep -o '[0-9.]*\/' | head -2 | tail -1 | tr -d '/')"
    if [ -n "$RTT" ]; then
      RTT_INT="${RTT%.*}"
      INFO "Ping $TARGET: ${RTT} ms (avg)"
      if [ "$RTT_INT" -lt 50 ]; then
        OK "Ping $TARGET — ${RTT} ms (отличный)"
      elif [ "$RTT_INT" -lt 150 ]; then
        OK "Ping $TARGET — ${RTT} ms (хороший)"
        verdict OK "Ping $TARGET" "${RTT} ms"
      elif [ "$RTT_INT" -lt 300 ]; then
        WARN "Ping $TARGET — ${RTT} ms (повышенный)"
        verdict WARN "Ping $TARGET" "${RTT} ms — высокая задержка"
      else
        FAIL "Ping $TARGET — ${RTT} ms (очень высокий)"
        verdict FAIL "Ping $TARGET" "${RTT} ms — слишком высокий"
      fi
    else
      FAIL "Ping $TARGET недоступен"
      verdict FAIL "Ping $TARGET" "недоступен"
    fi
  fi
done

# Traceroute (первые 10 хопов)
if command -v traceroute &>/dev/null || command -v tracepath &>/dev/null; then
  INFO "Traceroute до 1.1.1.1 (первые 10 хопов):"
  if command -v traceroute &>/dev/null; then
    traceroute -m 10 -w 2 1.1.1.1 2>/dev/null | tail -n +2 | while read -r line; do
      INFO "  $line"
    done
  else
    tracepath -m 10 1.1.1.1 2>/dev/null | head -12 | while read -r line; do
      INFO "  $line"
    done
  fi
else
  WARN "traceroute/tracepath не установлен — пропускаем"
fi

# Speedtest через curl (без установки пакетов)
if $RUN_SPEEDTEST; then
  INFO "Тест скорости загрузки (curl → Cloudflare)..."
  if command -v curl &>/dev/null; then
    # Загрузка 100MB файла с Cloudflare speed test
    SPEED_OUTPUT="$(curl -s --max-time 15 \
      -o /dev/null \
      -w "%{speed_download}" \
      "https://speed.cloudflare.com/__down?bytes=104857600" 2>/dev/null || echo '0')"
    SPEED_BYTES="${SPEED_OUTPUT%.*}"
    SPEED_MBIT=$(( (SPEED_BYTES * 8) / 1000000 ))
    if [ "$SPEED_MBIT" -gt 0 ]; then
      INFO "Скорость загрузки: ~${SPEED_MBIT} Mbit/s"
      if [ "$SPEED_MBIT" -ge 100 ]; then
        OK "Скорость загрузки ${SPEED_MBIT} Mbit/s (отличная)"
        verdict OK "Скорость" "${SPEED_MBIT} Mbit/s"
      elif [ "$SPEED_MBIT" -ge 50 ]; then
        OK "Скорость загрузки ${SPEED_MBIT} Mbit/s (хорошая)"
        verdict OK "Скорость" "${SPEED_MBIT} Mbit/s"
      elif [ "$SPEED_MBIT" -ge 10 ]; then
        WARN "Скорость загрузки ${SPEED_MBIT} Mbit/s (низкая для VPN)"
        verdict WARN "Скорость" "${SPEED_MBIT} Mbit/s — низкая"
      else
        FAIL "Скорость загрузки ${SPEED_MBIT} Mbit/s (очень низкая)"
        verdict FAIL "Скорость" "${SPEED_MBIT} Mbit/s — критически низкая"
      fi
    else
      WARN "Не удалось измерить скорость (timeout или нет доступа)"
      verdict WARN "Скорость" "не измерена"
    fi
  else
    WARN "curl не установлен — speedtest недоступен"
    verdict WARN "Скорость" "curl не установлен"
  fi
else
  INFO "Speedtest пропущен (--no-speedtest)"
fi

# ===========================================================================
# 5. ФАЕРВОЛ И ПОРТЫ
# ===========================================================================
HDR "5. Фаервол и порты"

# UFW
if command -v ufw &>/dev/null; then
  UFW_STATUS="$(ufw status 2>/dev/null | head -1)"
  INFO "UFW: $UFW_STATUS"
  if echo "$UFW_STATUS" | grep -qi 'inactive'; then
    WARN "UFW неактивен — рекомендуется настроить после установки"
    verdict WARN "UFW" "неактивен"
  else
    OK "UFW активен"
    verdict OK "UFW" "активен"
  fi
elif command -v iptables &>/dev/null; then
  RULES_COUNT="$(iptables -L 2>/dev/null | grep -c '^' || echo '0')"
  INFO "iptables: активен ($RULES_COUNT строк в правилах)"
  verdict OK "Фаервол" "iptables активен"
else
  WARN "Фаервол не обнаружен (ufw/iptables)"
  verdict WARN "Фаервол" "не найден"
fi

# SELinux / AppArmor
if command -v getenforce &>/dev/null; then
  SE_STATUS="$(getenforce 2>/dev/null)"
  INFO "SELinux: $SE_STATUS"
  if [ "$SE_STATUS" = "Enforcing" ]; then
    WARN "SELinux Enforcing — может мешать работе 3x-ui"
    verdict WARN "SELinux" "Enforcing — может потребоваться настройка политик"
  fi
elif [ -f /sys/kernel/security/apparmor/profiles ]; then
  INFO "AppArmor: активен"
fi

# fail2ban
if command -v fail2ban-client &>/dev/null; then
  F2B_STATUS="$(fail2ban-client status 2>/dev/null | head -1 || echo 'не запущен')"
  INFO "fail2ban: $F2B_STATUS"
  OK "fail2ban установлен"
else
  WARN "fail2ban не установлен (рекомендуется для защиты)"
  verdict WARN "fail2ban" "не установлен"
fi

# Занятость ключевых портов
INFO "Проверка ключевых портов:"
PORTS_TO_CHECK=(80 443 54321)
PORT_ISSUES=0
for PORT in "${PORTS_TO_CHECK[@]}"; do
  if command -v ss &>/dev/null; then
    IN_USE="$(ss -tlnp "sport = :$PORT" 2>/dev/null | grep -c LISTEN || echo '0')"
  elif command -v netstat &>/dev/null; then
    IN_USE="$(netstat -tlnp 2>/dev/null | grep -c ":$PORT " || echo '0')"
  else
    IN_USE="0"
  fi

  if [ "$IN_USE" -gt 0 ]; then
    PROCESS="$(ss -tlnp "sport = :$PORT" 2>/dev/null | grep LISTEN | grep -o 'users:(([^)]*))' | head -1 || echo '')"
    WARN "Порт $PORT — ЗАНЯТ ($PROCESS)"
    PORT_ISSUES=$((PORT_ISSUES+1))
  else
    OK "Порт $PORT — свободен"
  fi
done
if [ "$PORT_ISSUES" -eq 0 ]; then
  verdict OK "Порты" "80, 443, 54321 свободны"
else
  verdict WARN "Порты" "$PORT_ISSUES портов занято — могут быть конфликты"
fi

# ===========================================================================
# 6. ПАРАМЕТРЫ ЯДРА
# ===========================================================================
HDR "6. Параметры ядра Linux"

# BBR
if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
  BBR_STATUS="$(cat /proc/sys/net/ipv4/tcp_congestion_control)"
  INFO "TCP Congestion Control: $BBR_STATUS"
  if [ "$BBR_STATUS" = "bbr" ]; then
    OK "BBR включён — оптимальная производительность TCP"
    verdict OK "BBR" "включён"
  else
    WARN "BBR не включён (текущий: $BBR_STATUS) — рекомендуется включить"
    verdict WARN "BBR" "не включён — рекомендуется: sysctl -w net.ipv4.tcp_congestion_control=bbr"
  fi
fi

# IP Forwarding
if [ -f /proc/sys/net/ipv4/ip_forward ]; then
  IP_FWD="$(cat /proc/sys/net/ipv4/ip_forward)"
  INFO "IP Forwarding: $IP_FWD"
  if [ "$IP_FWD" = "1" ]; then
    OK "IP Forwarding включён"
    verdict OK "IP Forwarding" "включён"
  else
    WARN "IP Forwarding выключен — может потребоваться для некоторых конфигураций xray"
    verdict WARN "IP Forwarding" "выключен"
  fi
fi

# IPv6 forwarding
if [ -f /proc/sys/net/ipv6/conf/all/forwarding ]; then
  IPV6_FWD="$(cat /proc/sys/net/ipv6/conf/all/forwarding)"
  INFO "IPv6 Forwarding: $IPV6_FWD"
fi

# ulimit — open files
ULIMIT_FILES="$(ulimit -n 2>/dev/null || echo 'N/A')"
INFO "ulimit open files: $ULIMIT_FILES"
if [[ "$ULIMIT_FILES" =~ ^[0-9]+$ ]]; then
  if [ "$ULIMIT_FILES" -ge 65535 ]; then
    OK "ulimit -n $ULIMIT_FILES — достаточно для высокой нагрузки"
    verdict OK "ulimit" "$ULIMIT_FILES"
  elif [ "$ULIMIT_FILES" -ge 1024 ]; then
    WARN "ulimit -n $ULIMIT_FILES — рекомендуется 65535+"
    verdict WARN "ulimit" "$ULIMIT_FILES — рекомендуется увеличить"
  else
    FAIL "ulimit -n $ULIMIT_FILES — слишком низкий"
    verdict FAIL "ulimit" "$ULIMIT_FILES — критически низкий"
  fi
fi

# Размер receive buffer
RMEM="$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo '0')"
WMEM="$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo '0')"
INFO "net.core.rmem_max: $RMEM"
INFO "net.core.wmem_max: $WMEM"

# ===========================================================================
# 7. ВРЕМЯ И СИНХРОНИЗАЦИЯ
# ===========================================================================
HDR "7. Время и синхронизация"

# Текущее время
INFO "Время сервера:  $(date '+%Y-%m-%d %H:%M:%S')"
INFO "Часовой пояс:   $(cat /etc/timezone 2>/dev/null || timedatectl 2>/dev/null | grep 'Time zone' | awk '{print $3}' || date +%Z)"

# NTP / chrony / systemd-timesyncd
NTP_OK=false
if command -v chronyc &>/dev/null; then
  CHRONY_STATUS="$(chronyc tracking 2>/dev/null | grep 'System time' || echo '')"
  if [ -n "$CHRONY_STATUS" ]; then
    INFO "Chrony: $CHRONY_STATUS"
    OK "Chrony — синхронизация времени активна"
    NTP_OK=true
    verdict OK "NTP" "chrony активен"
  fi
fi

if ! $NTP_OK && command -v timedatectl &>/dev/null; then
  NTP_STATUS="$(timedatectl 2>/dev/null | grep 'NTP service\|Network time\|synchronized' | head -2)"
  INFO "timedatectl: $NTP_STATUS"
  if echo "$NTP_STATUS" | grep -qi 'yes\|active'; then
    OK "systemd-timesyncd — NTP синхронизация активна"
    NTP_OK=true
    verdict OK "NTP" "systemd-timesyncd активен"
  fi
fi

if ! $NTP_OK; then
  if command -v ntpd &>/dev/null || command -v ntpq &>/dev/null; then
    OK "NTP демон установлен"
    verdict OK "NTP" "ntpd установлен"
  else
    WARN "Синхронизация времени не обнаружена — рекомендуется chrony или systemd-timesyncd"
    verdict WARN "NTP" "не настроен — время может рассинхронизироваться"
  fi
fi

# ===========================================================================
# 8. ДОПОЛНИТЕЛЬНО: ЗАВИСИМОСТИ
# ===========================================================================
HDR "8. Необходимые утилиты"

REQUIRED_CMDS=(curl wget unzip tar systemctl)
OPTIONAL_CMDS=(docker nginx certbot fail2ban-client ufw)

INFO "Обязательные:"
for CMD in "${REQUIRED_CMDS[@]}"; do
  if command -v "$CMD" &>/dev/null; then
    OK "$CMD — установлен ($(command -v "$CMD"))"
  else
    FAIL "$CMD — НЕ установлен (требуется для установки 3x-ui)"
    verdict FAIL "Утилита $CMD" "не установлена"
  fi
done

INFO "Опциональные:"
for CMD in "${OPTIONAL_CMDS[@]}"; do
  if command -v "$CMD" &>/dev/null; then
    OK "$CMD — установлен"
  else
    INFO "$CMD — не установлен (может потребоваться)"
  fi
done

# ===========================================================================
# ИТОГОВЫЙ ВЕРДИКТ
# ===========================================================================
echo
echo -e "${C_BOLD}${C_WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo -e "${C_BOLD}${C_WHITE}  ИТОГОВЫЙ ВЕРДИКТ${C_RESET}"
echo -e "${C_BOLD}${C_WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo

for LINE in "${VERDICT_LINES[@]}"; do
  echo -e "  $LINE"
done

echo
echo -e "  ${C_GREEN}PASS: $PASS_COUNT${C_RESET}  ${C_YELLOW}WARN: $WARN_COUNT${C_RESET}  ${C_RED}FAIL: $FAIL_COUNT${C_RESET}"
echo

if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
  echo -e "  ${C_GREEN}${C_BOLD}Сервер полностью готов к установке 3x-ui!${C_RESET}"
elif [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "  ${C_YELLOW}${C_BOLD}Сервер готов, но есть предупреждения — рекомендуется устранить.${C_RESET}"
else
  echo -e "  ${C_RED}${C_BOLD}Обнаружены критические проблемы — устраните перед установкой!${C_RESET}"
fi

echo
echo -e "  Полный лог сохранён: ${C_CYAN}$LOG_FILE${C_RESET}"
echo
