# The workload of bench.sh: a context with many small files and two big ones, and RUN steps that read and change them, so that what is measured is what a build of a big
# repository spends its time on - the transfer of the context, the layers of many files, the snapshots after each RUN, the cache, the push. Offline but for the base image.
FROM alpine:3.20
WORKDIR /app
COPY tree/ /app/tree/
COPY blob1.bin blob2.bin /app/
RUN find /app/tree -type f | wc -l > /app/count
RUN chmod -R go-w /app/tree && chown -R 1000:1000 /app/tree
RUN cat /app/blob1.bin | sha256sum > /app/blob1.sha
RUN mkdir /app/out && for i in 1 2 3; do cp -r /app/tree /app/out/t$i; done
ARG REV=1
RUN echo "rev $REV" > /app/rev
