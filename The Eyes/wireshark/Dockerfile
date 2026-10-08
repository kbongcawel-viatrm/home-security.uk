FROM docker.io/library/alpine:3.20
RUN apk add --no-cache tshark jq curl
COPY capture.sh /usr/local/bin/capture.sh
RUN chmod +x /usr/local/bin/capture.sh
CMD ["/usr/local/bin/capture.sh"]
