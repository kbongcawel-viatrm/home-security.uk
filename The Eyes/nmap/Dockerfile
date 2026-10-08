FROM docker.io/library/alpine:3.20
RUN apk add --no-cache nmap curl jq python3
COPY scan.sh /usr/local/bin/scan.sh
RUN chmod +x /usr/local/bin/scan.sh
CMD ["/usr/local/bin/scan.sh"]
