#!/usr/bin/env python3
"""Makes the certificates for trying the mutual TLS to the key service (docs/hardware-key.md), self-signed, for development and tests only.
   certs.py OUTDIR      writes OUTDIR/{server,core,other,expired,wrong-server}.{crt,key}
   server        the key service's certificate (SAN 127.0.0.1, localhost): the core trusts exactly this one (CINIM_KEKD_CA)
   core          the core's client certificate: the key service accepts exactly this one
   other         another client certificate: must be refused
   expired       the core's key with a certificate that is over: must be refused
   wrong-server  another service's certificate for the same address: the core must refuse to talk to it
In a real setup the key service's certificate and the core's are made by whoever runs the cluster (a private CA, cert-manager) and their fingerprints are what is pinned."""
import datetime, ipaddress, os, sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID


def make(name, cn, days_from=-1, days_to=30, san=True, client=False, key=None):
    key = key or ec.generate_private_key(ec.SECP256R1())
    now = datetime.datetime.now(datetime.timezone.utc)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    b = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
         .serial_number(x509.random_serial_number())
         .not_valid_before(now + datetime.timedelta(days=days_from - (1 if days_to < 0 else 0)))
         .not_valid_after(now + datetime.timedelta(days=days_to))
         .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
         .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH if client else ExtendedKeyUsageOID.SERVER_AUTH]), critical=False))
    if san:
        b = b.add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost"), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), critical=False)
    cert = b.sign(key, hashes.SHA256())
    return key, cert


def write(out, name, key, cert):
    with open(os.path.join(out, name + ".key"), "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    os.chmod(os.path.join(out, name + ".key"), 0o600)
    with open(os.path.join(out, name + ".crt"), "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    k, c = make("server", "cinim-kekd", san=True); write(out, "server", k, c)
    k, c = make("core", "cinim-core", san=False, client=True); write(out, "core", k, c)
    core_key = k
    k, c = make("other", "cinim-core", san=False, client=True); write(out, "other", k, c)           # the same name, another key: a name is not an identity
    _, c = make("expired", "cinim-core", days_from=-10, days_to=-5, san=False, client=True, key=core_key); write(out, "expired", core_key, c)
    k, c = make("wrong-server", "cinim-kekd", san=True); write(out, "wrong-server", k, c)
    print("certificates written to", out)
