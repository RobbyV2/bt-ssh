# Shell over Bluetooth

This repository gives a Linux machine two ways to hand out a shell over
Bluetooth. No Wi-Fi, no Ethernet, no router, and no display are necessary.

| Way in | Method | Clients |
|---|---|---|
| **PAN** | A Bluetooth network. The client gets an address. The client then uses SSH. | Linux, Windows, Android |
| **SPP** | A Bluetooth serial port with a login prompt on it. | macOS, Linux, Windows |

Both run at the same time by default. Each one is advertised on its own, and
each one has its own service. Stop one, and the other continues.

Use this as an emergency access path to a headless machine, a server, or a
handheld computer.

One script does all the work:

```bash
./bt-ssh-manager.sh doctor      # check the host for problems
./bt-ssh-manager.sh install     # install the system and start it
./bt-ssh-manager.sh status      # show the state
./bt-ssh-manager.sh uninstall   # remove all changes
```

The script gets root permission with `sudo` when it is necessary. Do not start
it with `sudo` yourself.

## How it works

```
  PAN client (Linux/Windows/Android)          host machine
  ┌───────────────────┐                      ┌──────────────────────────────┐
  │ Bluetooth PAN     │  Bluetooth, ~10 m    │ bt-ssh-agent                 │
  │ 10.137.0.x        │◄────────────────────►│   adapter + pairing agent    │
  │   gw 10.137.0.1   │                      │                              │
  └─────────┬─────────┘                      │ bt-ssh-nap ──► bridge nap0   │
            │ ssh user@10.137.0.1            │   10.137.0.1/24 + DHCP + NAT │
            ▼                                │                              │
        a shell                              │ bt-ssh-spp ──► RFCOMM        │
                                             │   login prompt on a pty      │
  SPP client (macOS)                         │                              │
  ┌───────────────────┐                      │ sshd (no change)             │
  │ /dev/cu.NAME-Serial│◄───────────────────►└──────────────────────────────┘
  │   screen … 115200 │
  └─────────┬─────────┘
            ▼
        a login prompt
```

The Bluetooth network is an isolated network on its own bridge with its own
DHCP server. The Wi-Fi settings, the LAN routes, and the default gateway do not
change. The Bluetooth subnet only sends its traffic out through the default
route that the machine has.

The serial console needs no network at all. bluez gives one socket for each
connection. The service puts a pseudo terminal on the socket and runs the login
program on it.

### The services

| Service | Function | Necessary |
|---|---|---|
| `bt-ssh-agent` | Powers the adapter. Sets the name. Keeps the machine discoverable and pairable. Accepts pair requests. | Always |
| `bt-ssh-nap` | Registers the NAP server on the bridge. | PAN |
| `bt-ssh-spp` | Registers the SPP profile. Serves a login prompt. | SPP |
| `bt-ssh-portal` | A web page on the gateway address that shows the SSH command. | PAN, optional |
| `bt-ssh-net` | Makes the bridge and the NAT rule. | PAN, `manual` backend |
| `bt-ssh-dhcp` | The DHCP and DNS server for the PAN. | PAN, `manual` backend |

## Requirements

The host machine needs:

- Linux with systemd
- A Bluetooth controller
- `bluez` and `bluetoothctl`
- `python3` (**the standard library only**)

There is no Python package to install. The daemons speak the D-Bus protocol
directly through a small module in `/etc/bt-ssh/dbuslite.py`. `dbus-python` and
`PyGObject` are **not** necessary.

PAN also needs an SSH server and `dnsmasq`. SPP needs neither. An SPP-only
install (`--no-pan`) touches no network settings at all, and it adds no package
to the machine.

Run `./bt-ssh-manager.sh doctor` first. It examines each requirement. It gives the
install command for each package that is missing.

### Network backends

PAN has two ways to make the isolated network. The script selects one
automatically. Use `--backend` to select one yourself.

| Backend | Method | Use it when |
|---|---|---|
| `nm` | NetworkManager bridge with `ipv4.method shared` | NetworkManager is active. This is the usual condition on a desktop distribution. |
| `manual` | `ip` bridge, a dedicated `dnsmasq`, and nftables or iptables NAT | NetworkManager is not present. Examples are Debian minimal, Raspberry Pi OS, and a systemd-networkd machine. |

The `nm` backend has more operational history than the `manual` backend.

