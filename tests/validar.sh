#!/bin/sh
set -eu

compose='docker compose'
prefix=${NETWORK_PREFIX:-172.30}
started=0

fail() {
  printf 'ERRO: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [ "$started" -eq 1 ]; then
    $compose down -v --remove-orphans >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

command -v docker >/dev/null 2>&1 || fail 'Docker não foi encontrado. No PowerShell, execute este arquivo pelo WSL (wsl sh ./tests/validar.sh) ou por outro shell Unix.'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 não está disponível: use o comando "docker compose".'

printf '%s\n' 'Validando a configuração Compose...'
$compose config -q || fail 'docker compose config -q falhou.'

printf '%s\n' 'Verificando sobreposição das sub-redes antes de criar containers...'
conflicts=''
for subnet in "$prefix.10.0/24" "$prefix.20.0/24" "$prefix.30.0/24"; do
  found=$(
    for network in $(docker network ls --format '{{.Name}}'); do
      docker network inspect "$network" --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' 2>/dev/null |
        awk -v wanted="$subnet" -v network="$network" '
          function ipnum(value, a) { split(value, a, "."); return a[1]*16777216+a[2]*65536+a[3]*256+a[4] }
          function range(value, a, n, size) {
            split(value, a, "/"); n=ipnum(a[1]); size=2^(32-(a[2]+0));
            first=n-n%size; last=first+size-1; return first ":" last
          }
          NF && $0 != "null" {
            split(range(wanted), w, ":"); split(range($0), e, ":")
            if (w[1] <= e[2] && e[1] <= w[2]) print network "\t" $0
          }'
    done
  )
  [ -z "$found" ] || conflicts="$conflicts\n$found"
done
if [ -n "$conflicts" ]; then
  printf 'ERRO: as sub-redes do laboratório sobrepõem redes Docker existentes:\n%b\n' "$conflicts" >&2
  printf '%s\n' 'Nenhuma rede foi removida. Remova ou reenderece somente a rede conflitante de forma segura e execute novamente.' >&2
  exit 1
fi

$compose up -d --build
started=1

printf '%s\n' '[1/9] os quatro serviços devem estar running'
for service in firewall cliente nas computador-pessoal; do
  $compose ps --status running --services | grep -Fx "$service" >/dev/null 2>&1 || fail "serviço não está running: $service"
done

printf '%s\n' '[2/9] o cliente deve possuir nc'
$compose exec -T cliente sh -c 'command -v nc >/dev/null' || fail 'nc não está disponível no cliente.'

printf '%s\n' '[3/9] o listener do computador pessoal deve estar pronto'
ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if $compose exec -T computador-pessoal sh -c "nc -z -w 1 $prefix.30.10 8080" >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[ "$ready" -eq 1 ] || fail "o listener $prefix.30.10:8080 não ficou pronto"

printf '%s\n' '[4/9] HTTP externo -> NAS deve funcionar'
$compose exec -T cliente curl --fail --silent --show-error --max-time 5 "http://$prefix.10.2/" |
  grep -F 'NAS acessível pela DMZ' >/dev/null || fail 'HTTP para o NAS falhou.'

printf '%s\n' '[5/9] rotas e bloqueio cliente -> computador pessoal'
$compose exec -T cliente ip route get "$prefix.20.10" | grep -F "via $prefix.10.2" >/dev/null || fail 'rota cliente -> DMZ ausente.'
$compose exec -T cliente ip route get "$prefix.30.10" | grep -F "via $prefix.10.2" >/dev/null || fail 'rota cliente -> doméstica ausente.'
if $compose exec -T cliente nc -z -w 3 "$prefix.30.10" 8080; then fail 'o cliente alcançou o computador pessoal'; fi

printf '%s\n' '[6/9] rota e bloqueio NAS -> computador pessoal'
$compose exec -T nas ip route get "$prefix.30.10" | grep -F "via $prefix.20.2" >/dev/null || fail 'rota NAS -> doméstica ausente.'
if $compose exec -T nas nc -z -w 3 "$prefix.30.10" 8080; then fail 'o NAS alcançou o computador pessoal'; fi

printf '%s\n' '[7/9] porta não autorizada e política INPUT'
if $compose exec -T cliente nc -z -w 3 "$prefix.10.2" 81; then fail 'a porta 81 foi exposta pelo firewall'; fi
rules=$($compose exec -T firewall iptables -S)
printf '%s\n' "$rules" | grep -F -- '-P INPUT DROP' >/dev/null || fail 'política INPUT não é DROP.'

printf '%s\n' '[8/9] políticas, ip_forward, DNAT e MASQUERADE'
nat_rules=$($compose exec -T firewall iptables -t nat -S)
ip_forward=$($compose exec -T firewall cat /proc/sys/net/ipv4/ip_forward | tr -d '\r')
[ "$ip_forward" = 1 ] || fail 'ip_forward não está em 1.'
printf '%s\n' "$rules" | grep -F -- '-P FORWARD DROP' >/dev/null || fail 'política FORWARD não é DROP.'
printf '%s\n' "$rules" | grep -F -- '-P OUTPUT ACCEPT' >/dev/null || fail 'política OUTPUT não é ACCEPT.'
printf '%s\n' "$rules" | grep -E -- 'RELATED,ESTABLISHED|ESTABLISHED,RELATED' >/dev/null || fail 'regra de conexões estabelecidas ausente.'
printf '%s\n' "$rules" | grep -F -- '-j DROP' >/dev/null || fail 'regra de bloqueio FORWARD ausente.'
external_if=$($compose exec -T firewall sh -c "ip -o -4 addr show | awk '\$4 == \"$prefix.10.2/24\" {print \$2}'" | tr -d '\r')
dmz_if=$($compose exec -T firewall sh -c "ip -o -4 addr show | awk '\$4 == \"$prefix.20.2/24\" {print \$2}'" | tr -d '\r')
home_if=$($compose exec -T firewall sh -c "ip -o -4 addr show | awk '\$4 == \"$prefix.30.2/24\" {print \$2}'" | tr -d '\r')
[ -n "$external_if" ] && [ -n "$dmz_if" ] && [ -n "$home_if" ] || fail 'interfaces do firewall não foram identificadas.'
printf '%s\n' "$rules" | grep -F -- "-A FORWARD -i $external_if -o $home_if" | grep -F -- '-j DROP' >/dev/null || fail 'bloqueio externa -> doméstica ausente.'
printf '%s\n' "$rules" | grep -F -- "-A FORWARD -i $dmz_if -o $home_if" | grep -F -- '-j DROP' >/dev/null || fail 'bloqueio DMZ -> doméstica ausente.'
printf '%s\n' "$nat_rules" | grep -F -- "-A PREROUTING -i $external_if" | grep -F -- '--dport 80' | grep -F -- "${prefix}.20.10:80" >/dev/null || fail 'DNAT HTTP ausente.'
printf '%s\n' "$nat_rules" | grep -F -- 'MASQUERADE' >/dev/null || fail 'MASQUERADE ausente.'

printf '%s\n' '[9/9] configuração validada' 'Validação concluída: tráfego permitido/bloqueado e regras conferidos.'
