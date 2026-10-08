#!/usr/bin/env python3
"""A mutual-TLS front for the emulator of the key service (tools/kekd-emu): terminates TLS, asks the client for a certificate and lets in only the one that is pinned,
then passes the plain HTTP to the emulator on 127.0.0.1. It stands for the TLS side of the real key service, so that the core's https client can be tried.
   tls-front.py --listen 8444 --backend 8443 --cert server.crt --key server.key --client-cert core.crt
Only the certificate in --client-cert is accepted (it is the trust anchor, and its fingerprint is checked once more in the handler); a name in a certificate proves nothing.
Every connection, accepted or refused, is written to stdout with the client certificate's fingerprint: the audit trail the real service must keep."""
import argparse, hashlib, socket, ssl, sys, threading, time


def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, required=True)
    ap.add_argument("--backend", type=int, required=True)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--client-cert", required=True)
    a = ap.parse_args()
    pinned = ssl.PEM_cert_to_DER_cert(open(a.client_cert).read())
    pin = hashlib.sha256(pinned).hexdigest()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(a.cert, a.key)
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_verify_locations(a.client_cert)          # the only anchor
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.listen))
    srv.listen(32)
    print("tls-front: listening on", a.listen, "pinned client", pin[:16], flush=True)

    def handle(raw, peer):
        try:
            tls = ctx.wrap_socket(raw, server_side=True)
        except (ssl.SSLError, OSError) as e:
            print(time.strftime("%H:%M:%S"), "REFUSED", peer[0], str(e)[:80], flush=True)
            raw.close()
            return
        der = tls.getpeercert(binary_form=True)
        fp = hashlib.sha256(der).hexdigest() if der else ""
        if fp != pin:                                    # belt and braces: the handshake already refused anything else
            print(time.strftime("%H:%M:%S"), "REFUSED (fingerprint)", fp[:16], flush=True)
            tls.close()
            return
        print(time.strftime("%H:%M:%S"), "ACCEPTED", fp[:16], flush=True)
        try:
            up = socket.create_connection(("127.0.0.1", a.backend), timeout=5)
        except OSError:
            tls.close()
            return
        t = threading.Thread(target=pipe, args=(up, tls), daemon=True)
        t.start()
        pipe(tls, up)

    while True:
        raw, peer = srv.accept()
        threading.Thread(target=handle, args=(raw, peer), daemon=True).start()


if __name__ == "__main__":
    main()
