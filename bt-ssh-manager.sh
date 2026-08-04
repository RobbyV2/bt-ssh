#!/usr/bin/env bash
#
# bt-ssh-manager.sh - SSH over Bluetooth (PAN/NAP) manager.
# Run "bt-ssh-manager.sh help" for the command list.
#
set -euo pipefail

VERSION="1.0.0"
PROG="$(basename "${BASH_SOURCE[0]}")"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/${PROG}"
ORIG_ARGV=("$@")

STATE_DIR="/etc/bt-ssh"
STATE_FILE="${STATE_DIR}/config"
UNIT_DIR="/etc/systemd/system"
AVAHI_DIR="/etc/avahi/services"
AVAHI_FILE="${AVAHI_DIR}/bt-ssh.service"

SVC_AGENT="bt-ssh-agent.service"
SVC_NAP="bt-ssh-nap.service"
SVC_SPP="bt-ssh-spp.service"
SVC_PORTAL="bt-ssh-portal.service"
SVC_NET="bt-ssh-net.service"
SVC_DHCP="bt-ssh-dhcp.service"

DEF_BRIDGE="nap0"
DEF_SUBNET="10.137.0.0/24"
DEF_SSH_PORT="22"
DEF_ZONE="trusted"
DEF_SPP_NAME="Serial"
DEF_SPP_BAUD="115200"

# ---------------------------------------------------------------- output ----

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
	C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
	C_C=$'\033[36m'; C_D=$'\033[2m';  C_B=$'\033[1m'; C_0=$'\033[0m'
else
	C_R=""; C_G=""; C_Y=""; C_C=""; C_D=""; C_B=""; C_0=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$C_C" "$C_0" "$*"; }
