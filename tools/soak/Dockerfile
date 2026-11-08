# The soak harness (NFR-013) as an image, to run the 72 h soak in a cluster next to another host (tools/soak/run72.sh, deploy/examples/soak72).
# glibc, not musl: the AddressSanitizer variant needs it. Build with tools/image/kaniko-build.sh (DOCKERFILE=tools/soak/Dockerfile TARGETS=-:cinim-soak).
# The TLS keys are made at build time and are test keys only (tools/grpc/gen_tls.sh, into build/soak-certs).
FROM nimlang/nim:2.2.4
RUN apt-get update && apt-get install -y --no-install-recommends libsodium-dev git ca-certificates procps curl xz-utils cmake build-essential openssl zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# nghttp2 as a static archive where nimgrpc looks for it (1.57 or later)
RUN set -eu; W=$(mktemp -d); \
    curl -fsSL https://github.com/nghttp2/nghttp2/releases/download/v1.68.0/nghttp2-1.68.0.tar.xz | tar xJ -C "$W"; \
    cmake -S "$W/nghttp2-1.68.0" -B "$W/b" -DENABLE_LIB_ONLY=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_INSTALL_PREFIX=/opt/nghttp2 >/dev/null; \
    cmake --build "$W/b" -j"$(nproc)" --target install >/dev/null; rm -rf "$W"
WORKDIR /cinim
COPY cinim.nimble /cinim/cinim.nimble
RUN nimble install -y --depsOnly
COPY . /cinim
RUN mkdir -p build && sh tools/grpc/gen_tls.sh build/soak-certs 30 \
    && nim c -d:release --hints:off --warnings:off -o:build/soak tools/soak/soak.nim \
    && nim c -d:sanitize --passC:-fsanitize=address --passL:-fsanitize=address --passC:-fno-omit-frame-pointer --hints:off --warnings:off \
         -o:build/soak-san tools/soak/soak.nim
# the output directory is a volume; FOREGROUND=1 keeps the launcher alive for as long as both runs (release and ASan) last
ENV FOREGROUND=1
ENTRYPOINT ["/cinim/tools/soak/run72.sh"]
CMD ["/out", "72"]
