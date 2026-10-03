# The router image (SHD-006): one static binary, nothing else.
#   tools/shim/build_static.sh build/router-static src/router/main.nim "" 0
#   docker build -f deploy/router/Dockerfile -t <registry>/cinim-router:<tag> build
FROM scratch
COPY router-static /router
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/router"]