ok()   { printf '  %sOK%s    %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$C_Y" "$C_0" "$*" >&2; }
bad()  { printf '  %sBAD%s   %s\n' "$C_R" "$C_0" "$*"; }
info() { printf '  %s%s%s\n' "$C_D" "$*" "$C_0"; }
die()  { printf '%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
	[[ "${OPT_YES:-no}" == "yes" ]] && return 0
	local reply
	printf '%s [y/N] ' "$1"
	read -r reply || true
	[[ "$reply" =~ ^[Yy] ]]
}

require_root() {
	[[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
	have sudo || die "This command needs root permission. Run it as root."
	[[ -r "$SELF" ]] || die "This command needs root permission. Run it again as root."
	printf '%sThis command needs root permission. sudo starts now.%s\n' "$C_D" "$C_0" >&2
	exec sudo -- bash "$SELF" ${ORIG_ARGV[@]+"${ORIG_ARGV[@]}"}
}

# ------------------------------------------------------------- ipv4 math ----

ip2int() {
	local IFS=. a b c d
	read -r a b c d <<<"$1"
	printf '%s' $(((a << 24) | (b << 16) | (c << 8) | d))
}

int2ip() {
	local i=$1
	printf '%d.%d.%d.%d' $(((i >> 24) & 255)) $(((i >> 16) & 255)) \
		$(((i >> 8) & 255)) $((i & 255))
}

valid_ip() {
	local IFS=. p
	read -ra p <<<"$1"
	[[ ${#p[@]} -eq 4 ]] || return 1
	for o in "${p[@]}"; do
		[[ "$o" =~ ^[0-9]+$ ]] || return 1
		((o >= 0 && o <= 255)) || return 1
	done
}

# -------------------------------------------------------------- detection ----

detect_adapter() {
	local d
	for d in /sys/class/bluetooth/hci*; do
		if [[ -e "$d" ]]; then
			basename "$d"
			return 0
		fi
	done
	printf 'hci0'
}

detect_user() {
	if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
		printf '%s' "$SUDO_USER"
		return 0
	fi
	local u
	u="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd 2>/dev/null || true)"
	printf '%s' "${u:-root}"
}

detect_hostname() {
	local h
	h="$(hostnamectl --static 2>/dev/null || true)"
	[[ -z "$h" ]] && h="$(hostname 2>/dev/null || true)"
	printf '%s' "${h:-linux}"
}

nm_running() {
	have nmcli || return 1
	systemctl is-active --quiet NetworkManager 2>/dev/null
}

detect_backend() {
	if nm_running && have dnsmasq; then printf 'nm'
	elif nm_running && [[ -x /usr/sbin/dnsmasq ]]; then printf 'nm'
	elif have dnsmasq || [[ -x /usr/sbin/dnsmasq ]]; then printf 'manual'
	elif nm_running; then printf 'nm'
	else printf 'manual'
	fi
}

detect_firewall() {
	if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
		printf 'firewalld'
	elif have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
		printf 'ufw'
	elif have nft; then
		printf 'nftables'
	elif have iptables; then
		printf 'iptables'
	else
		printf 'none'
	fi
}

dnsmasq_bin() {
	local p
	for p in /usr/sbin/dnsmasq /usr/bin/dnsmasq /sbin/dnsmasq; do
		if [[ -x "$p" ]]; then
			printf '%s' "$p"
			return 0
		fi
	done
	command -v dnsmasq 2>/dev/null || true
}

python_bin() {
	local p
	for p in /usr/bin/python3 /usr/local/bin/python3; do
		if [[ -x "$p" ]]; then
			printf '%s' "$p"
			return 0
		fi
	done
	command -v python3 2>/dev/null || true
}

login_bin() {
	local p
	for p in /bin/login /usr/bin/login /sbin/login; do
		if [[ -x "$p" ]]; then
			printf '%s' "$p"
			return 0
		fi
	done
	command -v login 2>/dev/null || true
}

pkg_hint() {
	local names="$1"
	if have rpm-ostree; then printf 'sudo rpm-ostree install %s' "$names"
	elif have dnf; then printf 'sudo dnf install %s' "$names"
	elif have apt-get; then printf 'sudo apt-get install %s' "$names"
	elif have pacman; then printf 'sudo pacman -S %s' "$names"
	elif have zypper; then printf 'sudo zypper install %s' "$names"
	else printf 'install these packages: %s' "$names"
	fi
}

pkg_name() {
	case "$1" in
	dnsmasq)
		if have apt-get; then printf 'dnsmasq-base'; else printf 'dnsmasq'; fi ;;
	bluez)
		if have pacman; then printf 'bluez bluez-utils'; else printf 'bluez'; fi ;;
	esac
}

# ------------------------------------------------------------------ state ----

load_state() {
	BT_ALIAS=""; SSH_USER=""; ADAPTER=""; BRIDGE=""; HOST_IP=""; PREFIX=""
	SUBNET=""; BACKEND=""; FIREWALL=""; ZONE=""; PORTAL=""; MDNS=""
	SSH_PORT=""; AUTO_PAIR=""; DHCP_START=""; DHCP_END=""
	PAN=""; SPP=""; SPP_NAME=""; SPP_CHANNEL=""; SPP_SHELL=""; SPP_DEBUG=""
	if [[ -r "$STATE_FILE" ]]; then
		# shellcheck disable=SC1090
		. "$STATE_FILE"
	fi
	BRIDGE="${BRIDGE:-$DEF_BRIDGE}"
	SSH_PORT="${SSH_PORT:-$DEF_SSH_PORT}"
	# An install that came before the SPP feature has no PAN or SPP value.
	PAN="${PAN:-yes}"
	SPP="${SPP:-no}"
	SPP_NAME="${SPP_NAME:-$DEF_SPP_NAME}"
	SPP_DEBUG="${SPP_DEBUG:-no}"
}

installed() { [[ -f "${UNIT_DIR}/${SVC_NAP}" ]]; }

require_installed() {
	installed || die "The system is not installed. Run \"${PROG} install\" first."
}

save_state() {
	install -d -m 0755 "$STATE_DIR"
	cat >"$STATE_FILE" <<EOF
BT_ALIAS='${BT_ALIAS}'
SSH_USER='${SSH_USER}'
SSH_PORT='${SSH_PORT}'
ADAPTER='${ADAPTER}'
BRIDGE='${BRIDGE}'
HOST_IP='${HOST_IP}'
PREFIX='${PREFIX}'
SUBNET='${SUBNET}'
DHCP_START='${DHCP_START}'
DHCP_END='${DHCP_END}'
BACKEND='${BACKEND}'
FIREWALL='${FIREWALL}'
ZONE='${ZONE}'
PAN='${PAN}'
SPP='${SPP}'
SPP_NAME='${SPP_NAME}'
SPP_CHANNEL='${SPP_CHANNEL}'
SPP_SHELL='${SPP_SHELL}'
SPP_DEBUG='${SPP_DEBUG}'
PORTAL='${PORTAL}'
MDNS='${MDNS}'
AUTO_PAIR='${AUTO_PAIR}'
EOF
	chmod 0644 "$STATE_FILE"
	printf '%s' "$BT_ALIAS" >"${STATE_DIR}/alias"
	chmod 0644 "${STATE_DIR}/alias"
}

# ----------------------------------------------------------------- assets ----

write_dbuslite() {
	cat >"${STATE_DIR}/dbuslite.py" <<'PYEOF'
#!/usr/bin/python3
"""A small D-Bus client that uses only the Python standard library.

It does the part of the D-Bus protocol that this project needs: the EXTERNAL
handshake, method calls, method replies, errors, and file descriptor transfer.
It takes the place of dbus-python and PyGObject.
"""
import array
import errno
import os
import socket
import struct

METHOD_CALL = 1
METHOD_RETURN = 2
ERROR = 3
SIGNAL = 4
NO_REPLY_EXPECTED = 1

F_PATH = 1
F_INTERFACE = 2
F_MEMBER = 3
F_ERROR_NAME = 4
F_REPLY_SERIAL = 5
F_DESTINATION = 6
F_SENDER = 7
F_SIGNATURE = 8
F_UNIX_FDS = 9

ALIGN = {"y": 1, "b": 4, "n": 2, "q": 2, "i": 4, "u": 4, "x": 8, "t": 8,
         "d": 8, "s": 4, "o": 4, "g": 1, "a": 4, "(": 8, "{": 8, "v": 1,
         "h": 4}


class DBusError(Exception):
    def __init__(self, name, message=""):
        Exception.__init__(self, "%s: %s" % (name, message))
        self.name = name


def sig_end(sig, i):
    c = sig[i]
    if c == "a":
        return sig_end(sig, i + 1)
    if c in "({":
        close = ")" if c == "(" else "}"
        depth = 1
        j = i + 1
        while depth:
            if sig[j] == c:
                depth += 1
            elif sig[j] == close:
                depth -= 1
            j += 1
        return j
    return i + 1


def sig_split(sig):
    out = []
    i = 0
    while i < len(sig):
        j = sig_end(sig, i)
        out.append(sig[i:j])
        i = j
    return out


def pad(buf, n):
    r = len(buf) % n
    if r:
        buf.extend(b"\0" * (n - r))


def marshal(buf, sig, val, fds):
    c = sig[0]
    if c == "y":
        buf.append(val & 0xFF)
    elif c == "b":
        pad(buf, 4)
        buf.extend(struct.pack("<I", 1 if val else 0))
    elif c in "nq":
        pad(buf, 2)
        buf.extend(struct.pack("<h" if c == "n" else "<H", val))
    elif c in "iu":
        pad(buf, 4)
        buf.extend(struct.pack("<i" if c == "i" else "<I", val))
    elif c in "xt":
        pad(buf, 8)
        buf.extend(struct.pack("<q" if c == "x" else "<Q", val))
    elif c == "d":
        pad(buf, 8)
        buf.extend(struct.pack("<d", val))
    elif c == "h":
        pad(buf, 4)
        buf.extend(struct.pack("<I", len(fds)))
        fds.append(val)
    elif c in "so":
        data = val.encode("utf-8")
        pad(buf, 4)
        buf.extend(struct.pack("<I", len(data)))
        buf.extend(data)
        buf.append(0)
    elif c == "g":
        data = val.encode("ascii")
        buf.append(len(data))
        buf.extend(data)
        buf.append(0)
    elif c == "v":
        vsig, vval = val
        data = vsig.encode("ascii")
        buf.append(len(data))
        buf.extend(data)
        buf.append(0)
        marshal(buf, vsig, vval, fds)
    elif c == "a":
        esig = sig[1:]
        pad(buf, 4)
        at = len(buf)
        buf.extend(b"\0\0\0\0")
        pad(buf, ALIGN[esig[0]])
        start = len(buf)
        if esig[0] == "{":
            ksig = esig[1]
            vsig = esig[2:-1]
            for k, v in val.items():
                pad(buf, 8)
                marshal(buf, ksig, k, fds)
                marshal(buf, vsig, v, fds)
        else:
            for item in val:
                marshal(buf, esig, item, fds)
        buf[at:at + 4] = struct.pack("<I", len(buf) - start)
    elif c == "(":
        pad(buf, 8)
        for s, v in zip(sig_split(sig[1:-1]), val):
            marshal(buf, s, v, fds)
    else:
        raise ValueError("cannot send type %r" % c)


class Reader:
    def __init__(self, data, offset=0, fds=None):
        self.d = data
        self.o = offset
        self.fds = fds or []

    def align(self, n):
        r = self.o % n
        if r:
            self.o += n - r

    def read(self, sig):
        c = sig[0]
        if c == "y":
            v = self.d[self.o]
            self.o += 1
            return v
        if c == "b":
            self.align(4)
            v = struct.unpack_from("<I", self.d, self.o)[0]
            self.o += 4
            return bool(v)
        if c in "nq":
            self.align(2)
            v = struct.unpack_from("<h" if c == "n" else "<H", self.d, self.o)[0]
            self.o += 2
            return v
        if c in "iu":
            self.align(4)
            v = struct.unpack_from("<i" if c == "i" else "<I", self.d, self.o)[0]
            self.o += 4
            return v
        if c == "h":
            self.align(4)
            idx = struct.unpack_from("<I", self.d, self.o)[0]
            self.o += 4
            return self.fds[idx] if idx < len(self.fds) else -1
        if c in "xt":
            self.align(8)
            v = struct.unpack_from("<q" if c == "x" else "<Q", self.d, self.o)[0]
            self.o += 8
            return v
        if c == "d":
            self.align(8)
            v = struct.unpack_from("<d", self.d, self.o)[0]
            self.o += 8
            return v
        if c in "so":
            self.align(4)
            n = struct.unpack_from("<I", self.d, self.o)[0]
            self.o += 4
            v = self.d[self.o:self.o + n].decode("utf-8", "replace")
            self.o += n + 1
            return v
        if c == "g":
            n = self.d[self.o]
            self.o += 1
            v = self.d[self.o:self.o + n].decode("ascii", "replace")
            self.o += n + 1
            return v
        if c == "v":
            vsig = self.read("g")
            return self.read(vsig)
        if c == "a":
            esig = sig[1:]
            self.align(4)
            n = struct.unpack_from("<I", self.d, self.o)[0]
            self.o += 4
            self.align(ALIGN[esig[0]])
            end = self.o + n
            if esig[0] == "{":
                ksig = esig[1]
                vsig = esig[2:-1]
                out = {}
                while self.o < end:
                    self.align(8)
                    k = self.read(ksig)
                    out[k] = self.read(vsig)
                return out
            out = []
            while self.o < end:
                out.append(self.read(esig))
            return out
        if c == "(":
            self.align(8)
            return tuple(self.read(s) for s in sig_split(sig[1:-1]))
        raise ValueError("cannot read type %r" % c)


class Message:
    def __init__(self, mtype, serial=0, path=None, interface=None, member=None,
                 destination=None, sender=None, signature="", body=(),
                 reply_serial=None, error_name=None, flags=0, fds=None):
        self.mtype = mtype
        self.serial = serial
        self.path = path
        self.interface = interface
        self.member = member
        self.destination = destination
        self.sender = sender
        self.signature = signature
        self.body = body
        self.reply_serial = reply_serial
        self.error_name = error_name
        self.flags = flags
        self.fds = fds or []

    def encode(self):
        out_fds = []
        body = bytearray()
        for s, v in zip(sig_split(self.signature), self.body):
            marshal(body, s, v, out_fds)

        fields = []
        if self.path is not None:
            fields.append((F_PATH, ("o", self.path)))
        if self.interface is not None:
            fields.append((F_INTERFACE, ("s", self.interface)))
        if self.member is not None:
            fields.append((F_MEMBER, ("s", self.member)))
        if self.error_name is not None:
            fields.append((F_ERROR_NAME, ("s", self.error_name)))
        if self.reply_serial is not None:
            fields.append((F_REPLY_SERIAL, ("u", self.reply_serial)))
        if self.destination is not None:
            fields.append((F_DESTINATION, ("s", self.destination)))
        if self.signature:
            fields.append((F_SIGNATURE, ("g", self.signature)))
        if out_fds:
            fields.append((F_UNIX_FDS, ("u", len(out_fds))))

        head = bytearray()
        head.extend(struct.pack("<BBBBII", ord("l"), self.mtype, self.flags, 1,
                                len(body), self.serial))
        ignore = []
        marshal(head, "a(yv)", fields, ignore)
        pad(head, 8)
        head.extend(body)
        return bytes(head), out_fds


def decode(data, fds):
    """Return (message, consumed) or (None, 0) when more bytes are necessary."""
    if len(data) < 16:
        return None, 0
    endian, mtype, flags, _ver, blen, serial = struct.unpack_from("<BBBBII",
                                                                  data, 0)
    if endian != ord("l"):
        raise DBusError("bt.Endian", "only little endian is supported")
    flen = struct.unpack_from("<I", data, 12)[0]
    hend = 16 + flen
    hend += (-hend) % 8
    total = hend + blen
    if len(data) < total:
        return None, 0

    reader = Reader(data, 12, fds)
    fields = reader.read("a(yv)")
    msg = Message(mtype, serial=serial, flags=flags)
    nfds = 0
    for code, value in fields:
        if code == F_PATH:
            msg.path = value
        elif code == F_INTERFACE:
            msg.interface = value
        elif code == F_MEMBER:
            msg.member = value
        elif code == F_ERROR_NAME:
            msg.error_name = value
        elif code == F_REPLY_SERIAL:
            msg.reply_serial = value
        elif code == F_DESTINATION:
            msg.destination = value
        elif code == F_SENDER:
            msg.sender = value
        elif code == F_SIGNATURE:
            msg.signature = value
        elif code == F_UNIX_FDS:
            nfds = value
    msg.fds = fds[:nfds]
    del fds[:nfds]
    if msg.signature:
        body = Reader(data, hend, msg.fds)
        msg.body = tuple(body.read(s) for s in sig_split(msg.signature))
    return msg, total


class Bus:
    def __init__(self, address=None):
        self.sock = self._connect(address)
        self.serial = 0
        self.inbuf = bytearray()
        self.infds = []
        self.objects = {}
        self.unique = None
        self._handshake()
        self.unique = self.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                "org.freedesktop.DBus", "Hello")[0]

    @staticmethod
    def _connect(address):
        if not address:
            address = os.environ.get("DBUS_SYSTEM_BUS_ADDRESS", "")
        path = ""
        for part in address.split(","):
            if part.startswith("unix:path="):
                path = part[len("unix:path="):]
                break
            if part.startswith("unix:abstract="):
                path = "\0" + part[len("unix:abstract="):]
                break
        if not path:
            for candidate in ("/run/dbus/system_bus_socket",
                              "/var/run/dbus/system_bus_socket"):
                if os.path.exists(candidate):
                    path = candidate
                    break
        if not path:
            raise DBusError("bt.NoBus", "the system bus socket was not found")
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(path)
        return sock

    def _line(self):
        out = bytearray()
        while not out.endswith(b"\r\n"):
            c = self.sock.recv(1)
            if not c:
                raise DBusError("bt.Auth", "the bus closed the connection")
            out.extend(c)
        return bytes(out[:-2])

    def _handshake(self):
        self.sock.sendall(b"\0")
        uid = str(os.getuid()).encode("ascii").hex().encode("ascii")
        self.sock.sendall(b"AUTH EXTERNAL " + uid + b"\r\n")
        reply = self._line()
        if not reply.startswith(b"OK"):
            raise DBusError("bt.Auth", reply.decode("ascii", "replace"))
        self.sock.sendall(b"NEGOTIATE_UNIX_FD\r\n")
        reply = self._line()
        if not reply.startswith(b"AGREE_UNIX_FD"):
            raise DBusError("bt.Auth", "the bus refused file descriptors")
        self.sock.sendall(b"BEGIN\r\n")

    def fileno(self):
        return self.sock.fileno()

    def export(self, path, interface, methods):
        """methods maps a name to (in_signature, out_signature, function)."""
        self.objects.setdefault(path, {})[interface] = methods

    def send(self, msg):
        self.serial += 1
        msg.serial = self.serial
        data, fds = msg.encode()
        if fds:
            self.sock.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                        array.array("i", fds))])
        else:
            self.sock.sendall(data)
        return msg.serial

    def call(self, destination, path, interface, member, signature="", body=(),
             timeout=25.0):
        serial = self.send(Message(METHOD_CALL, path=path, interface=interface,
                                   member=member, destination=destination,
                                   signature=signature, body=body))
        deadline = None
        while True:
            reply = self._wait(serial, timeout, deadline)
            if reply is not None:
                return reply

    def _wait(self, serial, timeout, deadline):
        import select as _select
        import time as _time
        if deadline is None:
            deadline = _time.monotonic() + timeout
        while True:
            for msg in self._drain():
                if msg.reply_serial == serial:
                    if msg.mtype == ERROR:
                        text = msg.body[0] if msg.body else ""
                        raise DBusError(msg.error_name or "unknown", text)
                    return msg.body
                self.dispatch(msg)
            left = deadline - _time.monotonic()
            if left <= 0:
                raise DBusError("bt.Timeout", "no reply to serial %d" % serial)
            ready, _, _ = _select.select([self.sock], [], [], left)
            if ready and not self._fill():
                raise DBusError("bt.Closed", "the bus closed the connection")

    def _fill(self):
        try:
            data, anc, _flags, _addr = self.sock.recvmsg(
                65536, socket.CMSG_SPACE(64 * 4))
        except InterruptedError:
            return True
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                return True
            raise
        if not data and not anc:
            return False
        for level, ctype, cdata in anc:
            if level == socket.SOL_SOCKET and ctype == socket.SCM_RIGHTS:
                count = len(cdata) // 4
                got = array.array("i")
                got.frombytes(cdata[:count * 4])
                self.infds.extend(got.tolist())
        self.inbuf.extend(data)
        return True

    def _drain(self):
        out = []
        while True:
            msg, used = decode(bytes(self.inbuf), self.infds)
            if msg is None:
                break
            del self.inbuf[:used]
            out.append(msg)
        return out

    def process(self, timeout=None):
        """Read what is available and answer each incoming call."""
        import select as _select
        ready, _, _ = _select.select([self.sock], [], [], timeout)
        if ready:
            if not self._fill():
                raise DBusError("bt.Closed", "the bus closed the connection")
        for msg in self._drain():
            self.dispatch(msg)

    def dispatch(self, msg):
        if msg.mtype != METHOD_CALL:
            return
        if msg.interface == "org.freedesktop.DBus.Peer":
            if msg.member == "Ping":
                self.reply(msg, "", ())
            elif msg.member == "GetMachineId":
                self.reply(msg, "s", ("",))
            return
        table = self.objects.get(msg.path, {}).get(msg.interface)
        entry = table.get(msg.member) if table else None
        if entry is None:
            if msg.interface == "org.freedesktop.DBus.Introspectable":
                self.reply(msg, "s", (self.introspect(msg.path),))
                return
            self.error(msg, "org.freedesktop.DBus.Error.UnknownMethod",
                       "no method %s" % msg.member)
            return
        _in_sig, out_sig, func = entry
        try:
            result = func(msg, *msg.body)
        except DBusError as exc:
            self.error(msg, exc.name, str(exc))
            return
        except Exception as exc:                       # noqa: BLE001
            self.error(msg, "org.freedesktop.DBus.Error.Failed", str(exc))
            return
        if msg.flags & NO_REPLY_EXPECTED:
            return
        if result is None:
            result = ()
        elif not isinstance(result, tuple):
            result = (result,)
        self.reply(msg, out_sig, result)

    def introspect(self, path):
        parts = ['<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object '
                 'Introspection 1.0//EN" "http://www.freedesktop.org/standards/'
                 'dbus/1.0/introspect.dtd">', "<node>"]
        for interface, table in self.objects.get(path, {}).items():
            parts.append('<interface name="%s">' % interface)
            for name, (in_sig, out_sig, _f) in table.items():
                parts.append('<method name="%s">' % name)
                for s in sig_split(in_sig):
                    parts.append('<arg type="%s" direction="in"/>' % s)
                for s in sig_split(out_sig):
                    parts.append('<arg type="%s" direction="out"/>' % s)
                parts.append("</method>")
            parts.append("</interface>")
        parts.append("</node>")
        return "".join(parts)

    def reply(self, msg, signature, body):
        self.send(Message(METHOD_RETURN, destination=msg.sender,
                          reply_serial=msg.serial, signature=signature,
                          body=body))

    def error(self, msg, name, text):
        self.send(Message(ERROR, destination=msg.sender,
                          reply_serial=msg.serial, error_name=name,
                          signature="s", body=(text,)))

    def set_property(self, destination, path, interface, name, sig, value):
        self.call(destination, path, "org.freedesktop.DBus.Properties", "Set",
                  "ssv", (interface, name, (sig, value)))
PYEOF
	chmod 0644 "${STATE_DIR}/dbuslite.py"
}

