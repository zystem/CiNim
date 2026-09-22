"""gRPC C-core reference server (ready-made grpcio, raw bytes, no custom protocol code). Usage: server.py PORT CERTDIR"""
import grpc, sys, time
from concurrent import futures
def rss(): return int(open("/proc/self/statm").read().split()[1]) * 4096
port, d = sys.argv[1], sys.argv[2]
ident = lambda b: b
def unary(req, ctx): return req
def rssm(req, ctx): return str(rss()).encode()
def bidi(it, ctx):
    for m in it: yield m
def sink(it, ctx): return str(sum(len(m) for m in it)).encode()
h = grpc.method_handlers_generic_handler("m0.Echo", {
    "Unary": grpc.unary_unary_rpc_method_handler(unary, ident, ident),
    "Rss": grpc.unary_unary_rpc_method_handler(rssm, ident, ident),
    "Bidi": grpc.stream_stream_rpc_method_handler(bidi, ident, ident),
    "Sink": grpc.stream_unary_rpc_method_handler(sink, ident, ident)})
s = grpc.server(futures.ThreadPoolExecutor(4), handlers=[h])
creds = grpc.ssl_server_credentials([(open(d + "/server.key", "rb").read(), open(d + "/server.pem", "rb").read())],
    root_certificates=open(d + "/ca.pem", "rb").read(), require_client_auth=True)
s.add_secure_port("127.0.0.1:" + port, creds); s.start(); s.wait_for_termination()
