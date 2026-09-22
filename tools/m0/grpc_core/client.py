"""Measurements against server.py. Usage: client.py PORT CERTDIR"""
import grpc, sys, time, os
def rss(): return int(open("/proc/self/statm").read().split()[1]) * 4096
MiB = 1 << 20
port, d = sys.argv[1], sys.argv[2]
rd = lambda n: open(d + "/" + n, "rb").read()
ident = lambda b: b
def chan(cert="client", ca="ca"):
    creds = grpc.ssl_channel_credentials(root_certificates=rd(ca + ".pem"),
        private_key=rd(cert + ".key") if cert else None, certificate_chain=rd(cert + ".pem") if cert else None)
    return grpc.secure_channel("localhost:" + port, creds)
def call(c, name): return c.unary_unary("/m0.Echo/" + name, ident, ident)
base = rss()
c = chan(); call(c, "Unary")(b"hi", timeout=5)
print(f"client RSS after one mTLS call: {rss()/MiB:.1f} MiB (python+grpcio)")
# mTLS rejections
for label, kw in [("no client cert", dict(cert=None)), ("foreign-CA client cert", dict(cert="rogue")), ("untrusted server", dict(ca="rogue-ca"))]:
    try:
        call(chan(**kw), "Unary")(b"x", timeout=3); print(f"{label}: ACCEPTED (bad)")
    except grpc.RpcError as e: print(f"{label}: rejected ({e.code().name})")
# bidi ping-pong, then burst
rec = 0
def gen(n):
    for i in range(n): yield b"m%d" % i
out = list(c.stream_stream("/m0.Echo/Bidi", ident, ident)(gen(2100)))
print(f"bidi: sent 2100 got {len(out)} in order={out == [b'm%d' % i for i in range(2100)]}")
# 256 MiB through one stream
chunk = b"x" * 65536
srv0 = int(call(c, "Rss")(b""))
t0 = time.time()
n = int(c.stream_unary("/m0.Echo/Sink", ident, ident)(iter([chunk] * 4096)))
print(f"sink: {n/MiB:.0f} MiB at {n/MiB/(time.time()-t0):.0f} MiB/s; server RSS growth {(int(call(c,'Rss')(b''))-srv0)/MiB:.1f} MiB")
# connection churn: server RSS every 1000 connections
c.close()
last = None
for i in range(1, 5001):
    cc = chan(); call(cc, "Unary")(b"x", timeout=5); 
    if i % 1000 == 0:
        r = int(call(cc, "Rss")(b"")); print(f"{i} connections: server RSS {r/MiB:.1f} MiB" + (f" (+{(r-last)/1024:.0f} KiB, {(r-last)/1000:.0f} B/conn)" if last else "")); last = r
    cc.close()
