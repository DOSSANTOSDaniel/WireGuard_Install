#!/usr/bin/env bash

#************************************************#                    
# Auteur:  <dossantosjdf@gmail.com>              
# Date:    20/12/2023                                                               
#                                                
# Rôle:                                          
# Ce script permet d'installer le serveur VPN WireGuard et de créé automatiquement une configuration valide du serveur.
# Il permet aussi de créer huit configurations basiques de clients peer-1, peer-2...peer-9.
# Il installe un serveur DNS (Dnsmasq) pour la résolution de nom en local à partir du VPN.
#
# Les données automatiquement récupérées :
# 1. Adresse IP publique, ex : 86.**.**.** 
# 2. Adresse du réseau local, ex : 192.168.1.0/24
# 3. Adresse de la passerelle du réseau local, ex : 192.168.1.1
#
# Les données fixes :
# 1. Adresse IP de l'interface VPN, ex : 10.0.0.1/24
# 2. Adresse réseau du VPN, ex : 10.0.0.0/24
# 3. Les ports DNS, SSH, WireGuard, ex : 53, 22, 61443
# 4. Adresses IP des clients, ex : 10.0.0.2...10.0.0.9
# 5. L'extension des noms est [nom].lan
#
# Limites
# * Il ne vérifie pas si le réseau VPN est différent du réseau local
# * Le script peut être lancé qu'une seule fois, certaines parties sont non reproductible
#
# Usage:   ./wireguard_install.sh
#************************************************#

if [[ $(id -u) -ne 0 ]]
then
  echo "Merci d'exécuter ce script en tant que root !"
  exit 1
fi

msg_info() {
  echo -e "\n ### $1 ###"
  echo -e "-------------------------------------------------------------------------------- \n" 
}

# Variables
ip_pub="$(wget -qO- ipv4.icanhazip.com)"
dep_apps='ufw wireguard wireguard-tools dnsmasq qrencode'
ip_wg_int='10.0.0.1'

port_ssh='22'
port_wg='61443'
port_dns='53'

net_int="$(ip route | grep default | awk '{print $5}')"
ip_gatway="$(ip route | grep default | awk '{print $3}')"

local_network="$(ip route | grep $net_int | grep -v default | awk '{print $1}')"
vpn_network='10.0.0.0/24'

msg_info 'Installation et configuration de WireGuard'

# Dependances

for app in $dep_apps
do
  if ! command -v $app
  then
    msg_info "Installation de $app !" 
    apt install $app -y
  fi
done

# Config ufw allow ports
msg_info 'Configuration du pare-feu UFW'
ufw allow $port_ssh/tcp comment 'OpenSSH'
ufw allow $port_wg/udp comment 'Wireguard VPN'
ufw allow $port_dns comment 'DNSmasq'

ufw enable

msg_info 'Configuration IP forward et NAT'
# Config routage ip_forward
if grep '#net/ipv4/ip_forward=1' /etc/ufw/sysctl.conf
then
  sed -i '/net\/ipv4\/ip_forward=1/ s/^#//g' /etc/ufw/sysctl.conf
elif grep 'net/ipv4/ip_forward=0' /etc/ufw/sysctl.conf
then
  sed -i 's/^net\/ipv4\/ip_forward=0$/net\/ipv4\/ip_forward=1/g'
else
  echo 'net/ipv4/ip_forward=1' >> /etc/ufw/sysctl.conf
fi

# Proxy_arp
if ! grep 'net/ipv4/conf/all/proxy_arp=1' /etc/ufw/sysctl.conf
then
  sed -i '/^net\/ipv4\/ip_forward=1$/a net\/ipv4\/conf\/all\/proxy_arp=1' /etc/ufw/sysctl.conf
fi

sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/g' /etc/default/ufw

if grep '#91azerfv4582ghy' /etc/wireguard/.wg.info
then
  msg_info "Impossible de relancer ce script !"
  exit 1
fi

# Ajoute un marqueur d'installation
echo "# Fichier d'informations
# WireGuard Install $(date +%Y%m%d%H%M%S)
#91azerfv4582ghy
" > /etc/wireguard/.wg.info

# Non reproductible
if ! grep '# WireGuard allow forwarding for trusted network' /etc/ufw/before.rules
then
  sed -i "/^# allow dhcp client to work$/i\
# WireGuard allow forwarding for trusted network\n\
-A ufw-before-forward -s $vpn_network -j ACCEPT\n\
-A ufw-before-forward -d $vpn_network -j ACCEPT\n\
-A ufw-before-forward -s $local_network -j ACCEPT\n\
-A ufw-before-forward -d $local_network -j ACCEPT\n" /etc/ufw/before.rules
fi

# Non reproductible
# config routage NAT
if ! grep '# WireGuard NAT table rules' /etc/ufw/before.rules
then
  echo "
# WireGuard NAT table rules
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o $net_int -j MASQUERADE

#End each table with COMMIT line or these rules won't be process
COMMIT
  " >> /etc/ufw/before.rules
fi

systemctl restart ufw.service || systemctl restart ufw.service

msg_info 'Configuration de Dnsmasq'

# config dnsmasq
if ! grep '# WireGuard Dnsmasq name list' /etc/hosts
then
  echo "
# WireGuard Dnsmasq name list, examples :
#192.168.1.112	nextcloud.lan
#192.168.1.21	proxmox.lan
  " >> /etc/hosts