The script also finds the firewall manager. It supports firewalld, ufw, and
plain nftables or iptables.

## Install

```bash
git clone <this-repo>
cd bt-ssh
./bt-ssh-manager.sh doctor
./bt-ssh-manager.sh install
```

The install command finds a value for each option that you do not give. It
shows the plan. Then it asks for approval before it changes the machine.

Examples:

```bash
./bt-ssh-manager.sh install --alias "Rack 3 Node" --user ops
./bt-ssh-manager.sh install --no-pan --spp-name Console    # a Mac client only
./bt-ssh-manager.sh install --no-spp                       # a network only
./bt-ssh-manager.sh install --subnet 10.99.0.0/24 --backend manual
```

To change a value later, run the install command again with the new options.
The command replaces the earlier configuration.

### General options

| Option | Function | Default |
|---|---|---|
| `-a, --alias NAME` | The Bluetooth name that the client sees. | The hostname. |
| `-i, --adapter hciN` | The Bluetooth controller. | The first controller. |
| `--no-mdns` | Do not advertise the SSH service with mDNS. | The service is advertised. |
| `--no-auto-pair` | Do not accept a pair request without approval. | Pair requests are accepted. |
| `--no-autostart` | Do not start the services at boot. | The services start at boot. |
| `-y, --yes` | Do not ask for approval. | The command asks. |

### PAN options

| Option | Function | Default |
|---|---|---|
| `--no-pan` | Do not install the network. SPP stays available. This also removes the bridge, the DHCP server, the NAT rule, the firewall change, and the landing page. | PAN is installed. |
| `-u, --user NAME` | The account for the SSH login. | The account that started `sudo`. |
| `-b, --bridge NAME` | The bridge interface name. | `nap0` |
| `-n, --subnet CIDR` | The isolated subnet. The machine takes the first address. | `10.137.0.0/24` |
| `-p, --ssh-port N` | The port of the SSH server. | `22` |
| `--backend MODE` | `auto`, `nm`, or `manual`. | `auto` |
| `--zone NAME` | The firewalld zone for the bridge. | `trusted` |
| `--no-portal` | Do not install the web landing page. | The page is installed. |

### SPP options

| Option | Function | Default |
|---|---|---|
| `--no-spp` | Do not install the serial console. PAN stays available. | SPP is installed. |
| `--spp-name NAME` | The name of the serial service. macOS makes the device node from it: `/dev/cu.<bluetooth-name>-<spp-name>` | `Serial` |
| `--spp-channel N` | The RFCOMM channel, 1 to 30. | bluez selects one. |
| `--spp-shell PATH` | The program that runs on each connection. | The login program of this machine. |

`--no-pan` and `--no-spp` together are refused, because they leave no way in.

bluez fixes the name of the PAN service record. There is no supported option to
change it. Only the SPP service name is adjustable.

## Connect from a client

Pair with the Bluetooth name of the machine first. Then use one of the two
ways in.

### Way 1: SSH over the Bluetooth network (PAN)

1. Join the Bluetooth network. **This step is necessary. Many people forget
   it. Pairing alone does not give you an address.**
   - **Windows**: Bluetooth settings → the device → *Connect using* →
     *Access point*
   - **Linux**: the network menu → the device → *Connect*, or
     `nmcli device connect <BT-MAC>`
   - **Android**: the paired device settings → enable *Internet access*
2. Use SSH:
   ```bash
   ssh user@10.137.0.1
   ```
   Give the account password. Then use `sudo` for root permission.

### Way 2: The serial console (SPP)

- **macOS**:
  ```bash
  ls /dev/cu.*                       # find the exact name first
  screen /dev/cu.<name> 115200
  ```
  macOS makes the name from the Bluetooth name. Sometimes it adds the service
  name, and sometimes it does not. Both `/dev/cu.MyBox` and
  `/dev/cu.MyBox-Serial` are usual. Always look at `ls /dev/cu.*` for the
  correct name.

  > **Do not push Enter at an empty login prompt.** An empty account name tells
  > the login program to stop. That ends the session immediately. Type the
  > account name first, then push Enter.
- **Linux**:
  ```bash
  sudo rfcomm connect /dev/rfcomm0 <BT-MAC>
  screen /dev/rfcomm0 115200
  ```
- **Windows**: pair, then open the outgoing COM port with PuTTY.

