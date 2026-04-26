# Server-side admin guide — VPN client behind a killswitch

## TL;DR for admins

When VPN clients run with a **killswitch** (Windows default, optional on
Linux/macOS), all traffic NOT going through the WireGuard tunnel is
blocked at the OS firewall. If the management server isn't reachable
through the tunnel, the client can never refresh its peer key and
permanently loses access after the peer's TTL expires.

**Fix:** include the management server's IP (or a small CIDR around it)
in the AllowedIPs returned by `POST /api/connect`.

## The chicken-and-egg

```
T0       client connects → peer valid for 24h → DNS = 1.1.1.1 (via tunnel)
T0+24h   server-side peer TTL hits → server evicts peer
         client tries to refresh → packet → tunnel → server drops (no peer)
         client DNS query → 1.1.1.1 → tunnel → drop
         client app-api request → vpn.livevpn.com → DNS NXDOMAIN
         → client retries every 5 min, never recovers
         → killswitch blocks any non-VPN attempt to bypass
```

On Linux without killswitch, the client (v0.3.1+) self-heals by tearing
the tunnel down and retrying over `eth0`. On **Windows with
killswitch**, that escape hatch doesn't exist — we must keep the
management connection routable through the tunnel.

## Required server-side configuration

The management server must be **inside AllowedIPs**. For each device
(or for all devices), update `device_static_ips.allowed_ips` to include:

```
<management-server-IP>/32        — direct IP, no DNS
```

OR a CIDR that covers it:

```
<management-subnet>/24           — preferred if mgmt is in a stable subnet
```

### SQL examples

For a specific device:

```sql
INSERT INTO device_static_ips
  (device_id, server_id, subnet_id, ip_address, allowed_ips)
VALUES
  ('<device_uuid>', <server_id>, <subnet_id>, '<assigned_vpn_ip>',
   ARRAY['10.88.0.0/24', '<mgmt_ip>/32'])
ON CONFLICT (device_id, server_id, subnet_id) DO UPDATE
  SET allowed_ips = EXCLUDED.allowed_ips;
```

To roll it out to every existing device on a server:

```sql
UPDATE device_static_ips
   SET allowed_ips = array_cat(allowed_ips, ARRAY['<mgmt_ip>/32'])
 WHERE server_id = <server_id>
   AND NOT (allowed_ips @> ARRAY['<mgmt_ip>/32']);
```

After updating, each device must `olv-vpn reconnect` (Linux) or refresh
the connection (Windows) once to pick up the new AllowedIPs. Subsequent
TTL-driven refreshes will use the new value automatically.

## Recommended: use a direct IP, not Cloudflare-proxied

If `vpn.livevpn.com` (or your equivalent) sits behind Cloudflare's
anycast, the management endpoint resolves to one of Cloudflare's
**rotating** IPs (`104.x.x.x`, `172.67.x.x`, `162.158.x.x`, …). You'd
have to whitelist Cloudflare's entire IP range in AllowedIPs — large,
opaque, and changes over time.

**Switch the management hostname to a DNS A record pointing directly at
the origin server's static IP.** Disable the Cloudflare proxy (set the
record to "DNS only", grey cloud) for that hostname. Then a single
`<origin_ip>/32` entry in AllowedIPs is enough.

You lose Cloudflare DDoS / WAF protection on management, so:

- Restrict the origin server's firewall to only accept :443 from VPN
  egress IPs (or whitelist your office / admin IPs).
- Keep Cloudflare in front of any **non-management** endpoints that
  don't need to be reachable through the tunnel.

## Verification

After deploying, on a client:

```sh
sudo olv-vpn reconnect
sudo grep AllowedIPs /etc/wireguard/olv0.conf
# expected to include: <mgmt_ip>/32  (or the subnet you used)

# confirm management is reached via tunnel
ip route get <mgmt_ip>
# expected: dev olv0
```

When TTL hits, daemon will refresh through the tunnel even if killswitch
is on. Watch:

```sh
sudo journalctl -u olv-vpn -f
# [daemon] connected to <server>; next refresh in <ttl-300>s
```

## Client behaviour summary

- **Linux v0.3.1+**: detects DNS deadlock from gaierror → brings tunnel
  down → retries over `eth0`. Works without admin intervention BUT only
  on hosts with no killswitch.
- **Linux v0.3.2+**: in addition to the above, refreshes 5 minutes
  before TTL (was 60s) and caps backoff so retries don't sleep past
  expiry. Gives the daemon ~4-5 retry windows before the peer is gone.
- **Windows w/ killswitch**: relies on the AllowedIPs config above —
  there is no DNS-deadlock self-heal because the killswitch blocks any
  attempt to bypass.

## Why both early-refresh AND mgmt-in-AllowedIPs?

Either one alone is incomplete:

| Scenario | Early refresh only | Mgmt in AllowedIPs only | Both |
|---|---|---|---|
| Transient network blip | ✓ retries succeed | ✓ retries succeed | ✓ |
| Long network outage > 5 min | ✗ peer expires | ✓ refreshes via tunnel as soon as net returns | ✓ |
| Peer expired server-side | ✗ chicken-egg | ✓ refresh via tunnel (peer still valid until TTL) | ✓ |
| Killswitch on, mgmt outside tunnel | ✗ blocked | N/A — config error | — |

Run both. They reinforce each other.
