# Sourced by the scripts that start something on a port they chose (the soak, the port-forwards, the smoke checks):
#   . "$(dirname "$0")/../test/portfree.sh"; require_free_port 19720 "the soak"
# A port that something already listens on belongs to another process (an earlier run, a forgotten forward): what is started beside it fails quietly or is answered by the old one, and the
# result is about the old one. So the script stops, naming the port and how to find the holder. POSIX sh.

port_in_use() {
  # 0 when something listens on the TCP port of this machine
  if command -v ss >/dev/null 2>&1; then
    [ -n "$(ss -ltn "sport = :$1" 2>/dev/null | sed 1d)" ]
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    python3 -c "import socket,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try: s.bind(('127.0.0.1', int(sys.argv[1])))
except OSError: sys.exit(0)
sys.exit(1)" "$1"
  fi
}

require_free_port() {
  # require_free_port PORT WHAT: stops the script (exit 2) when the port is in use
  if port_in_use "$1"; then
    echo "$2: the port $1 is in use (an earlier run, a forgotten forward or a scratch server): what is started on it would be answered by that instead; find it with: ss -ltnp | grep $1" >&2
    exit 2
  fi
}