A login prompt comes on the connection. Give the account name and the password.
To leave `screen`, push `Ctrl-A` then `K`. Leave `screen` correctly. Do not
close the terminal window, because that keeps the serial port open.

> **A Mac must pair again after you add SPP.** macOS reads the service list of
> a device one time, at the moment you pair. A profile that comes later stays
> invisible. If you installed PAN first and added SPP after, do this:
> *System Settings → Bluetooth → the device → Forget This Device*. Then pair
> again. A new `/dev/cu.*` device comes only after that.

#### A Mac gives one serial session for each Bluetooth restart

This is a macOS limitation. It is not a condition of the host machine.

After one serial session stops, macOS keeps the old RFCOMM state. The port
`/dev/cu.*` still opens, and the open operation gives no error, but no data
moves. macOS does not make a new connection to the host machine.

A disconnection and a connection in the Bluetooth settings **do not** correct
this. Only a restart of the macOS Bluetooth daemon does:

```bash
sudo pkill bluetoothd
```

macOS starts the daemon again automatically. Connect the device again. Then the
serial console operates one more time.

Because of this, do all of your work in one session. Do not stop the session
and start it again.

Linux and Windows clients do not have this limitation. The condition is in the
Apple Bluetooth stack. See the
[report of the same behaviour with other serial devices](https://community.st.com/t5/others-stm32-mcus-related/rn4678-macos-rfcomm-spp-reconnect-port-opens-but-no-data-until/td-p/838349).

### Client support

| Client | PAN | SPP |
|---|---|---|
| Linux | Yes | Yes |
| Windows | Yes | Yes |
| Android | Yes | With a serial terminal app |
| macOS | **No** | **Yes** |
| iOS and iPadOS | No | No |

Apple removed the Bluetooth PAN (BNEP) network stack from macOS. A recent Mac
pairs with the machine, but it cannot join the Bluetooth network. There is no
*Connect to Network* command, because the network service does not exist. This
condition is in macOS itself. No change on the host machine corrects it.

To confirm this on a Mac, run:

```bash
networksetup -listallhardwareports | grep -i bluetooth
```

An empty result means that the Mac has no Bluetooth PAN support. **Use the
serial console instead.** That is why SPP is installed by default.

An Apple iPhone or iPad cannot use either way in.

### The client can find the SSH command without documentation

- **A browser**: open `http://10.137.0.1`. The page shows the SSH command. The
  page is bound to the gateway address only. It is not available on the Wi-Fi
  network.
- **mDNS**: the machine advertises `_ssh._tcp`. SSH clients with mDNS support
  show the machine in a list. Avahi advertises on all interfaces, so this record
  is also on the Wi-Fi network. This is not a problem, because `sshd` already
  listens there.

## Commands

```
bt-ssh-manager.sh <command> [options]

SETUP
  install       Install the system and start it.
  uninstall     Remove all changes of the install.
  config        Show the current configuration.

CONTROL
  start         Start the services now.
  stop          Stop the services now.
  restart       Stop the services. Then start them.
  enable        Start the services at each boot.
  disable       Do not start the services at boot.

DIAGNOSTIC
  status        Show the state of the services and the network.
  doctor        Check the host for problems. Give a remedy for each problem.
  logs          Show the service logs.
  clients       List the paired devices and the connected devices.
  forget <MAC>  Remove a paired device.

OTHER
  help [command]  Show help. Give a command name for more detail.
  version         Show the version.
```

For the options of one command, run `bt-ssh-manager.sh help <command>`.

Examples:

```bash
./bt-ssh-manager.sh status            # what is advertised? who has an address?
./bt-ssh-manager.sh logs spp -f       # follow the serial console log
./bt-ssh-manager.sh logs nap          # the NAP service log
./bt-ssh-manager.sh clients           # who is paired
./bt-ssh-manager.sh forget AA:BB:CC:DD:EE:FF
./bt-ssh-manager.sh stop              # stop all the services now
```

`logs` accepts a unit name: `agent`, `nap` (or `pan`), `spp` (or `serial`),
`portal`, `net`, and `dhcp`. With no name, it shows all of them.

## Security

Read this section before you use the system.

The access barriers are the Bluetooth pairing, the physical range of
approximately 10 metres, and the account password.

- The default configuration **accepts each pair request without approval**.
  This makes emergency access easy. Then the account password is the only real
  barrier. This applies to **both** ways in: SSH asks for the password on the
  PAN, and the login program asks for it on the serial console. Use
  `--no-auto-pair` when you want more control. Then approve each pair request
  with `bluetoothctl`.
- The serial console gives a login prompt to each paired device. Use `--no-spp`
  when you do not want it. Use `--spp-shell` to give a different program.
- The bridge goes in the firewalld zone `trusted` by default. A connected PAN
  client can reach each port of the host. Use `--zone` to select a stricter
  zone. On Fedora, the zone `FedoraWorkstation` still permits SSH.
- An SSH key is better than a password. Put a key on the emergency client. Then
  set `PasswordAuthentication no`. Do this step only after the key operates
  correctly, because the change stops each password login. This does not affect
  the serial console, which always uses the account password.
- Fedora and most other distributions do not permit a root SSH login with a
  password. Log in as a normal account. Then use `sudo`.

## Uninstall

```bash
./bt-ssh-manager.sh uninstall
```

The command stops the services. It removes the units, the files, the bridge,
and the firewall change. The Wi-Fi settings and the LAN settings do not change.

The paired devices stay in the Bluetooth database. They are not dangerous. To
remove one:

```bash
./bt-ssh-manager.sh clients
./bt-ssh-manager.sh forget <MAC>
```

## What the install changes

| Location | Content |
|---|---|
| `/etc/bt-ssh/` | The configuration, `dbuslite.py`, the Python daemons, and the network scripts. |
| `/etc/systemd/system/bt-ssh-*.service` | The service units. |
| `/etc/avahi/services/bt-ssh.service` | The mDNS advert. Optional. |
| The `nap0` bridge | The isolated network. PAN only. |
| The firewall | One rule or one zone change for the bridge only. PAN only. |

The install does not change `sshd_config`, the Wi-Fi connection, the default
route, or the DNS configuration of the host.

## Troubleshooting

Run `./bt-ssh-manager.sh doctor` first. It finds most problems and gives a remedy.
Then run `./bt-ssh-manager.sh status`, which shows which profiles are advertised.

| Symptom | Cause and remedy |
|---|---|
| The machine is not in the Bluetooth list of the client. | Make sure that you know the broadcast name. Run `bt-ssh-manager.sh config` to see it. The name comes from the hostname when you do not give `--alias`. |
| A Mac pairs, but then nothing happens. | macOS has no Bluetooth PAN support. Use the serial console. See *Way 2*. |
| The client pairs, but SSH gets a timeout. | The client did not join the Bluetooth network. Do step 1 of *Way 1*. Make sure that the client has an address in the subnet. |
| No `/dev/cu.*` device comes on the Mac. | Usually the Mac paired before SPP was installed, so its service list is old. Forget the device on the Mac. Then pair again. If the device is still absent, run `bt-ssh-manager.sh logs spp`. |
| The serial console opens on a Mac, but the display stays empty. | macOS gives one session for each Bluetooth restart. Run `sudo pkill bluetoothd` on the Mac. Then connect the device again. See *A Mac gives one serial session for each Bluetooth restart*. |
| The session stops as soon as it starts. | Somebody pushed Enter at an empty login prompt. An empty account name stops the login program. Type the account name first. |
| The Mac shows the old name of the device. | macOS keeps the name from the moment you pair. Forget the device. Then pair again. |
| `Resource busy` comes when you open the serial port. | Another program has the port. Only one connection is possible at a time. Close the other `screen` session. |
| The bridge has no address. | The service did not start. Run `bt-ssh-manager.sh logs`. Then run `bt-ssh-manager.sh restart`. |
| The client has no address. | The DHCP server did not start. On the `manual` backend, run `bt-ssh-manager.sh logs dhcp`. On the `nm` backend, make sure that `dnsmasq` is installed. |
| The machine is not discoverable. | Run `bt-ssh-manager.sh logs agent`. Then run `bt-ssh-manager.sh restart`. |
| An SELinux denial is in the journal. | Run `sudo ausearch -m AVC -ts recent`. Then run `sudo audit2allow -a` to see the necessary policy. |
| The client gets an address, but has no internet access. | The NAT rule is missing, or IP forwarding is off. On the `manual` backend, run `sudo systemctl restart bt-ssh-net`. |
