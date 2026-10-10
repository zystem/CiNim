# The image of the shard (chart cinim-shard): the core, static, nothing else but the CA certificates that
# the core's TLS client needs to reach a router over https. Build the context with tools/image/build_core.sh.
FROM scratch
COPY core-static /core
COPY ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 65532:65532
EXPOSE 18081 19742 19743 19744 19745
ENTRYPOINT ["/core"]
