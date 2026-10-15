#!/bin/sh
set -eu

compose='docker compose'
cleanup() {
  $compose down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

$compose config -q
$compose up -d --build

echo '[1/9] todos os serviços devem estar running'
for service in firewall cliente nas computador-pessoal; do
  status=$($compose ps --status running --services | grep -Fx "$service" || true)
  [ "$status" = "$service" ] || {
    echo "ERRO: serviço não está running: $service" >&2
    exit 1
  }
done

echo '[2/9] cliente deve possuir nc'
$compose exec -T cliente sh -c 'command -v nc >/dev/null'

echo '[3/9] listener doméstico deve estar pronto antes dos negativos'
ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if $compose exec -T computador-pessoal sh -c 'nc -z -w 1 172.30.30.10 8080' >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = 1 ] || {
  echo 'ERRO: o listener 172.30.30.10:8080 não ficou pronto' >&2
  exit 1
}

echo '[4/9] HTTP externo -> NAS deve funcionar'
$compose exec -T cliente curl --fail --silent --show-error --max-time 5 http://172.30.10.2/ \
  | grep -F 'NAS acessível pela DMZ' >/dev/null

echo '[5/9] rota externa -> doméstica deve ser inspecionada'
$compose exec -T cliente ip route get 172.30.20.10 | grep -F 'via 172.30.10.2' >/dev/null
$compose exec -T cliente ip route get 172.30.30.10 | grep -F 'via 172.30.10.2' >/dev/null
if $compose exec -T cliente nc -z -w 3 172.30.30.10 8080; then
  echo 'ERRO: o cliente alcançou o computador pessoal' >&2
  exit 1
fi

echo '[6/9] NAS deve rotear via firewall e ser bloqueado'
$compose exec -T nas ip route get 172.30.30.10 | grep -F 'via 172.30.20.2' >/dev/null
if $compose exec -T nas nc -z -w 3 172.30.30.10 8080; then
  echo 'ERRO: o NAS alcançou o computador pessoal' >&2
  exit 1
fi

echo '[7/9] porta não autorizada do NAS deve estar fechada'
if $compose exec -T cliente nc -z -w 3 172.30.10.2 81; then
  echo 'ERRO: a porta 81 foi exposta pelo firewall' >&2
  exit 1
fi
$compose exec -T firewall iptables -L INPUT -n | grep -E 'policy DROP|Chain INPUT.*policy DROP' >/dev/null

echo '[8/9] inspeção das políticas, do DNAT e do encaminhamento'
rules=$($compose exec -T firewall iptables -S)
nat_rules=$($compose exec -T firewall iptables -t nat -S)
ip_forward=$($compose exec -T firewall cat /proc/sys/net/ipv4/ip_forward | tr -d '\r')
[ "$ip_forward" = 1 ]
printf '%s\n' "$rules" | grep -F -- '-P INPUT DROP' >/dev/null
printf '%s\n' "$rules" | grep -F -- '-P FORWARD DROP' >/dev/null
printf '%s\n' "$rules" | grep -F -- '-P OUTPUT ACCEPT' >/dev/null
printf '%s\n' "$rules" | grep -F -- '-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' >/dev/null
printf '%s\n' "$rules" | grep -F -- '-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' >/dev/null
printf '%s\n' "$rules" | grep -F -- '-A FORWARD -i ' | grep -F -- '-o ' | grep -F -- '-j DROP' >/dev/null
external_if=$($compose exec -T firewall sh -c "ip -o -4 addr show | awk '\$4 == \"172.30.10.2/24\" {print \$2}'" | tr -d '\r')
dmz_if=$($compose exec -T firewall sh -c "ip -o -4 addr show | awk '\$4 == \"172.30.20.2/24\" {print \$2}'" | tr -d '\r')
home_if=$($compose exec -T firewall sh -c "ip -o -4 addr show | awk '\$4 == \"172.30.30.2/24\" {print \$2}'" | tr -d '\r')
[ -n "$external_if" ] && [ -n "$dmz_if" ] && [ -n "$home_if" ]
printf '%s\n' "$rules" | grep -F -- "-A FORWARD -i $external_if -o $home_if" | grep -F -- '-j DROP' >/dev/null
printf '%s\n' "$rules" | grep -F -- "-A FORWARD -i $dmz_if -o $home_if" | grep -F -- '-j DROP' >/dev/null
printf '%s\n' "$nat_rules" | grep -F -- "-A PREROUTING -i $external_if" | grep -F -- '--dport 80' | grep -F -- 'DNAT' | grep -F -- '172.30.20.10:80' >/dev/null
printf '%s\n' "$nat_rules" | grep -F -- 'MASQUERADE' >/dev/null

echo '[9/9] configuração validada'
echo 'Validação concluída: regras e tráfego permitido/bloqueado conferidos.'
