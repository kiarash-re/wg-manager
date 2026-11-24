# WireGuard SAFE Manager

A single bash script that manages Mullvad WireGuard tunnels that Xray uses through `fwmark` (`sockopt.mark`) on Ubuntu servers.

- Policy routing per tunnel (fwmark → own table), with endpoint loop protection
- Keeps the rules alive when `systemd-networkd` restarts (drop-in + hook)
- Watchdog (systemd timer, every 5 min): repairs routing, restarts dead tunnels with backoff
- Real-path tests through the mark: exit IP v4/v6, leak detection, ping, MTU
- Bulk import from a .zip or folder of WireGuard configs from Mullvad or any other provider
- Leak counter (counts only, blocks nothing), backup/restore, rollback with diff
- Interactive menu: health banner with one-key fix, `/` search for every action, phone layout, live monitor

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/kiarash-re/wg-manager/main/wg-manager.sh -o /root/wg-manager.sh
bash /root/wg-manager.sh install
wg-manager
```

Requires root, `wireguard-tools`, `iptables`, `python3`, systemd ≥ 249 (older works, without the networkd fix).

## Usage

Run `wg-manager` for the menu, or `wg-manager help` for all commands (`add`, `import <zip>`, `test all`, `doctor --fix`, `status --json`, `monitor`, `backup`, `rollback`, …).

Options: `WGM_FLAGS=0` hides country flags, `WGM_LOGO=0` hides the logo, `NO_COLOR=1` disables colors.
