# OpenLay VPN — client binaries

Pre-built clients for OpenLay VPN. Each subfolder targets a platform and hosts
the binary + installer + integrity manifest.

```
linux-client/   # Linux (x86_64; aarch64 coming soon)
```

## Linux — quick install

```bash
curl -sSL https://raw.githubusercontent.com/openlay/openlay-vpn-client-release/main/linux-client/install.sh | sudo bash
```

The installer:
- pulls OS deps (`wireguard-tools`, `iptables`, `systemd-resolved`, optional `tpm2-tools`) from `apt` / `dnf` / `pacman`
- downloads the architecture-appropriate `olv-vpn-linux-<arch>` binary from this repo
- verifies its SHA256 against `SHA256SUMS`
- installs to `/usr/sbin/olv-vpn` + drops the systemd unit at `/etc/systemd/system/olv-vpn.service`

After install:

```bash
sudo olv-vpn enroll --code 1234567890 --server https://vpn.livevpn.com
sudo olv-vpn connect
sudo systemctl enable --now olv-vpn       # optional: auto-reconnect on peer TTL
```

## Self-update

The client can rotate itself in place:

```bash
sudo olv-vpn update
```

Flow: read `linux-client/VERSION` on `main`, compare against the running
binary, download the newer `olv-vpn-linux-<arch>` and verify against
`SHA256SUMS`, then atomically `rename(2)` over `/usr/sbin/olv-vpn`. Restart
the daemon afterwards if it's running:

```bash
sudo systemctl restart olv-vpn
```

## Supported distros

Tested on **Rocky Linux 9.7** (x86_64, real TPM 2.0). Should work on any
modern Linux with:

- kernel WireGuard (≥ 5.6 built-in, or `wireguard-dkms` on older kernels)
- `wireguard-tools` ≥ 1.0
- `iptables` (nft or legacy backend — both fine)
- `systemd` ≥ 245 (for `systemd-resolved` DNS handling inside `wg-quick`)
- optional: TPM 2.0 + `tpm2-tools` ≥ 5.0 for hardware-backed device key

See the [source repo](https://github.com/openlay/openlay-vpn-client/tree/main/linux-client)
for architecture details, commands, and troubleshooting.

## What's in each release

| File                          | Role                                                |
| ----------------------------- | --------------------------------------------------- |
| `olv-vpn-linux-x86_64`        | PyInstaller single-file binary (x86_64)             |
| `olv-vpn-linux-aarch64`       | PyInstaller single-file binary (aarch64) — pending |
| `VERSION`                     | Plain-text semantic version (e.g. `0.2.0`)          |
| `SHA256SUMS`                  | `sha256  name` for every binary                     |
| `install.sh`                  | First-time installer (bash + curl)                  |
| `olv-vpn.service`             | systemd unit for the reconnect daemon               |

## Issues / bug reports

File an issue on the [source repo](https://github.com/openlay/openlay-vpn-client/issues).