write_agent_holder() {
	cat >"${STATE_DIR}/agent-holder.py" <<'PYEOF'
#!/usr/bin/python3
# Owns the adapter and answers pair requests. No package outside the Python
# standard library is necessary.
import os
import sys

import dbuslite

ADAPTER = "/org/bluez/" + os.environ.get("BT_ADAPTER", "hci0")
AUTO_PAIR = os.environ.get("BT_AUTO_PAIR", "yes") == "yes"
AGENT_PATH = "/btssh/agent"
AGENT_CAP = "NoInputNoOutput"


def log(message):
    sys.stdout.write(message + "\n")
    sys.stdout.flush()


def alias():
    try:
        with open("/etc/bt-ssh/alias", encoding="utf-8") as fh:
            value = fh.read().strip()
            if value:
                return value
    except OSError:
        pass
    return os.environ.get("BT_ALIAS", "Emergency SSH")


def main():
    bus = dbuslite.Bus()

    def trust(device):
        try:
            bus.set_property("org.bluez", device, "org.bluez.Device1",
                             "Trusted", "b", True)
        except dbuslite.DBusError:
            pass

    def apply_adapter():
        for name, sig, value in (("Powered", "b", True),
                                 ("Alias", "s", alias()),
                                 ("Pairable", "b", True),
                                 ("PairableTimeout", "u", 0),
                                 ("DiscoverableTimeout", "u", 0),
                                 ("Discoverable", "b", True)):
            try:
                bus.set_property("org.bluez", ADAPTER, "org.bluez.Adapter1",
                                 name, sig, value)
            except dbuslite.DBusError as exc:
                log("adapter %s: %s" % (name, exc))

    apply_adapter()
    log("adapter %s is ready as \"%s\"" % (ADAPTER, alias()))

    if AUTO_PAIR:
        def authorize_service(msg, device, uuid):
            trust(device)

        def request_authorization(msg, device):
            trust(device)

        def request_confirmation(msg, device, passkey):
            trust(device)

        bus.export(AGENT_PATH, "org.bluez.Agent1", {
            "Release": ("", "", lambda msg: None),
            "Cancel": ("", "", lambda msg: None),
            "AuthorizeService": ("os", "", authorize_service),
            "RequestPinCode": ("o", "s", lambda msg, d: "0000"),
            "RequestPasskey": ("o", "u", lambda msg, d: 0),
            "RequestConfirmation": ("ou", "", request_confirmation),
            "RequestAuthorization": ("o", "", request_authorization),
            "DisplayPasskey": ("ouq", "", lambda msg, d, p, e: None),
            "DisplayPinCode": ("os", "", lambda msg, d, p: None),
        })
        bus.call("org.bluez", "/org/bluez", "org.bluez.AgentManager1",
                 "RegisterAgent", "os", (AGENT_PATH, AGENT_CAP))
        try:
            bus.call("org.bluez", "/org/bluez", "org.bluez.AgentManager1",
                     "RequestDefaultAgent", "o", (AGENT_PATH,))
        except dbuslite.DBusError as exc:
            log("the default agent request did not succeed: %s" % exc)
        log("the pairing agent is registered")

    while True:
        bus.process(timeout=30.0)


if __name__ == "__main__":
    main()
PYEOF
	chmod 0755 "${STATE_DIR}/agent-holder.py"
}

write_nap_holder() {
	cat >"${STATE_DIR}/nap-holder.py" <<'PYEOF'
#!/usr/bin/python3
# Holds the NAP registration open. bluez cancels it when this process stops.
import os
import sys

import dbuslite

ADAPTER = "/org/bluez/" + os.environ.get("BT_ADAPTER", "hci0")
BRIDGE = os.environ.get("BT_BRIDGE", "nap0")


def main():
    bus = dbuslite.Bus()
    bus.call("org.bluez", ADAPTER, "org.bluez.NetworkServer1", "Register",
             "ss", ("nap", BRIDGE))
    sys.stdout.write("the NAP server is on %s\n" % BRIDGE)
    sys.stdout.flush()
    while True:
        bus.process(timeout=30.0)


if __name__ == "__main__":
    main()
PYEOF
	chmod 0755 "${STATE_DIR}/nap-holder.py"
}

write_spp_holder() {
	cat >"${STATE_DIR}/spp-holder.py" <<'PYEOF'
#!/usr/bin/python3
# Serial Port Profile server. bluez gives one socket for each connection.
# The socket stays in this process, as the bluez examples show. A copy of this
# process must not hold it, because bluez then sees a false disconnection.
# Only the login program runs in a child process.
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios

import dbuslite

PROFILE_PATH = "/btssh/spp"
SPP_UUID = "00001101-0000-1000-8000-00805f9b34fb"
SPP_NAME = os.environ.get("BT_SPP_NAME", "Serial")
SPP_CHANNEL = os.environ.get("BT_SPP_CHANNEL", "")
SHELL = os.environ.get("BT_SPP_SHELL", "/bin/login")
TERM = os.environ.get("BT_SPP_TERM", "vt100")
DEBUG = os.environ.get("BT_SPP_DEBUG", "no") == "yes"

sessions = {}


def log(message):
    sys.stdout.write(message + "\n")
    sys.stdout.flush()


def dlog(message):
    # Only the direction from the machine to the client is recorded, and only
    # a quantity of bytes. What the client sends stays out of the journal,
    # because it holds the password.
    if DEBUG:
        log("debug: " + message)


class Session:
    def __init__(self, path, sock):
        self.path = path
        self.sock = sock
        self.master = None
        self.pid = None
        self.closed = False
        # Output that the other end was not ready to take. RFCOMM uses credit
        # flow control, so a write immediately after the connection often
        # cannot go out yet. Keep the bytes and send them when the socket is
        # ready. If you discard them, the login prompt is lost.
        self.to_sock = bytearray()
        self.to_master = bytearray()

    def start(self):
        master, slave = pty.openpty()
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ,
                        struct.pack("HHHH", 24, 80, 0, 0))
        except OSError:
            pass
        pid = os.fork()
        if pid == 0:
            try:
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                os.dup2(slave, 0)
                os.dup2(slave, 1)
                os.dup2(slave, 2)
                if slave > 2:
                    os.close(slave)
                os.close(master)
                os.close(self.sock)
                signal.signal(signal.SIGCHLD, signal.SIG_DFL)
                os.environ["TERM"] = TERM
                os.execv(SHELL, [os.path.basename(SHELL)])
            except Exception:                          # noqa: BLE001
                pass
            os._exit(1)
        os.close(slave)
        self.master = master
        self.pid = pid
        # The socket and the terminal stay in blocking mode. An RFCOMM socket
        # does not report that it is ready to send in a dependable way, so a
        # non-blocking write keeps its data and the prompt never goes out.
        # The bluez examples use blocking mode for the same reason. Each read
        # comes after select() says that data is available, so it does not wait.
        log("session open for %s (pid %d)" % (self.path, pid))

    def read_fds(self):
        if self.closed:
            return []
        return [self.sock, self.master]

    def write_fds(self):
        if self.closed:
            return []
        out = []
        if self.to_sock:
            out.append(self.sock)
        if self.to_master:
            out.append(self.master)
        return out

    def on_readable(self, fd):
        if self.closed:
            return
        if fd == self.sock:
            queue = self.to_master
        else:
            queue = self.to_sock
        try:
            data = os.read(fd, 4096)
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                return
            self.close()
            return
        if not data:
            self.close()
            return
        if fd == self.master:
            dlog("pty gave %d bytes" % len(data))
        if len(queue) > 1 << 20:
            del queue[:len(queue) - (1 << 19)]
        queue.extend(data)
        self.flush(self.master if fd == self.sock else self.sock)

    def flush(self, fd):
        if self.closed:
            return
        queue = self.to_sock if fd == self.sock else self.to_master
        while queue:
            try:
                sent = os.write(fd, bytes(queue))
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    if fd == self.sock:
                        dlog("socket not ready, %d bytes wait" % len(queue))
                    return          # try again when select says it is ready
                if fd == self.sock:
                    dlog("socket write failed: %s" % exc)
                self.close()
                return
            if sent <= 0:
                return
            if fd == self.sock:
                dlog("socket took %d bytes, %d wait" % (sent, len(queue) - sent))
            del queue[:sent]

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.pid:
            try:
                os.kill(self.pid, signal.SIGHUP)
            except OSError:
                pass
        for fd in (self.master, self.sock):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        self.master = None
        self.sock = None
        sessions.pop(self.path, None)
        log("session closed for %s" % self.path)


def reap():
    while True:
        try:
            pid, _status = os.waitpid(-1, os.WNOHANG)
        except OSError:
            return
        if pid <= 0:
            return
        for session in list(sessions.values()):
            if session.pid == pid:
                session.pid = None
                session.close()


