FROM alpine:3.20

RUN apk add --no-cache curl iproute2 iptables netcat-openbsd

COPY entrypoint.sh /usr/local/bin/cliente-entrypoint.sh
RUN chmod 755 /usr/local/bin/cliente-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/cliente-entrypoint.sh"]
