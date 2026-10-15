# Relatório do laboratório

## 1. Definição do Case

O case modela um cliente externo que precisa acessar por HTTP um NAS, sem que a publicação torne alcançável o computador da rede doméstica. O Compose cria três redes bridge isoladas: `externa` (`172.30.10.0/24`), `dmz` (`172.30.20.0/24`) e `domestica` (`172.30.30.0/24`). O firewall é o único container conectado às três redes.

| Segmento | Participantes e endereços | Função |
|---|---|---|
| Externa | firewall `172.30.10.2`, cliente `172.30.10.10` | origem do acesso |
| DMZ | firewall `172.30.20.2`, NAS `172.30.20.10` | serviço HTTP |
| Doméstica | firewall `172.30.30.2`, computador `172.30.30.10` | ativo a proteger |

## 2. Diagnóstico: Cenário Atual versus Proposta de Solução

No cenário sem segmentação, publicar o NAS pode criar um caminho indevido até outros ativos internos. A proposta coloca o firewall entre os segmentos, habilita `ip_forward`, usa política padrão `FORWARD DROP` e libera apenas o fluxo previsto para o NAS. O serviço publicado não usa `ports` do Docker: o cliente chama `172.30.10.2:80` e o firewall aplica DNAT para `172.30.20.10:80`. Uma porta publicada pelo Docker (`HOST:CONTAINER`) é um encaminhamento do host para um container; DNAT é a alteração do destino de pacotes que atravessam este firewall, portanto são mecanismos diferentes.

Cliente e NAS possuem `NET_ADMIN` exclusivamente para instalar as rotas explícitas que obrigam seus tráfegos inter-redes a passar pelo firewall (`172.30.10.2` e `172.30.20.2`, respectivamente). Isso é uma decisão de laboratório, não uma recomendação de hardening. O firewall também usa `NET_ADMIN` para instalar as regras. O computador doméstico não recebe essa capacidade.

O host Docker pode contornar essa política: ele está fora do namespace do firewall e pode acessar bridges, containers ou portas publicadas diretamente. Assim, a evidência deve ser coletada a partir de `cliente` e `nas`; a segurança do host exigiria controles próprios.

### DNAT e retorno

O `PREROUTING` do firewall traduz TCP/80 recebido na interface externa para o NAS. A regra de `FORWARD` autoriza somente o novo fluxo externo → NAS. `MASQUERADE` no tráfego destinado ao NAS favorece o retorno pelo firewall, e o conntrack desfaz a tradução na resposta. Fluxos novos externa → doméstica e DMZ → doméstica são descartados, além do `DROP` padrão.

## 3. Matriz de Regras de Segurança

| Origem | Destino | Porta/protocolo | Ação | Justificativa |
|---|---|---|---|---|
| Cliente / externa | Firewall → NAS `172.30.20.10` | TCP/80 | **Permitir + DNAT** | Publicar somente o HTTP do NAS |
| Externa | Rede doméstica `172.30.30.0/24` | Qualquer | **Bloquear** | Impedir acesso do cliente ao computador |
| DMZ / NAS | Rede doméstica `172.30.30.0/24` | Qualquer | **Bloquear** | Conter comprometimento do NAS |
| Qualquer fluxo não previsto | Outra rede | Qualquer | **Bloquear (`FORWARD DROP`)** | Negar por padrão |
| Respostas de conexões permitidas | Origem correspondente | `ESTABLISHED,RELATED` | **Permitir** | Completar somente conexões já autorizadas |
| Firewall | Saída | Qualquer | `OUTPUT ACCEPT` | Configuração permissiva do laboratório; deve ser restringida em produção |

**DNAT separado:** `TCP 172.30.10.2:80` → `TCP 172.30.20.10:80`, na tabela `nat`, cadeia `PREROUTING`. Isso não significa que todas as portas do NAS foram publicadas.

## 4. Metodologia de Testes e Validação

### Procedimento previsto

1. Validar a configuração com `docker compose config -q`.
2. Construir e iniciar com `docker compose up -d --build`; verificar os quatro serviços com `docker compose ps`.
3. No `cliente`, testar `curl http://172.30.10.2/` e confirmar o texto `NAS acessível pela DMZ`.
4. No `cliente` e no `nas`, testar `nc -z -w 3 172.30.30.10 8080`; ambas as tentativas devem falhar ou expirar.
5. Confirmar as rotas com `ip route get` e as regras com `iptables -S` e `iptables -t nat -S`.
6. Verificar que TCP/81 no firewall não é autorizado e que a política `INPUT` é `DROP`.

O roteiro correspondente está em `tests/validar.sh`. A evidência deve incluir sua saída, `docker compose ps`, contadores de `iptables -L -n -v` e as regras NAT, sem confundir uma porta sem serviço com prova de filtragem.

### Evidências e limitações atuais

Não foi inventada execução nem resultado aprovado/reprovado: este documento registra a configuração e os resultados esperados. Os testes Docker completos ainda dependem do avaliador, pois o ambiente atual apresenta conflito de sub-rede com as faixas `172.30.10.0/24`, `172.30.20.0/24` e/ou `172.30.30.0/24`. Para diagnosticar, usar `docker network ls` e `docker network inspect <rede>`; alterar as faixas exige atualizar IPs, rotas, regras e testes de forma consistente. Não se deve usar publicação de portas como solução para esse conflito.

## 5. Conclusão

A solução proposta separa externa, DMZ e rede doméstica, encaminha explicitamente o HTTP do cliente ao NAS por DNAT e bloqueia os acessos novos à rede doméstica. Ela é adequada para estudo de roteamento, `iptables`, DNAT e MASQUERADE, mas a conclusão permanece limitada ao código e à configuração declarada até que o avaliador execute os testes em ambiente sem conflito.

Para produção seriam necessários TLS, autenticação, políticas de saída restritivas, persistência e monitoramento, hardening das imagens e do host, tratamento de IPv6 e revisão das capacidades `NET_ADMIN`. Nenhuma alteração de API ou banco é aplicável a este projeto, e nenhum commit é necessário para esta documentação.