def main():
    if not os.path.exists(SHELL):
        log("error: the login program %s does not exist" % SHELL)
        sys.exit(1)

    bus = dbuslite.Bus()

    def new_connection(msg, path, fd, properties):
        key = str(path)
        log("connection from %s" % key)
        old = sessions.get(key)
        if old:
            old.close()
        session = Session(key, fd)
        sessions[key] = session
        session.start()

    def request_disconnection(msg, path):
        key = str(path)
        log("disconnect request for %s" % key)
        session = sessions.get(key)
        if session:
            session.close()

    bus.export(PROFILE_PATH, "org.bluez.Profile1", {
        "Release": ("", "", lambda msg: None),
        "Cancel": ("", "", lambda msg: None),
        "NewConnection": ("oha{sv}", "", new_connection),
        "RequestDisconnection": ("o", "", request_disconnection),
    })

    options = {
        "Name": ("s", SPP_NAME),
        "Role": ("s", "server"),
        "RequireAuthentication": ("b", True),
        "RequireAuthorization": ("b", False),
    }
    if SPP_CHANNEL:
        options["Channel"] = ("q", int(SPP_CHANNEL))

    bus.call("org.bluez", "/org/bluez", "org.bluez.ProfileManager1",
             "RegisterProfile", "osa{sv}", (PROFILE_PATH, SPP_UUID, options))
    log("SPP profile \"%s\" is registered" % SPP_NAME)

    while True:
        rset = [bus.fileno()]
        wset = []
        owner = {}
        for session in list(sessions.values()):
            for fd in session.read_fds():
                rset.append(fd)
                owner[fd] = session
            for fd in session.write_fds():
                wset.append(fd)
                owner[fd] = session
        try:
            readable, writable, _ = select.select(rset, wset, [], 30.0)
        except InterruptedError:
            continue
        except OSError:
            reap()
            continue
        reap()
        # Send what is waiting first, then take in new data.
        for fd in writable:
            session = owner.get(fd)
            if session and not session.closed:
                session.flush(fd)
        for fd in readable:
            if fd == bus.fileno():
                bus.process(timeout=0)
            else:
                session = owner.get(fd)
                if session and not session.closed:
                    session.on_readable(fd)


if __name__ == "__main__":
    main()
PYEOF
	chmod 0755 "${STATE_DIR}/spp-holder.py"
}

write_portal() {
	cat >"${STATE_DIR}/portal.py" <<'PORTALEOF'
#!/usr/bin/python3
import os
import http.server

HOST = os.environ.get("BT_HOST_IP", "10.137.0.1")
USER = os.environ.get("BT_SSH_USER", "root")
SSH_PORT = os.environ.get("BT_SSH_PORT", "22")
PORT = 80


def alias():
    try:
        with open("/etc/bt-ssh/alias", encoding="utf-8") as fh:
            value = fh.read().strip()
            if value:
                return value
    except OSError:
        pass
    return "this device"


PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{alias} - SSH over Bluetooth</title>
<style>
 body{{font-family:system-ui,sans-serif;max-width:40rem;margin:3rem auto;
      padding:0 1rem;line-height:1.6;background:#0f1115;color:#e6e6e6}}
 code,pre{{background:#1c2030;color:#9ad;padding:.15rem .4rem;border-radius:.3rem}}
 pre{{padding:1rem;overflow:auto}} h1{{font-size:1.4rem}} .muted{{color:#9aa}}
</style></head><body>
<h1>{alias}</h1>
<p>The Bluetooth network connection is correct. Use SSH to get a shell:</p>
<pre>{cmd}</pre>
<p>Give the account password. Then use <code>sudo</code> for root permission.</p>
<p class="muted">This page comes from {host}. The DHCP server on this device
gave you an address. SSH listens on port {sshport}.</p>
</body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        cmd = "ssh {}@{}".format(USER, HOST)
        if SSH_PORT != "22":
            cmd = "ssh -p {} {}@{}".format(SSH_PORT, USER, HOST)
        body = PAGE.format(alias=alias(), cmd=cmd, host=HOST,
                           sshport=SSH_PORT).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    http.server.HTTPServer((HOST, PORT), Handler).serve_forever()
PORTALEOF
	chmod 0755 "${STATE_DIR}/portal.py"
}

write_net_scripts() {
	cat >"${STATE_DIR}/net-up.sh" <<'NETUPEOF'
#!/usr/bin/env bash
set -euo pipefail
. /etc/bt-ssh/config

DUMMY="${BRIDGE}d0"

ip link show "$BRIDGE" >/dev/null 2>&1 || ip link add name "$BRIDGE" type bridge
ip link set "$BRIDGE" type bridge stp_state 0 || true
ip link show "$DUMMY" >/dev/null 2>&1 || ip link add name "$DUMMY" type dummy
ip link set "$DUMMY" master "$BRIDGE"
ip link set "$DUMMY" up
ip addr replace "${HOST_IP}/${PREFIX}" dev "$BRIDGE"
ip link set "$BRIDGE" up

sysctl -qw net.ipv4.ip_forward=1

if command -v nft >/dev/null 2>&1; then
	nft delete table inet bt_ssh >/dev/null 2>&1 || true
	nft delete table ip bt_ssh_nat >/dev/null 2>&1 || true
	nft -f - <<NFT
table inet bt_ssh {
	chain input {
		type filter hook input priority -10; policy accept;
		iifname "${BRIDGE}" accept
	}
	chain forward {
		type filter hook forward priority -10; policy accept;
		iifname "${BRIDGE}" accept
		oifname "${BRIDGE}" ct state established,related accept
	}
}
table ip bt_ssh_nat {
	chain postrouting {
		type nat hook postrouting priority 100; policy accept;
		ip saddr ${SUBNET} oifname != "${BRIDGE}" masquerade
	}
}
NFT
elif command -v iptables >/dev/null 2>&1; then
	iptables -t nat -C POSTROUTING -s "$SUBNET" ! -o "$BRIDGE" -j MASQUERADE 2>/dev/null ||
		iptables -t nat -A POSTROUTING -s "$SUBNET" ! -o "$BRIDGE" -j MASQUERADE
	iptables -C FORWARD -i "$BRIDGE" -j ACCEPT 2>/dev/null ||
		iptables -I FORWARD 1 -i "$BRIDGE" -j ACCEPT
	iptables -C FORWARD -o "$BRIDGE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null ||
		iptables -I FORWARD 1 -o "$BRIDGE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	iptables -C INPUT -i "$BRIDGE" -j ACCEPT 2>/dev/null ||
		iptables -I INPUT 1 -i "$BRIDGE" -j ACCEPT
fi
NETUPEOF
	chmod 0755 "${STATE_DIR}/net-up.sh"

	cat >"${STATE_DIR}/net-down.sh" <<'NETDOWNEOF'
#!/usr/bin/env bash
set -uo pipefail
. /etc/bt-ssh/config

DUMMY="${BRIDGE}d0"

if command -v nft >/dev/null 2>&1; then
	nft delete table inet bt_ssh >/dev/null 2>&1
	nft delete table ip bt_ssh_nat >/dev/null 2>&1
fi
if command -v iptables >/dev/null 2>&1; then
	iptables -t nat -D POSTROUTING -s "$SUBNET" ! -o "$BRIDGE" -j MASQUERADE 2>/dev/null
	iptables -D FORWARD -i "$BRIDGE" -j ACCEPT 2>/dev/null
	iptables -D FORWARD -o "$BRIDGE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
	iptables -D INPUT -i "$BRIDGE" -j ACCEPT 2>/dev/null
fi

ip link del "$DUMMY" 2>/dev/null
ip link del "$BRIDGE" 2>/dev/null
exit 0
NETDOWNEOF
	chmod 0755 "${STATE_DIR}/net-down.sh"
}

write_dnsmasq_conf() {
	cat >"${STATE_DIR}/dnsmasq.conf" <<EOF
interface=${BRIDGE}
listen-address=${HOST_IP}
bind-interfaces
dhcp-authoritative
dhcp-range=${DHCP_START},${DHCP_END},12h
dhcp-option=option:router,${HOST_IP}
dhcp-option=option:dns-server,${HOST_IP}
pid-file=/run/bt-ssh-dnsmasq.pid
EOF
	chmod 0644 "${STATE_DIR}/dnsmasq.conf"
}

write_units() {
	local py dnsq nmcli_path deps pre=""
	py="$(python_bin)"
	[[ -n "$py" ]] || die "python3 is missing. The unit files need the path to it."

	cat >"${UNIT_DIR}/${SVC_AGENT}" <<EOF
[Unit]
Description=SSH over Bluetooth: adapter and pairing agent
Documentation=https://www.bluez.org/
After=bluetooth.service
Requires=bluetooth.service
PartOf=bluetooth.service

[Service]
Type=simple
Environment="BT_ADAPTER=${ADAPTER}"
Environment="BT_AUTO_PAIR=${AUTO_PAIR}"
ExecStart=${py} ${STATE_DIR}/agent-holder.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

	if [[ "$SPP" == "yes" ]]; then
		cat >"${UNIT_DIR}/${SVC_SPP}" <<EOF
[Unit]
Description=SSH over Bluetooth: serial console (SPP)
Documentation=https://www.bluez.org/
After=${SVC_AGENT}
Requires=${SVC_AGENT}
PartOf=bluetooth.service

[Service]
Type=simple
Environment="BT_SPP_NAME=${SPP_NAME}"
Environment="BT_SPP_CHANNEL=${SPP_CHANNEL}"
Environment="BT_SPP_SHELL=${SPP_SHELL}"
Environment="BT_SPP_DEBUG=${SPP_DEBUG}"
ExecStart=${py} ${STATE_DIR}/spp-holder.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
	fi

	if [[ "$PAN" != "yes" ]]; then
		return 0
	fi

	if [[ "$BACKEND" == "manual" ]]; then
		dnsq="$(dnsmasq_bin)"
		[[ -n "$dnsq" ]] ||
			die "dnsmasq is missing. Run: $(pkg_hint "$(pkg_name dnsmasq)")"
		deps="After=${SVC_AGENT} ${SVC_NET}"$'\n'"Requires=${SVC_AGENT} ${SVC_NET}"
	else
		nmcli_path="$(command -v nmcli || true)"
		[[ -n "$nmcli_path" ]] || die "nmcli is missing. Use --backend manual."
		deps="After=${SVC_AGENT} NetworkManager.service"$'\n'"Requires=${SVC_AGENT}"
		pre="ExecStartPre=-${nmcli_path} -w 20 connection up ${BRIDGE}"
	fi

	{
		cat <<EOF
[Unit]
Description=SSH over Bluetooth: NAP broadcast
Documentation=https://www.bluez.org/
${deps}
PartOf=bluetooth.service

[Service]
Type=simple
Environment="BT_ADAPTER=${ADAPTER}"
Environment="BT_BRIDGE=${BRIDGE}"
EOF
		if [[ -n "$pre" ]]; then printf '%s\n' "$pre"; fi
		cat <<EOF
ExecStart=${py} ${STATE_DIR}/nap-holder.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
	} >"${UNIT_DIR}/${SVC_NAP}"

	if [[ "$PORTAL" == "yes" ]]; then
		cat >"${UNIT_DIR}/${SVC_PORTAL}" <<EOF
[Unit]
Description=SSH over Bluetooth: landing page on the PAN gateway
After=${SVC_NAP}
Requires=${SVC_NAP}

[Service]
Type=simple
Environment="BT_HOST_IP=${HOST_IP}"
Environment="BT_SSH_USER=${SSH_USER}"
Environment="BT_SSH_PORT=${SSH_PORT}"
ExecStart=${py} ${STATE_DIR}/portal.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
	fi

	if [[ "$BACKEND" == "manual" ]]; then
		cat >"${UNIT_DIR}/${SVC_NET}" <<EOF
[Unit]
Description=SSH over Bluetooth: isolated bridge and NAT
Wants=network-pre.target
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${STATE_DIR}/net-up.sh
ExecStop=${STATE_DIR}/net-down.sh

[Install]
WantedBy=multi-user.target
EOF

		cat >"${UNIT_DIR}/${SVC_DHCP}" <<EOF
[Unit]
Description=SSH over Bluetooth: DHCP and DNS for the PAN
After=${SVC_NET}
Requires=${SVC_NET}

[Service]
Type=simple
ExecStart=${dnsq} -k --conf-file=${STATE_DIR}/dnsmasq.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
	fi
}

write_avahi() {
	[[ "$MDNS" == "yes" ]] || return 0
	[[ -d "$AVAHI_DIR" ]] || return 0
	cat >"$AVAHI_FILE" <<EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">${BT_ALIAS} (SSH over Bluetooth) on %h</name>
  <service>
    <type>_ssh._tcp</type>
    <port>${SSH_PORT}</port>
  </service>
</service-group>
EOF
	chmod 0644 "$AVAHI_FILE"
	systemctl reload avahi-daemon 2>/dev/null ||
		systemctl restart avahi-daemon 2>/dev/null || true
}

# --------------------------------------------------------------- backends ----

nm_up() {
	local zone_args=()
	if [[ -n "${ZONE:-}" ]]; then zone_args=(connection.zone "$ZONE"); fi
	nmcli connection delete "${BRIDGE}-port" >/dev/null 2>&1 || true
	nmcli connection delete "${BRIDGE}" >/dev/null 2>&1 || true
	nmcli connection add type bridge ifname "${BRIDGE}" con-name "${BRIDGE}" \
		ipv4.method shared ipv4.addresses "${HOST_IP}/${PREFIX}" \
		ipv6.method ignore bridge.stp no connection.autoconnect yes \
		${zone_args[@]+"${zone_args[@]}"} >/dev/null
	nmcli connection add type dummy ifname "${BRIDGE}d0" \
		con-name "${BRIDGE}-port" master "${BRIDGE}" \
		connection.autoconnect yes >/dev/null
	nmcli connection up "${BRIDGE}" >/dev/null
	nmcli connection up "${BRIDGE}-port" >/dev/null 2>&1 || true
}

nm_down() {
	nmcli connection down "${BRIDGE}-port" >/dev/null 2>&1 || true
	nmcli connection delete "${BRIDGE}-port" >/dev/null 2>&1 || true
	nmcli connection down "${BRIDGE}" >/dev/null 2>&1 || true
	nmcli connection delete "${BRIDGE}" >/dev/null 2>&1 || true
}

# --------------------------------------------------------------- firewall ----

fw_open() {
	case "$FIREWALL" in
	firewalld)
		if [[ "$BACKEND" == "nm" ]]; then
			ok "firewalld uses the connection zone \"${ZONE}\"."
		else
			firewall-cmd --permanent --zone="${ZONE}" \
				--change-interface="${BRIDGE}" >/dev/null 2>&1 || true
			firewall-cmd --reload >/dev/null 2>&1 || true
			ok "firewalld put ${BRIDGE} in the zone \"${ZONE}\"."
		fi
		;;
	ufw)
		ufw allow in on "${BRIDGE}" >/dev/null 2>&1 || true
		ufw route allow in on "${BRIDGE}" >/dev/null 2>&1 || true
		ok "ufw permits traffic on ${BRIDGE}."
		;;
	nftables | iptables)
		if [[ "$BACKEND" == "manual" ]]; then
			ok "${FIREWALL} rules come from ${SVC_NET}."
		else
			warn "No managed firewall found. Make sure port ${SSH_PORT} accepts traffic on ${BRIDGE}."
		fi
		;;
	*)
		info "No firewall manager found. No firewall change is necessary."
		;;
	esac
}

fw_close() {
	case "$FIREWALL" in
	firewalld)
		firewall-cmd --permanent --zone="${ZONE}" \
			--remove-interface="${BRIDGE}" >/dev/null 2>&1 || true
		firewall-cmd --reload >/dev/null 2>&1 || true
		;;
	ufw)
		ufw delete allow in on "${BRIDGE}" >/dev/null 2>&1 || true
		ufw route delete allow in on "${BRIDGE}" >/dev/null 2>&1 || true
		;;
	esac
}

