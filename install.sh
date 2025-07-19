#!/bin/bash
set -e

WG_INTERFACE="wg0"
WG_PORT=51820
WG_SUBNET="10.1.0.0/24"
WG_SERVER_IP="10.1.0.1/24"
CLIENT_CONF_DIR=~/wg-clients
KEY_DIR="/etc/wireguard/keys"
SERVER_CONF="/etc/wireguard/${WG_INTERFACE}.conf"
WAN_INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5}')
mkdir -p "$CLIENT_CONF_DIR" "$KEY_DIR"

# === Определение внешнего IPv4 ===
SERVER_PUBLIC_IP=$(curl -4 -s https://ipv4.icanhazip.com || dig -4 +short myip.opendns.com @resolver1.opendns.com)
SERVER_PUBLIC_IP=$(echo "$SERVER_PUBLIC_IP" | tr -d '\n')

if [[ ! "$SERVER_PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Не удалось получить корректный IPv4-адрес: $SERVER_PUBLIC_IP"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ Скрипт нужно запускать от root"
  exit 1
fi

install_server() {
  echo "🔧 Установка WireGuard..."
  apt update && apt install -y wireguard qrencode curl

  echo "🔑 Генерация ключей сервера..."
  wg genkey | tee "$KEY_DIR/server_private.key" | wg pubkey > "$KEY_DIR/server_public.key"
  chmod 600 "$KEY_DIR/server_private.key"

  SERVER_PRIVATE_KEY=$(cat "$KEY_DIR/server_private.key")

  cat > "$SERVER_CONF" <<EOF
[Interface]
Address = $WG_SERVER_IP
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIVATE_KEY

PostUp = iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; \
         iptables -A FORWARD -o $WG_INTERFACE -j ACCEPT; \
         iptables -t nat -A POSTROUTING -s $WG_SUBNET -o $WAN_INTERFACE -j MASQUERADE

PostDown = iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; \
           iptables -D FORWARD -o $WG_INTERFACE -j ACCEPT; \
           iptables -t nat -D POSTROUTING -s $WG_SUBNET -o $WAN_INTERFACE -j MASQUERADE
EOF

  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard-forward.conf
  sysctl --system

  systemctl enable wg-quick@$WG_INTERFACE
  systemctl start wg-quick@$WG_INTERFACE

  echo "✅ WireGuard установлен и запущен!"
}

add_client() {
  CLIENT_NAME="$1"
  if [[ -z "${CLIENT_NAME// }" ]]; then
    echo "❌ Имя клиента не может быть пустым"
    exit 1
  fi

  if [ ! -f "$SERVER_CONF" ]; then
    echo "❌ WireGuard не установлен. Сначала запустите скрипт без параметров."
    exit 1
  fi

  CLIENT_CONF_PATH="${CLIENT_CONF_DIR}/${CLIENT_NAME}.conf"

  while [ -f "$CLIENT_CONF_PATH" ]; do
    echo "⚠ Клиент '$CLIENT_NAME' уже существует: $CLIENT_CONF_PATH"
    read -p "Введите другое имя клиента: " CLIENT_NAME
    if [[ -z "${CLIENT_NAME// }" ]]; then
      echo "❌ Имя клиента не может быть пустым. Попробуйте снова."
      continue
    fi
    CLIENT_CONF_PATH="${CLIENT_CONF_DIR}/${CLIENT_NAME}.conf"
  done

  USED_IPS=$(grep AllowedIPs "$SERVER_CONF" | awk -F '[ /]' '{print $3}')
  NEXT_OCTET=2
  while echo "$USED_IPS" | grep -q "10.1.0.$NEXT_OCTET"; do
    ((NEXT_OCTET++))
  done
  CLIENT_IP="10.1.0.$NEXT_OCTET/32"

  echo "🔑 Генерация ключей клиента..."
  CLIENT_PRIV=$(wg genkey)
  CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)
  SERVER_PUB=$(cat "$KEY_DIR/server_public.key")

  echo "⚙ Добавление клиента в конфигурацию сервера..."
  echo -e "\n[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = ${CLIENT_IP}" >> "$SERVER_CONF"

  echo "🌀 Перезапуск интерфейса для применения клиента..."
  systemctl restart wg-quick@$WG_INTERFACE

  echo "📝 Создание конфигурации клиента..."
  cat > "$CLIENT_CONF_PATH" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = ${CLIENT_IP}
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = $WG_SUBNET
PersistentKeepalive = 25
EOF

  echo "✅ Клиент '$CLIENT_NAME' добавлен!"
  echo "➡ Конфиг: $CLIENT_CONF_PATH"
  echo "📱 QR-код для подключения:"
  qrencode -t ansiutf8 < "$CLIENT_CONF_PATH"
}

### === Логика вызова ===

if [ $# -eq 0 ]; then
  if [ ! -f "$SERVER_CONF" ]; then
    install_server
  fi

  # Цикл: запрашиваем имя клиента, пока оно невалидное или занято
  while true; do
    read -p "Введите имя клиента: " CLIENT_NAME
    if [[ -z "${CLIENT_NAME// }" ]]; then
      echo "❌ Имя клиента не может быть пустым. Попробуйте снова."
      continue
    fi
    CLIENT_PATH="${CLIENT_CONF_DIR}/${CLIENT_NAME}.conf"
    if [ -f "$CLIENT_PATH" ]; then
      echo "⚠ Клиент '$CLIENT_NAME' уже существует: $CLIENT_PATH"
      continue
    fi
    break
  done

  add_client "$CLIENT_NAME"
else
  add_client "$1"
fi
