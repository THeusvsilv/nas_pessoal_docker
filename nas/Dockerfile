FROM nginx:1.27-alpine

RUN apk add --no-cache iproute2 netcat-openbsd

COPY entrypoint.sh /usr/local/bin/nas-entrypoint.sh
RUN chmod 755 /usr/local/bin/nas-entrypoint.sh