# ------------------------------------------------------------ dependencies ----

check_deps() {
	local missing=()

	have systemctl || die "systemd is necessary. This tool does not support other init systems."
	[[ -n "$(python_bin)" ]] || missing+=("python3")
	have bluetoothctl || missing+=("$(pkg_name bluez)")

	if [[ ${#missing[@]} -gt 0 ]]; then
		bad "These programs are missing: ${missing[*]}"
		info "$(pkg_hint "${missing[*]}")"
		die "Install the missing packages. Then run the command again."
	fi

	local py; py="$(python_bin)"
	"$py" -c 'import socket, struct, array, pty, termios, fcntl, select' 2>/dev/null ||
		die "The Python standard library is incomplete. Install the full python3 package."

	if [[ "$BACKEND" == "manual" ]]; then
		[[ -n "$(dnsmasq_bin)" ]] ||
			die "dnsmasq is necessary for the manual backend. Run: $(pkg_hint "$(pkg_name dnsmasq)")"
		have ip || die "iproute2 is necessary. Install the iproute2 package."
		have nft || have iptables ||
			die "nftables or iptables is necessary for NAT. Install one of them."
	else
		[[ -n "$(dnsmasq_bin)" ]] ||
			warn "dnsmasq is missing. NetworkManager shared mode needs it for DHCP."
	fi

	systemctl is-active --quiet bluetooth.service 2>/dev/null ||
		warn "bluetooth.service is not active. The install starts it."
	systemctl is-enabled --quiet sshd.service 2>/dev/null ||
		systemctl is-enabled --quiet ssh.service 2>/dev/null ||
		warn "The SSH server is not enabled. Enable it with: systemctl enable --now sshd"
}

# ------------------------------------------------------------- subcommands ----

cmd_install() {
	local o_user="" o_alias="" o_adapter="" o_bridge="" o_subnet="" o_backend=""
	local o_zone="" o_port="" o_portal="yes" o_mdns="yes" o_pair="yes" o_start="yes"
	local o_pan="yes" o_spp="yes" o_spp_name="" o_spp_chan="" o_spp_shell=""
	local o_spp_debug="no"
	OPT_YES="no"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-u | --user) o_user="${2:?--user needs a value}"; shift 2 ;;
		-a | --alias) o_alias="${2:?--alias needs a value}"; shift 2 ;;
		-i | --adapter) o_adapter="${2:?--adapter needs a value}"; shift 2 ;;
		-b | --bridge) o_bridge="${2:?--bridge needs a value}"; shift 2 ;;
		-n | --subnet) o_subnet="${2:?--subnet needs a value}"; shift 2 ;;
		-p | --ssh-port) o_port="${2:?--ssh-port needs a value}"; shift 2 ;;
		--backend) o_backend="${2:?--backend needs a value}"; shift 2 ;;
		--zone) o_zone="${2:?--zone needs a value}"; shift 2 ;;
		--spp-name) o_spp_name="${2:?--spp-name needs a value}"; shift 2 ;;
		--spp-channel) o_spp_chan="${2:?--spp-channel needs a value}"; shift 2 ;;
		--spp-shell) o_spp_shell="${2:?--spp-shell needs a value}"; shift 2 ;;
		--spp-debug) o_spp_debug="yes"; shift ;;
		--no-pan) o_pan="no"; shift ;;
		--no-spp) o_spp="no"; shift ;;
		--no-portal) o_portal="no"; shift ;;
		--no-mdns) o_mdns="no"; shift ;;
		--no-auto-pair) o_pair="no"; shift ;;
		--no-autostart) o_start="no"; shift ;;
		-y | --yes) OPT_YES="yes"; shift ;;
		-h | --help) help_install; return 0 ;;
		*) die "Unknown option for install: $1" ;;
		esac
	done

	[[ "$o_pan" == "yes" || "$o_spp" == "yes" ]] ||
		die "--no-pan and --no-spp together leave no way in. Keep one of them."

	BT_ALIAS="${o_alias:-$(detect_hostname)}"
	SSH_USER="${o_user:-$(detect_user)}"
	ADAPTER="${o_adapter:-$(detect_adapter)}"
	BRIDGE="${o_bridge:-$DEF_BRIDGE}"
	SSH_PORT="${o_port:-$DEF_SSH_PORT}"
	ZONE="${o_zone:-$DEF_ZONE}"
	PAN="$o_pan"
	SPP="$o_spp"
	MDNS="$o_mdns"
	AUTO_PAIR="$o_pair"
	PORTAL="$o_portal"
	[[ "$PAN" == "yes" ]] || PORTAL="no"

	SPP_NAME="${o_spp_name:-$DEF_SPP_NAME}"
	SPP_CHANNEL="$o_spp_chan"
	SPP_SHELL="${o_spp_shell:-$(login_bin)}"
	SPP_DEBUG="$o_spp_debug"
	if [[ -n "$SPP_CHANNEL" ]]; then
		[[ "$SPP_CHANNEL" =~ ^[0-9]+$ ]] && ((SPP_CHANNEL >= 1 && SPP_CHANNEL <= 30)) ||
			die "The SPP channel must be a number between 1 and 30."
	fi
	if [[ "$SPP" == "yes" ]]; then
		[[ -n "$SPP_SHELL" ]] ||
			die "No login program was found. Give one with --spp-shell."
		[[ "$SPP_NAME" == *[![:space:]]* ]] ||
			die "The SPP name must not be empty."
	fi

	local cidr="${o_subnet:-$DEF_SUBNET}"
	local base="${cidr%%/*}"
	PREFIX="${cidr##*/}"
	valid_ip "$base" || die "The subnet address is not valid: ${base}"
	[[ "$PREFIX" =~ ^[0-9]+$ ]] && ((PREFIX >= 8 && PREFIX <= 30)) ||
		die "The prefix must be a number between 8 and 30."

	local base_int mask size net_int
	base_int="$(ip2int "$base")"
	size=$((1 << (32 - PREFIX)))
	mask=$((0xFFFFFFFF ^ (size - 1)))
	net_int=$((base_int & mask))
	HOST_IP="$(int2ip $((net_int + 1)))"
	SUBNET="$(int2ip "$net_int")/${PREFIX}"
	DHCP_START="$(int2ip $((net_int + 10)))"
	local last=$((net_int + size - 2))
	if ((last > net_int + 200)); then last=$((net_int + 200)); fi
	DHCP_END="$(int2ip "$last")"

	if [[ -n "$o_backend" && "$o_backend" != "auto" ]]; then
		[[ "$o_backend" == "nm" || "$o_backend" == "manual" ]] ||
			die "The backend must be auto, nm, or manual."
		BACKEND="$o_backend"
	else
		BACKEND="$(detect_backend)"
	fi
	FIREWALL="$(detect_firewall)"

	if [[ "$PAN" == "yes" && "$BACKEND" == "nm" ]] && ! nm_running; then
		die "The nm backend needs NetworkManager. Start it, or use --backend manual."
	fi

	require_root

	step "Plan"
	printf '  %-14s %s\n' "Bluetooth name" "$BT_ALIAS"
	printf '  %-14s %s\n' "Adapter" "$ADAPTER"
	printf '  %-14s %s\n' "Auto pairing" "$AUTO_PAIR"
	printf '  %-14s %s\n' "mDNS advert" "$MDNS"
	say ""
	printf '  %-14s %s\n' "PAN (network)" "$PAN"
	if [[ "$PAN" == "yes" ]]; then
		printf '  %-14s %s\n' "  SSH login" "${SSH_USER}@${HOST_IP} (port ${SSH_PORT})"
		printf '  %-14s %s\n' "  Bridge" "$BRIDGE"
		printf '  %-14s %s\n' "  Subnet" "$SUBNET"
		printf '  %-14s %s\n' "  DHCP pool" "${DHCP_START} - ${DHCP_END}"
		printf '  %-14s %s\n' "  Backend" "$BACKEND"
		printf '  %-14s %s\n' "  Firewall" "$FIREWALL"
		printf '  %-14s %s\n' "  Landing page" "$PORTAL"
	fi
	say ""
	printf '  %-14s %s\n' "SPP (serial)" "$SPP"
	if [[ "$SPP" == "yes" ]]; then
		printf '  %-14s %s\n' "  Service name" "$SPP_NAME"
		printf '  %-14s %s\n' "  RFCOMM chan" "${SPP_CHANNEL:-auto}"
		printf '  %-14s %s\n' "  Login program" "$SPP_SHELL"
		printf '  %-14s %s\n' "  Debug log" "$SPP_DEBUG"
	fi
	say ""

	if [[ "$PAN" == "yes" ]]; then
		id -u "$SSH_USER" >/dev/null 2>&1 ||
			warn "The account \"${SSH_USER}\" does not exist on this machine."
	fi

	confirm "Continue with the install?" || die "The install stopped."

	step "[1/6] Check the dependencies"
	check_deps
	ok "All necessary programs are available."

	step "[2/6] Write the files to ${STATE_DIR}"
	install -d -m 0755 "$STATE_DIR"
	save_state
	write_dbuslite
	write_agent_holder
	if [[ "$SPP" == "yes" ]]; then write_spp_holder; fi
	if [[ "$PAN" == "yes" ]]; then
		write_nap_holder
		if [[ "$PORTAL" == "yes" ]]; then write_portal; fi
		if [[ "$BACKEND" == "manual" ]]; then
			write_net_scripts
			write_dnsmasq_conf
		fi
	fi
	ok "The files are in place."

	step "[3/6] Create the isolated network"
	if [[ "$PAN" != "yes" ]]; then
		info "PAN is off. No network change is necessary."
	elif [[ "$BACKEND" == "nm" ]]; then
		nm_up
		ok "NetworkManager manages the bridge ${BRIDGE} (${HOST_IP}/${PREFIX})."
	else
		"${STATE_DIR}/net-up.sh"
		ok "The bridge ${BRIDGE} is up (${HOST_IP}/${PREFIX}). NAT is active."
	fi

	step "[4/6] Write the systemd units"
	write_units
	write_avahi
	systemctl daemon-reload
	ok "The units are in ${UNIT_DIR}."

	step "[5/6] Set the firewall"
	if [[ "$PAN" == "yes" ]]; then
		fw_open
	else
		info "PAN is off. No firewall change is necessary."
	fi

	step "[6/6] Start the services"
	systemctl enable --now bluetooth.service >/dev/null 2>&1 || true
	local enable_flag="enable"
	if [[ "$o_start" == "no" ]]; then enable_flag="disable"; fi
	local svc
	while read -r svc; do
		systemctl "$enable_flag" "$svc" >/dev/null 2>&1 || true
	done < <(services_of)
	# "enable --now" does not restart a service that already runs, so an
	# install over an earlier one would keep the old code. Restart each one.
	while read -r svc; do
		systemctl restart "$svc" >/dev/null 2>&1 || true
	done < <(services_of)
	sleep 1
	local failed=0
	while read -r svc; do
		if systemctl is-active --quiet "$svc"; then
			ok "${svc} runs."
		else
			bad "${svc} did not start."
			failed=$((failed + 1))
		fi
	done < <(services_of)
	if ((failed > 0)); then
		info "Run \"${PROG} logs\" to see why."
	fi

	say ""
	print_connect_help
}

