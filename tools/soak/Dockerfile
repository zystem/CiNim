# The soak harness (NFR-013) as an image, to run the 72 h soak in a cluster next to another host (tools/soak/run72.sh, deploy/examples/soak72).
# glibc, not musl: the AddressSanitizer variant needs it. Build with tools/image/kaniko-build.sh (DOCKERFILE=tools/soak/Dockerfile TARGETS=-:cinim-soak).
# The CURVE keys are made at build time and are test keys only (tests/certs/curve, tools/zmq/gen_curve_keys.sh).
FROM nimlang/nim:2.2.4
RUN apt-get update && apt-get install -y --no-install-recommends libzmq3-dev libsodium-dev git ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /cinim
COPY cinim.nimble /cinim/cinim.nimble
RUN nimble install -y --depsOnly
COPY . /cinim
RUN mkdir -p build && tools/zmq/gen_curve_keys.sh \
    && nim c -d:release --hints:off --warnings:off -o:build/soak tools/soak/soak.nim \
    && nim c -d:sanitize --passC:-fsanitize=address --passL:-fsanitize=address --passC:-fno-omit-frame-pointer --hints:off --warnings:off \
         -o:build/soak-san tools/soak/soak.nim
# the output directory is a volume; FOREGROUND=1 keeps the launcher alive for as long as both runs (release and ASan) last
ENV FOREGROUND=1
ENTRYPOINT ["/cinim/tools/soak/run72.sh"]
CMD ["/out", "72"]
