FROM nginx@sha256:72ba65eb42c10344912a84ff42408db7d34f2feb642204570ab8fc5ffd29f1d3

COPY config /opt/loresuelvo/gateway/config
COPY nginx /opt/loresuelvo/gateway/nginx
COPY --chmod=0755 entrypoint.sh /usr/local/bin/loresuelvo-gateway

RUN rm /etc/nginx/conf.d/default.conf

ENTRYPOINT ["/usr/local/bin/loresuelvo-gateway"]
CMD ["nginx", "-g", "daemon off;"]
