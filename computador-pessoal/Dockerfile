FROM alpine:3.20

RUN apk add --no-cache netcat-openbsd

CMD ["sh", "-c", "while true; do printf 'computador-pessoal\\n' | nc -l -p 8080; done"]