cmd_uninstall() {
	OPT_YES="no"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-y | --yes) OPT_YES="yes"; shift ;;
		-h | --help) help_uninstall; return 0 ;;
		*) die "Unknown option for uninstall: $1" ;;
		esac
	done

	require_root
	load_state
	installed || warn "No install record exists. The removal continues."

	confirm "Remove all changes of ${PROG}?" || die "The removal stopped."

	step "[1/4] Stop and disable the services"
	local svc
	for svc in "$SVC_PORTAL" "$SVC_SPP" "$SVC_NAP" "$SVC_DHCP" "$SVC_NET" "$SVC_AGENT"; do
		systemctl disable --now "$svc" >/dev/null 2>&1 || true
	done
	ok "The services are stopped."

	step "[2/4] Remove the isolated network"
	if [[ "${BACKEND:-nm}" == "manual" ]]; then
		if [[ -x "${STATE_DIR}/net-down.sh" ]]; then
			"${STATE_DIR}/net-down.sh" || true
		fi
	else
		nm_down
	fi
	ip link del "${BRIDGE}d0" >/dev/null 2>&1 || true
	ip link del "${BRIDGE}" >/dev/null 2>&1 || true
	ok "The bridge ${BRIDGE} is gone."

	step "[3/4] Undo the firewall change"
	FIREWALL="${FIREWALL:-$(detect_firewall)}"
	ZONE="${ZONE:-$DEF_ZONE}"
	fw_close
	ok "The firewall is at its earlier state."

	step "[4/4] Remove the files"
	rm -f "${UNIT_DIR}/${SVC_AGENT}" "${UNIT_DIR}/${SVC_NAP}" \
		"${UNIT_DIR}/${SVC_SPP}" "${UNIT_DIR}/${SVC_PORTAL}" \
		"${UNIT_DIR}/${SVC_NET}" "${UNIT_DIR}/${SVC_DHCP}"
	rm -f "$AVAHI_FILE"
	rm -rf "$STATE_DIR"
	systemctl daemon-reload
	systemctl reload avahi-daemon >/dev/null 2>&1 || true
	ok "The files are gone."

	if have bluetoothctl; then
		bluetoothctl <<'EOF' >/dev/null 2>&1 || true
discoverable off
pairable off
EOF
	fi

	say ""
	say "The removal is complete. The Wi-Fi and LAN settings did not change."
	say "The paired clients stay in the Bluetooth database. To remove one:"
	say "  ${PROG} clients"
	say "  ${PROG} forget <MAC>"
}

services_of() {
	load_state
	local list=()
	if [[ -f "${UNIT_DIR}/${SVC_AGENT}" ]]; then list+=("$SVC_AGENT"); fi
	if [[ "$PAN" == "yes" && -f "${UNIT_DIR}/${SVC_NAP}" ]]; then
		if [[ "$BACKEND" == "manual" ]]; then
			list+=("$SVC_NET" "$SVC_DHCP")
		fi
		list+=("$SVC_NAP")
		if [[ "$PORTAL" == "yes" && -f "${UNIT_DIR}/${SVC_PORTAL}" ]]; then
			list+=("$SVC_PORTAL")
		fi
	fi
	if [[ "$SPP" == "yes" && -f "${UNIT_DIR}/${SVC_SPP}" ]]; then
		list+=("$SVC_SPP")
	fi
	if [[ ${#list[@]} -eq 0 ]]; then list=("$SVC_AGENT"); fi
	printf '%s\n' "${list[@]}"
}

cmd_start() {
	require_root
	require_installed
	local svc
	while read -r svc; do
		step "Start ${svc}"
		systemctl start "$svc" && ok "${svc} runs." || bad "${svc} did not start."
	done < <(services_of)
}

cmd_stop() {
	require_root
	require_installed
	local svcs=() svc
	while read -r svc; do svcs+=("$svc"); done < <(services_of)
	local i
	for ((i = ${#svcs[@]} - 1; i >= 0; i--)); do
		step "Stop ${svcs[i]}"
		systemctl stop "${svcs[i]}" >/dev/null 2>&1 || true
		ok "${svcs[i]} is stopped."
	done
}

cmd_restart() {
	require_root
	require_installed
	cmd_stop
	cmd_start
}

cmd_enable() {
	require_root
	require_installed
	local svc
	while read -r svc; do
		if systemctl enable "$svc" >/dev/null 2>&1; then
			ok "${svc} starts at boot."
		else
			bad "${svc} was not enabled."
		fi
	done < <(services_of)
}

cmd_disable() {
	require_root
	require_installed
	local svc
	while read -r svc; do
		if systemctl disable "$svc" >/dev/null 2>&1; then
			ok "${svc} does not start at boot."
		else
			bad "${svc} was not disabled."
		fi
	done < <(services_of)
}

cmd_status() {
	load_state
	if ! installed; then
		bad "The system is not installed."
		info "Run \"${PROG} install\" to install it."
		return 1
	fi

	step "Configuration"
	printf '  %-14s %s\n' "Bluetooth name" "${BT_ALIAS:-?}"
	printf '  %-14s %s\n' "Adapter" "${ADAPTER:-?}"
	printf '  %-14s %s\n' "PAN (network)" "${PAN}"
	if [[ "$PAN" == "yes" ]]; then
		printf '  %-14s %s\n' "  SSH login" "${SSH_USER:-?}@${HOST_IP:-?} (port ${SSH_PORT})"
		printf '  %-14s %s\n' "  Bridge" "${BRIDGE}"
		printf '  %-14s %s\n' "  Subnet" "${SUBNET:-?}"
		printf '  %-14s %s\n' "  Backend" "${BACKEND:-?}"
	fi
	printf '  %-14s %s\n' "SPP (serial)" "${SPP}"
	if [[ "$SPP" == "yes" ]]; then
		printf '  %-14s %s\n' "  Service name" "${SPP_NAME}"
		printf '  %-14s %s\n' "  Login program" "${SPP_SHELL:-?}"
	fi

	step "Services"
	local svc state
	while read -r svc; do
		state="$(systemctl is-active "$svc" 2>/dev/null || true)"
		if [[ "$state" == "active" ]]; then ok "${svc} is active."
		else bad "${svc} is ${state:-unknown}."; fi
	done < <(services_of)

	if [[ "$PAN" == "yes" ]]; then
		step "Network"
		if ip -o -4 addr show "$BRIDGE" 2>/dev/null | grep -q "$HOST_IP"; then
			ok "${BRIDGE} has the address ${HOST_IP}/${PREFIX}."
		else
			bad "${BRIDGE} does not have the address ${HOST_IP}."
		fi
		info "Default route: $(ip route show default 2>/dev/null | head -1 || echo none)"
	fi

	step "Bluetooth"
	if have bluetoothctl; then
		local show; show="$(bluetoothctl show 2>/dev/null || true)"
		if grep -qi 'Powered: yes' <<<"$show"; then
			ok "The adapter has power."
		else
			bad "The adapter has no power."
		fi
		if grep -qi 'Discoverable: yes' <<<"$show"; then
			ok "The adapter is discoverable."
		else
			bad "The adapter is not discoverable."
		fi
		info "Alias: $(grep -i 'Alias:' <<<"$show" | head -1 | sed 's/.*Alias: //' || true)"
	fi
	step "Advertised profiles"
	local uuids=""
	if have bluetoothctl; then uuids="$(bluetoothctl show 2>/dev/null || true)"; fi
	if [[ "$PAN" == "yes" ]]; then
		if grep -qiE '^\s*UUID: NAP' <<<"$uuids"; then
			ok "NAP is advertised. Clients can join the network."
		else
			bad "NAP is not advertised. Run \"${PROG} logs nap\"."
		fi
	fi
	if [[ "$SPP" == "yes" ]]; then
		if grep -qiE '^\s*UUID: Serial Port' <<<"$uuids"; then
			ok "SPP is advertised as \"${SPP_NAME}\"."
			info "macOS device node: /dev/cu.<name>-${SPP_NAME}"
		else
			bad "SPP is not advertised. Run \"${PROG} logs spp\"."
		fi
	fi

	if [[ "${PORTAL:-no}" == "yes" ]] && have curl; then
		step "Landing page"
		local code
		code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://${HOST_IP}/" 2>/dev/null || true)"
		if [[ "$code" == "200" ]]; then
			ok "http://${HOST_IP} answers."
		else
			bad "http://${HOST_IP} does not answer (code ${code:-none})."
		fi
	fi

	if [[ "$PAN" != "yes" ]]; then
		return 0
	fi

	step "Clients"
	local leases=""
	if [[ "${BACKEND:-nm}" == "manual" ]]; then
		leases="$(cat /var/lib/misc/dnsmasq.leases 2>/dev/null || true)"
	else
		leases="$(cat /var/lib/NetworkManager/dnsmasq-"${BRIDGE}".leases 2>/dev/null || true)"
	fi
	if [[ -n "$leases" ]]; then
		printf '%s\n' "$leases" | awk '{printf "  %-16s %s\n", $3, $4}'
	else
		info "No client has an address at this time."
	fi
}

cmd_logs() {
	local follow="" lines="60" svc=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-f | --follow) follow="-f"; shift ;;
		-n | --lines) lines="${2:?--lines needs a value}"; shift 2 ;;
		-h | --help) help_logs; return 0 ;;
		agent) svc="$SVC_AGENT"; shift ;;
		nap | pan) svc="$SVC_NAP"; shift ;;
		spp | serial) svc="$SVC_SPP"; shift ;;
		portal) svc="$SVC_PORTAL"; shift ;;
		net) svc="$SVC_NET"; shift ;;
		dhcp) svc="$SVC_DHCP"; shift ;;
		*) die "Unknown option for logs: $1" ;;
		esac
	done
	require_root
	require_installed
	local args=()
	if [[ -n "$svc" ]]; then
		args=(-u "$svc")
	else
		local s
		while read -r s; do args+=(-u "$s"); done < <(services_of)
	fi
	journalctl "${args[@]}" -n "$lines" --no-pager ${follow:+$follow}
}