fi

# /etc/nameservers.conf
dns_servers="$ip_gatway 8.8.8.8"
touch /etc/nameservers.conf
for server in $dns_servers
do
  if ! grep $server /etc/nameservers.conf
  then
    echo "nameserver $server" >> /etc/nameservers.conf
  fi
done

# Non reproductible
#  /etc/dnsmasq.conf
if ! grep '# Config WireGuard dnsmasq' /etc/dnsmasq.conf
then
  sed -i '/domain-needed$/ s/^#//g' /etc/dnsmasq.conf
  sed -i '/bogus-priv$/ s/^#//g' /etc/dnsmasq.conf
  sed -i 's/^#resolv-file=$/resolv-file=\/etc\/nameservers.conf/g' /etc/dnsmasq.conf
  sed -i 's/^#local=\/localnet\/$/local=\/lan\//g' /etc/dnsmasq.conf
  sed -i "s/^#listen-address=$/listen-address=127.0.0.1,${ip_wg_int}/g" /etc/dnsmasq.conf 
  echo '# Config WireGuard dnsmasq' >> /etc/dnsmasq.conf
fi

systemctl restart dnsmasq.service

msg_info 'Création et configuration du serveur WireGuard et des clients'

# Création du serveur 
if [[ ! -f /etc/wireguard/wg-server.conf ]]
then
  mkdir -p /etc/wireguard 
  # Création de clé privée 
  (umask 077; wg genkey > /etc/wireguard/wg-server-private.key)
  # Création de la clé publique
  wg pubkey < /etc/wireguard/wg-server-private.key > /etc/wireguard/wg-server-public.key
  
  priv_key="$(cat /etc/wireguard/wg-server-private.key)"
  
  # Configuration pour le serveur
  echo "[Interface]
Address = $ip_wg_int/24
ListenPort = $port_wg
PrivateKey = $priv_key" > /etc/wireguard/wg-server.conf
fi

pub_key_srv="$(cat /etc/wireguard/wg-server-public.key)"

# Configuration pour 8 clients et le serveur
for clt in {2..9}
do
  if [[ -f /etc/wireguard/clients/peer-${clt}/wg-peer-${clt}-private.key ]]
  then
    echo "La configuration pour le client peer-${clt} existe déjà !"
    exit 1
  fi  
  # Création de clé privée 
  mkdir -p /etc/wireguard/clients/peer-${clt}
  (umask 077; wg genkey > /etc/wireguard/clients/peer-${clt}/wg-peer-${clt}-private.key)
  # Création de la clé publique
  wg pubkey < /etc/wireguard/clients/peer-${clt}/wg-peer-${clt}-private.key > /etc/wireguard/clients/peer-${clt}/wg-peer-${clt}-public.key

  priv_key_cli="$(cat /etc/wireguard/clients/peer-${clt}/wg-peer-${clt}-private.key)"
  pub_key_cli="$(cat /etc/wireguard/clients/peer-${clt}/wg-peer-${clt}-public.key)"

  # Configuration pour le client
  echo "[Interface]
Address = 10.0.0.${clt}/24
PrivateKey = $priv_key_cli
DNS = $ip_wg_int
  
[peer]
PublicKey = $pub_key_srv
AllowedIPs = ${vpn_network}, $local_network
Endpoint = ${ip_pub}:${port_wg}
PersistentKeepalive = 25" > /etc/wireguard/clients/peer-${clt}/peer-${clt}.conf
  
  # Création des QR codes
  msg_info "Client : peer-${clt}, 10.0.0.${clt}/24"
  qrencode --type=ansiutf8 --read-from=/etc/wireguard/clients/peer-${clt}/peer-${clt}.conf
  
  qrencode --output=/etc/wireguard/clients/peer-${clt}/qr-peer-${clt}.png --read-from=/etc/wireguard/clients/peer-${clt}/peer-${clt}.conf
  
  # Configuration pour le serveur
  echo "
[Peer]
PublicKey = $pub_key_cli
AllowedIPs = 10.0.0.${clt}/32
  " >> /etc/wireguard/wg-server.conf
done

# Configuration des droits sur /etc/wireguard/
chmod 600 -R /etc/wireguard/
chown root:root -R /etc/wireguard/

msg_info "Activation de l'interface VPN"
# Activer l’interface automatiquement au démarrage de la machine.
systemctl enable wg-quick@wg-server.service

# Activation de l'interface VPN wg-server.
wg-quick up wg-server

echo "
### Quelques indications ###

Compléter la liste des noms DNS des machines locales dans le fichier /etc/hosts
puis appliquer les modifications avec la commande : sudo systemctl restart dnsmasq.

8 clients ont été créés automatiquement, peer-2, peer-3...peer-9
Les fichiers de configuration et les QR codes des clients se trouvent dans : /etc/wireguard/clients/peer-[N]

Pour envoyer les configurations aux machines clientes utiliser :
1* sous Linux utiliser la commande : sudo scp -r /etc/wireguard/clients/peer-[N] [USER]@[IP]:/home/[USER]
2* sous Windows utiliser WinSCP.
3* sur un smartphone afficher le QR code avec la commande : sudo qrencode --type=ansiutf8 --read-from=/etc/wireguard/clients/peer-[N]/peer-[N].conf
" 
