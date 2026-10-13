![Omaspot flyout](assets/omaspot.png)

# Omaspot

Compact Omarchy bar plugin for starting and stopping a mobile Wi-Fi hotspot
with `create_ap` (`linux-wifi-hotspot`).

## Requirements

- `create_ap` (linux-wifi-hotspot)
- `pkexec` (polkit)
- `nmcli` (networkmanager)
- `stat` (coreutils)
- `qrencode` (optional, QR code)
- `iw` (optional, associated-device markers)

Dependencies are checked on every open; missing required packages show an
install command with a Copy button.

## Install

```sh
omarchy plugin install https://github.com/DeV-433/Omaspot.git --enable --yes
```

or:

```sh
omarchy plugin add https://github.com/DeV-433/Omaspot.git --enable --yes
```

## Use

Open the panel from the bar, choose upstream/band/channel, edit SSID and
security key, then use the switch. The QR code appears only while active.
Settings and credentials are stored in:

```text
~/.local/state/omarchy/settings/io.github.devanshu.omaspot.json
```

## Development

```sh
omarchy plugin validate .
node -e "const m=require('./Model.js'); console.log(m.defaults())"
bash -n backend/omaspotctl
```

Backend commands: `status`, `interfaces`, `deps`, `doctor`, `clients`,
`start`, `stop`, `qr`.

## Security

State and instance data under `/tmp` are validated (root-owned,
non-writable, symlink-safe) before any privileged action; create_ap pids are
matched against `/proc` identity and start time. Omaspot also refuses to run
while `/tmp/create_ap.common.conf` is not root-owned, because create_ap
cleans it up as root.

## License

MIT. See [LICENSE](LICENSE).
```