cmd_clients() {
	have bluetoothctl || die "bluetoothctl is missing. Install the bluez package."
	step "Paired devices"
	local out
	out="$(bluetoothctl devices Paired 2>/dev/null || bluetoothctl paired-devices 2>/dev/null || true)"
	if [[ -n "$out" ]]; then printf '%s\n' "$out" | sed 's/^/  /'; else info "No device is paired."; fi
	step "Connected devices"
	out="$(bluetoothctl devices Connected 2>/dev/null || true)"
	if [[ -n "$out" ]]; then printf '%s\n' "$out" | sed 's/^/  /'; else info "No device is connected."; fi
}

cmd_connect() {
	[[ $# -ge 1 ]] || die "Give the MAC address. Run \"${PROG} clients\" to see them."
	require_root
	have bluetoothctl || die "bluetoothctl is missing. Install the bluez package."
	local mac out
	for mac in "$@"; do
		step "Connect to ${mac}"
		out="$(bluetoothctl connect "$mac" 2>&1 || true)"
		if grep -qi "Connection successful" <<<"$out"; then
			ok "The device ${mac} is connected."
		else
			bad "The connection to ${mac} did not succeed."
			printf '%s\n' "$out" | sed 's/^/    /'
		fi
	done
}

cmd_disconnect() {
	require_root
	have bluetoothctl || die "bluetoothctl is missing. Install the bluez package."
	local macs=("$@") mac out
	if [[ ${#macs[@]} -eq 0 ]]; then
		while read -r _ mac _; do
			if [[ -n "$mac" ]]; then macs+=("$mac"); fi
		done < <(bluetoothctl devices Connected 2>/dev/null || true)
		[[ ${#macs[@]} -gt 0 ]] || { info "No device is connected."; return 0; }
	fi
	for mac in "${macs[@]}"; do
		step "Disconnect ${mac}"
		out="$(bluetoothctl disconnect "$mac" 2>&1 || true)"
		if grep -qi "Successful disconnected" <<<"$out" ||
			grep -qi "Connected: no" <<<"$out"; then
			ok "The device ${mac} is disconnected."
		else
			bad "The disconnection of ${mac} did not succeed."
			printf '%s\n' "$out" | sed 's/^/    /'
		fi
	done
}

cmd_forget() {
	[[ $# -ge 1 ]] || die "Give the MAC address. Example: ${PROG} forget AA:BB:CC:DD:EE:FF"
	require_root
	have bluetoothctl || die "bluetoothctl is missing. Install the bluez package."
	local mac
	for mac in "$@"; do
		if bluetoothctl remove "$mac" >/dev/null 2>&1; then
			ok "The device ${mac} is removed."
		else
			bad "The device ${mac} was not removed."
		fi
	done
}

cmd_config() {
	load_state
	installed || die "The system is not installed."
	[[ -r "$STATE_FILE" ]] || die "The configuration file is missing: ${STATE_FILE}"
	step "Configuration file: ${STATE_FILE}"
	sed 's/^/  /' "$STATE_FILE"
	say ""
	info "To change a value, run the install command again with the new options."
}

PROBLEMS=0

fault() {
	bad "$1"
	PROBLEMS=$((PROBLEMS + 1))
}

cmd_doctor() {
	load_state
	PROBLEMS=0

	step "Host requirements"
	if have systemctl; then ok "systemd is available."
	else fault "systemd is missing. This tool does not support other init systems."; fi

	local py; py="$(python_bin)"
	if [[ -n "$py" ]]; then ok "python3 is available."
	else fault "python3 is missing."; fi

	if have bluetoothctl; then ok "bluez is available."
	else fault "bluez is missing. Run: $(pkg_hint "$(pkg_name bluez)")"; fi

	if [[ -n "$py" ]]; then
		if "$py" -c 'import socket, struct, array, select' 2>/dev/null; then
			ok "The Python standard library is complete."
		else
			fault "The Python standard library is incomplete."
		fi
	fi
	if [[ -S /run/dbus/system_bus_socket || -S /var/run/dbus/system_bus_socket ]]; then
		ok "The D-Bus system bus socket is present."
	else
		fault "The D-Bus system bus socket was not found. Start dbus-daemon."
	fi

	step "Bluetooth hardware"
	local adapters=() d
	for d in /sys/class/bluetooth/hci*; do
		if [[ -e "$d" ]]; then adapters+=("$(basename "$d")"); fi
	done
	if [[ ${#adapters[@]} -gt 0 ]]; then ok "Adapters: ${adapters[*]}"
	else fault "No Bluetooth adapter is present."; fi

	if systemctl is-active --quiet bluetooth.service 2>/dev/null; then
		ok "bluetooth.service is active."
	else
		fault "bluetooth.service is not active. Run: systemctl enable --now bluetooth"
	fi

	step "SSH server"
	if systemctl is-active --quiet sshd.service 2>/dev/null ||
		systemctl is-active --quiet ssh.service 2>/dev/null; then
		ok "The SSH server is active."
	else
		fault "The SSH server is not active. Run: systemctl enable --now sshd"
	fi

	step "Serial console (SPP)"
	local lb; lb="$(login_bin)"
	if [[ -n "$lb" ]]; then ok "The login program is ${lb}."
	else fault "No login program was found. Give one with --spp-shell."; fi
	if [[ -n "$py" ]]; then
		if "$py" -c 'import pty, select' 2>/dev/null; then
			ok "The Python terminal modules are available."
		else
			fault "The Python pty or select module is missing."
		fi
	fi

	step "Network backend"
	if nm_running; then
		ok "NetworkManager is active. The nm backend is available."
	else
		info "NetworkManager is not active. Use --backend manual."
	fi
	if [[ -n "$(dnsmasq_bin)" ]]; then ok "dnsmasq is available."
	else
		bad "dnsmasq is missing. PAN needs it. Run: $(pkg_hint "$(pkg_name dnsmasq)")"
		info "SPP does not need dnsmasq. Use --no-pan for a serial console only."
		PROBLEMS=$((PROBLEMS + 1))
	fi
	if have nft; then ok "nftables is available."
	elif have iptables; then ok "iptables is available."
	else info "No NAT tool is available."; fi
	info "Firewall manager: $(detect_firewall)"
	info "Backend for an install with --backend auto: $(detect_backend)"

	if installed; then
		step "Installed state"
		local svc state
		while read -r svc; do
			state="$(systemctl is-active "$svc" 2>/dev/null || true)"
			if [[ "$state" == "active" ]]; then ok "${svc} is active."
			else fault "${svc} is ${state:-unknown}. Run: ${PROG} logs"; fi
		done < <(services_of)
		if [[ -n "${HOST_IP:-}" ]]; then
			if ip -o -4 addr show "$BRIDGE" 2>/dev/null | grep -q "$HOST_IP"; then
				ok "${BRIDGE} has the address ${HOST_IP}."
			else
				fault "${BRIDGE} does not have the address ${HOST_IP}. Run: ${PROG} restart"
			fi
		fi
	else
		info "The system is not installed."
	fi

	say ""
	if ((PROBLEMS == 0)); then
		ok "The check found no problem."
	else
		bad "The check found ${PROBLEMS} problem(s)."
		return 1
	fi
}

print_connect_help() {
	say "${C_B}The machine broadcasts the Bluetooth name \"${BT_ALIAS}\".${C_0}"
	say ""
	say "On the client, pair with \"${BT_ALIAS}\" first."
	if [[ "$AUTO_PAIR" == "yes" ]]; then
		say "This machine accepts the pair request without a prompt."
	else
		say "Approve the pair request on this machine with bluetoothctl."
	fi
	say ""

	if [[ "$PAN" == "yes" ]]; then
		say "${C_B}PATH 1 - SSH over the Bluetooth network (Linux, Windows, Android)${C_0}"
		say "  1. Join the Bluetooth network. This step is necessary."
		say "     Windows: Bluetooth settings > the device > Connect using > Access point"
		say "     Linux:   network menu > the device > Connect"
		say "              or: nmcli device connect <BT-MAC>"
		say "     Android: paired device settings > enable Internet access"
		if [[ "$SSH_PORT" == "22" ]]; then
			say "  2. Use SSH: ssh ${SSH_USER}@${HOST_IP}"
		else
			say "  2. Use SSH: ssh -p ${SSH_PORT} ${SSH_USER}@${HOST_IP}"
		fi
		say "     Give the account password. Then use sudo for root permission."
		if [[ "$PORTAL" == "yes" ]]; then
			say "  The client can also open http://${HOST_IP} for these instructions."
		fi
		say ""
	fi

	if [[ "$SPP" == "yes" ]]; then
		say "${C_B}PATH 2 - Serial console over Bluetooth (macOS and any serial terminal)${C_0}"
		say "  macOS:   ls /dev/cu.*                  <- find the exact name first"
		say "           screen /dev/cu.<name> ${DEF_SPP_BAUD}"
		say "           The name comes from \"${BT_ALIAS}\". macOS adds \"${SPP_NAME}\""
		say "           to it in some conditions, and does not in others."
		say "  Linux:   rfcomm connect /dev/rfcomm0 <BT-MAC>, then"
		say "           screen /dev/rfcomm0 ${DEF_SPP_BAUD}"
		say "  Windows: pair, then open the outgoing COM port with PuTTY."
		say "  A login prompt comes on the connection. Give the account name"
		say "  and the password."
		say "  ${C_B}Do not push Enter at an empty login prompt.${C_0} An empty account name"
		say "  stops the login program and ends the session."
		say "  To leave screen, push Ctrl-A then K."
		say ""
		say "  ${C_B}A Mac that paired before this install must pair again.${C_0} macOS reads"
		say "  the service list one time, at the moment you pair. Forget the device"
		say "  on the Mac. Then pair again. Only then does a /dev/cu.* device come."
		say ""
		say "  ${C_B}A Mac gives one session for each Bluetooth restart.${C_0} After a session"
		say "  stops, the port still opens but no data moves. A disconnection and a"
		say "  connection do not correct this. Run \"sudo pkill bluetoothd\" on the"
		say "  Mac. Then connect again. Do all your work in one session."
		say ""
	fi

	if [[ "$MDNS" == "yes" && -f "$AVAHI_FILE" ]]; then
		say "SSH clients with mDNS support show \"${BT_ALIAS} (SSH over Bluetooth)\"."
		say ""
	fi

	if [[ "$PAN" == "yes" && "$SPP" != "yes" ]]; then
		say "${C_D}macOS, iOS, and iPadOS have no Bluetooth PAN support. For a Mac client,"
		say "install again without --no-spp to get the serial console.${C_0}"
	elif [[ "$SPP" == "yes" ]]; then
		say "${C_D}iOS and iPadOS cannot use either path. Use a laptop or an Android device.${C_0}"
	fi
}

# ------------------------------------------------------------------- help ----

help_main() {
	cat <<EOF
${C_B}${PROG}${C_0} ${VERSION} - SSH over Bluetooth (PAN/NAP) manager.

The machine gives two ways to get a shell over Bluetooth. No Wi-Fi, no
Ethernet, and no display are necessary.

  PAN   A Bluetooth network. The client gets an address and uses SSH.
        Linux, Windows, and Android support it.
  SPP   A Bluetooth serial port with a login prompt on it.
        macOS supports it. This is the only way in for a Mac.

Both run at the same time by default. Each one has its own service.

${C_B}USAGE${C_0}
  ${PROG} <command> [options]

${C_B}SETUP COMMANDS${C_0}
  install       Install the system and start it.
  uninstall     Remove all changes of the install.
  config        Show the current configuration.

${C_B}CONTROL COMMANDS${C_0}
  start         Start the services now.
  stop          Stop the services now.
  restart       Stop the services. Then start them.
  enable        Start the services at each boot.
  disable       Do not start the services at boot.

${C_B}DIAGNOSTIC COMMANDS${C_0}
  status        Show the state of the services and the network.
  doctor        Check the host for problems. Give a remedy for each problem.
  logs          Show the service logs.
  clients       List the paired devices and the connected devices.

${C_B}DEVICE COMMANDS${C_0}
  connect <MAC>     Start a link to a paired device from this machine.
  disconnect [MAC]  Stop the link. With no MAC, stop all of them.
  forget <MAC>      Remove a paired device.

${C_B}OTHER COMMANDS${C_0}
  help [command]  Show help. Give a command name for more detail.
  version         Show the version.

${C_B}NOTES${C_0}
  The commands that change the system get root permission with sudo.
  For the options of one command, run: ${PROG} help <command>

${C_B}QUICK START${C_0}
  ${PROG} doctor
  ${PROG} install --alias "Server Room Box" --user admin
  ${PROG} status
EOF
}

help_install() {
	cat <<EOF
${C_B}${PROG} install${C_0} - Install the system and start it.

The command finds a value for each option that you do not give. It shows the
plan. Then it asks for approval before it changes the system.

${C_B}USAGE${C_0}
  ${PROG} install [options]

The install gives two ways in at the same time. Each one is advertised on its
own, and each one has its own service. You can turn either one off.

  PAN   A Bluetooth network. The client gets an address and uses SSH.
        Linux, Windows, and Android support it. macOS and iOS do not.
  SPP   A Bluetooth serial port with a login prompt on it.
        macOS supports it. This is the only way in for a Mac.

${C_B}GENERAL OPTIONS${C_0}
  -a, --alias NAME      The Bluetooth name that the client sees.
                        Default: the hostname of this machine.
  -i, --adapter hciN    The Bluetooth controller. Default: the first controller.
      --no-mdns         Do not advertise the SSH service with mDNS.
      --no-auto-pair    Do not accept a pair request without approval.
      --no-autostart    Do not start the services at boot.
  -y, --yes             Do not ask for approval.
  -h, --help            Show this help.

${C_B}PAN OPTIONS (the Bluetooth network)${C_0}
      --no-pan          Do not install the network. SPP stays available.
                        This also removes the bridge, the DHCP server, the
                        NAT rule, the firewall change, and the landing page.
  -u, --user NAME       The account for the SSH login.
                        Default: the account that started sudo.
  -b, --bridge NAME     The bridge interface name. Default: ${DEF_BRIDGE}
  -n, --subnet CIDR     The isolated subnet. Default: ${DEF_SUBNET}
                        This machine takes the first address of the subnet.
  -p, --ssh-port N      The port of the SSH server. Default: ${DEF_SSH_PORT}
      --backend MODE    auto, nm, or manual. Default: auto
                        nm     = NetworkManager shared mode.
                        manual = bridge, dnsmasq, and nftables or iptables.
      --zone NAME       The firewalld zone for the bridge. Default: ${DEF_ZONE}
      --no-portal       Do not install the web landing page.

${C_B}SPP OPTIONS (the Bluetooth serial console)${C_0}
      --no-spp          Do not install the serial console. PAN stays available.
      --spp-name NAME   The name of the serial service. Default: ${DEF_SPP_NAME}
                        macOS makes the device node from this name:
                        /dev/cu.<bluetooth-name>-<spp-name>
      --spp-channel N   The RFCOMM channel, 1 to 30. Default: bluez selects one.
      --spp-shell PATH  The program that runs on each connection.
                        Default: the login program of this machine.
      --spp-debug       Record a quantity of bytes for the data that goes to
                        the client. Use it when no prompt arrives. What the
                        client sends is never recorded, because it holds the
                        password. Read it with: ${PROG} logs spp

${C_B}EXAMPLES${C_0}
  ${PROG} install
  ${PROG} install --alias "Rack 3 Node" --user ops --subnet 10.99.0.0/24
  ${PROG} install --no-pan --spp-name Console      # a Mac client only
  ${PROG} install --no-spp                         # a network only
  ${PROG} install --backend manual --no-portal --no-mdns -y

${C_B}NOTES${C_0}
  bluez fixes the name of the PAN service record. There is no option to change
  it. Only the SPP service name is adjustable.
  --no-pan and --no-spp together are refused, because they leave no way in.

${C_B}SECURITY${C_0}
  The default configuration accepts each pair request. Then the account
  password is the only barrier. This applies to both ways in: SSH asks for the
  password on the PAN, and the login program asks for it on the serial console.
  Use --no-auto-pair for more control. Use an SSH key and set
  PasswordAuthentication no when the key operates correctly.
EOF
}

help_uninstall() {
	cat <<EOF
${C_B}${PROG} uninstall${C_0} - Remove all changes of the install.

The command stops the services. It removes the units, the files, the bridge,
and the firewall change. The Wi-Fi and LAN settings do not change. The paired
devices stay in the Bluetooth database.

${C_B}USAGE${C_0}
  ${PROG} uninstall [-y]

${C_B}OPTIONS${C_0}
  -y, --yes    Do not ask for approval.
  -h, --help   Show this help.
EOF
}

help_logs() {
	cat <<EOF
${C_B}${PROG} logs${C_0} - Show the service logs.

${C_B}USAGE${C_0}
  ${PROG} logs [unit] [options]

${C_B}UNITS${C_0}
  agent    The adapter and pairing agent service.
  nap      The NAP broadcast service. "pan" also selects it.
  spp      The serial console service. "serial" also selects it.
  portal   The web landing page service.
  net      The bridge and NAT service (manual backend only).
  dhcp     The DHCP and DNS service (manual backend only).
  (none)   All units of the install.

${C_B}OPTIONS${C_0}
  -f, --follow     Show new lines as they arrive.
  -n, --lines N    The quantity of lines to show. Default: 60
  -h, --help       Show this help.

${C_B}EXAMPLES${C_0}
  ${PROG} logs
  ${PROG} logs nap -f
  ${PROG} logs -n 200
EOF
}

help_status() {
	cat <<EOF
${C_B}${PROG} status${C_0} - Show the state of the services and the network.

The command shows the configuration, the state of each service, the address of
the bridge, the Bluetooth adapter state, and the clients with an address.

${C_B}USAGE${C_0}
  ${PROG} status
EOF
}

help_doctor() {
	cat <<EOF
${C_B}${PROG} doctor${C_0} - Check the host for problems.

The command examines the necessary programs, the Bluetooth hardware, the SSH
server, the network backend, and the installed state. It gives a remedy for
each problem. Run this command before the install.

${C_B}USAGE${C_0}
  ${PROG} doctor
EOF
}

help_forget() {
	cat <<EOF
${C_B}${PROG} forget${C_0} - Remove a paired device.

${C_B}USAGE${C_0}
  ${PROG} forget <MAC> [MAC ...]

Use "${PROG} clients" to find the MAC address of a device.

${C_B}EXAMPLE${C_0}
  ${PROG} forget AA:BB:CC:DD:EE:FF
EOF
}

help_connect() {
	cat <<EOF
${C_B}${PROG} connect${C_0} - Start a link to a paired device from this machine.

Usually the client starts the link. This command does the opposite: the host
machine starts it. The device must be paired first.

${C_B}USAGE${C_0}
  ${PROG} connect <MAC> [MAC ...]

${C_B}WHEN IT IS USEFUL${C_0}
  - The client has no Bluetooth menu, or its menu does not offer a connection.
  - A macOS client stops the link and does not start it again.
  - You have access to this machine and want to push a link to a known client.

${C_B}NOTE${C_0}
  This command needs access to this machine. In an emergency you do not have
  that access. Then the client must start the link.

${C_B}EXAMPLE${C_0}
  ${PROG} connect AA:BB:CC:DD:EE:FF
EOF
}

help_disconnect() {
	cat <<EOF
${C_B}${PROG} disconnect${C_0} - Stop the link to a device.

With no MAC address, the command stops the link to each connected device.

${C_B}USAGE${C_0}
  ${PROG} disconnect [MAC ...]

${C_B}WHEN IT IS USEFUL${C_0}
  A client that keeps a dead link open cannot make a new one. A disconnection
  from this side clears that condition. This is a known macOS behaviour with
  the serial console.

${C_B}EXAMPLES${C_0}
  ${PROG} disconnect
  ${PROG} disconnect AA:BB:CC:DD:EE:FF
EOF
}

help_simple() {
	cat <<EOF
${C_B}${PROG} $1${C_0} - $2

${C_B}USAGE${C_0}
  ${PROG} $1
EOF
}

cmd_help() {
	case "${1:-}" in
	"") help_main ;;
	install) help_install ;;
	uninstall | remove) help_uninstall ;;
	logs) help_logs ;;
	status) help_status ;;
	doctor) help_doctor ;;
	forget) help_forget ;;
	connect) help_connect ;;
	disconnect) help_disconnect ;;
	start) help_simple start "Start the services now." ;;
	stop) help_simple stop "Stop the services now." ;;
	restart) help_simple restart "Stop the services. Then start them." ;;
	enable) help_simple enable "Start the services at each boot." ;;
	disable) help_simple disable "Do not start the services at boot." ;;
	clients) help_simple clients "List the paired devices and the connected devices." ;;
	config) help_simple config "Show the current configuration." ;;
	version) help_simple version "Show the version." ;;
	help) help_simple "help [command]" "Show help. Give a command name for more detail." ;;
	*) die "No help is available for \"$1\". Run \"${PROG} help\" for the command list." ;;
	esac
}

# ------------------------------------------------------------------- main ----

main() {
	local cmd="${1:-help}"
	[[ $# -gt 0 ]] && shift || true

	case "$cmd" in
	install | setup) cmd_install "$@" ;;
	uninstall | remove | teardown) cmd_uninstall "$@" ;;
	start) cmd_start "$@" ;;
	stop) cmd_stop "$@" ;;
	restart) cmd_restart "$@" ;;
	enable) cmd_enable "$@" ;;
	disable) cmd_disable "$@" ;;
	status) cmd_status "$@" ;;
	doctor | check) cmd_doctor "$@" ;;
	logs | log) cmd_logs "$@" ;;
	clients | devices) cmd_clients "$@" ;;
	connect) cmd_connect "$@" ;;
	disconnect) cmd_disconnect "$@" ;;
	forget) cmd_forget "$@" ;;
	config) cmd_config "$@" ;;
	help | -h | --help) cmd_help "$@" ;;
	version | -V | --version) say "${PROG} ${VERSION}" ;;
	*) die "Unknown command \"${cmd}\". Run \"${PROG} help\" for the command list." ;;
	esac
}

main ${ORIG_ARGV[@]+"${ORIG_ARGV[@]}"}
