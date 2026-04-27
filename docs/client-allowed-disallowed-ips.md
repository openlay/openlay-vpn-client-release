# AllowedIPs / DisallowedIPs / DisallowedDomains — client implementation guide

**Audience:** team building Linux / Windows / macOS / iOS / Android clients.
**Goal:** every client computes its WireGuard `AllowedIPs` the same way so
the daemon never gets caught in the chicken-and-egg where a dead-but-up
tunnel eats its own refresh request.

## The problem (why this exists)

WireGuard `AllowedIPs` is a routing decision: any destination matching it
goes via the tunnel; everything else uses the system default route. With
`AllowedIPs = 0.0.0.0/0, ::/0` (route-all) the tunnel becomes a black hole
for the daemon's own management traffic the moment the server-side peer
expires:

1. T0     — client connects, server-side peer valid for `peer_ttl_hours`
2. T0+ttl — server evicts the peer (TTL hit before next client refresh)
3. Client tries `POST /api/connect`:
   - `getaddrinfo("vpn.example.com")` → DNS query to nameserver in
     `AllowedIPs` → **tunnel** → dead → timeout
   - even with cached IP, TCP `connect()` to mgmt IP → **tunnel** → dead
4. Client cannot recover via the tunnel. On Windows-with-killswitch there
   is no eth0 fallback either — the client is bricked until manual reset.

The fix is server-declarative + client-computed: the server tells the
client which destinations must NOT be routed through the tunnel; the
client subtracts those (plus a few self-derived ones) from the server's
broad `AllowedIPs` before writing the WireGuard config. Pure WG semantics
— no socket marks, no /32 route pins, no firewall hacks.

## Server contract (`POST /api/connect` response)

```jsonc
{
  "assignedIp":     "10.10.0.6/32",
  "expiresAt":      "2026-04-27T18:30:00.000Z",
  "serverPublicKey": "...",
  "serverEndpoint": "18.184.29.198:51820",

  "allowedIPs":      "0.0.0.0/0, ::/0",  // BROAD set — what the org wants
                                          //  routed via tunnel
  "disallowedIPs":   ["10.0.0.0/8"],     // Server-declared exclusions
                                          //  (CIDRs only).
  "disallowedDomains": ["audit.example.com"], // (future phase) FQDNs the
                                              //  client resolves and adds
                                              //  to the exclusion set.
  "dns":             "1.1.1.1",
  ...
}
```

Source: `enterprise_settings` per enterprise.

```sql
INSERT INTO enterprise_settings (enterprise_id, key, value) VALUES
  (..., 'disallowed_ips', '10.0.0.0/8, 192.168.0.0/16'),
  (..., 'disallowed_domains', 'audit.example.com');
```

The values are comma-or-whitespace-separated.

## Client computation

```
exclude_set =
    server.disallowedIPs
  + resolve(server.disallowedDomains)        // future
  + resolve(client.app_api_url.host)         // ALWAYS — protects refresh path
  + active_inbound_ssh_peer_ips              // ALWAYS — protects operator SSH
                                              //   when AllowedIPs covers
                                              //   default route

effective_AllowedIPs = subtract_cidrs(server.allowedIPs, exclude_set)
```

Then write `effective_AllowedIPs` (NOT the raw server value) into the
WireGuard config's `[Peer] AllowedIPs = ...` line.

### Why each exclusion source

| Source | Necessity | What it protects |
|---|---|---|
| `disallowedIPs` (server) | Admin-controlled | Anything the org needs reachable off-tunnel (e.g. on-prem services not behind VPN, license servers, etc.) |
| `disallowedDomains` (server, future) | Admin-controlled | Same as above but for hostnames that may resolve to rotating IPs |
| `resolve(app_api_url.host)` | **Mandatory** | The daemon's own refresh endpoint. Without this, every ttl-driven refresh races with server-side peer rotation; loss of that race = dead tunnel until admin intervention. |
| Active inbound SSH peer IPs | **Mandatory on bare-metal/VM** | Prevents the daemon from locking out the operator who's currently SSH'd in. SSH replies need to leave the box via the SSH peer's source IP route, which is `eth0` not the tunnel. |

Apple platforms (iOS, macOS) typically don't host inbound SSH, so the SSH
exclusion is a no-op there. Windows servers running OpenSSH-server: yes,
include it. Linux daemons on cloud VMs: yes, definitely.

## CIDR subtraction algorithm

Given `parent_cidr` and `excluded_cidr`, produce the smallest set of CIDRs
that covers `parent_cidr − excluded_cidr`. Standard textbook algorithm
(also what Python's `ipaddress.ip_network.address_exclude()` does):

```
def subtract(parent, exclude):
    if not exclude.subnet_of(parent):
        yield parent
        return
    if parent == exclude:
        return
    # bisect parent at one bit deeper, recurse on the half that doesn't
    # contain `exclude`, repeat until parent == exclude.
    new_prefix = parent.prefixlen + 1
    half = parent.network_address
    left  = ip_network(f"{half}/{new_prefix}", strict=False)
    right = ip_network(f"{int(half) | (1 << (parent.max_prefixlen - new_prefix))}/{new_prefix}", strict=False)
    if exclude.subnet_of(left):
        yield right
        yield from subtract(left, exclude)
    else:
        yield left
        yield from subtract(right, exclude)
```

Example: `0.0.0.0/0 − 18.192.152.205/32` produces ~32 CIDRs covering all
of IPv4 minus that one /32. `10.10.0.0/24 − 10.10.0.6/32` produces 8
small CIDRs.

For multiple exclusions, iterate: take each exclusion in turn, replace
each CIDR in the working list with `subtract(cidr, exclusion)`, repeat.

For IPv6, the same logic applies — just keep IPv4 and IPv6 networks
separate (they don't overlap).

Reference Python implementation: `olv-client/linux-client/olv_vpn/wireguard.py::subtract_from_cidrs`.

## Detecting active SSH peers (Linux daemon)

```bash
ss -tnH state established sport = :22
# fields: <recv-q> <send-q> <local-addr:port> <peer-addr:port>
```

Parse the 4th field, take the IP portion (strip `[]` for IPv6). Each
unique peer IP gets a `/32` (IPv4) or `/128` (IPv6) added to the
exclusion set. macOS/BSD use `netstat -an | grep ESTABLISHED`; Windows
uses `Get-NetTCPConnection -State Established -LocalPort 22`.

Skip this entirely if you're not running an SSH server (most desktop
clients).

## Putting it together — sequence per `POST /api/connect`

```
1. issue request → server returns {allowedIPs, disallowedIPs,
                                   disallowedDomains, ...}
2. exclude = server.disallowedIPs[]
3. exclude += [resolve(host) for host in server.disallowedDomains]
4. exclude += [resolve(parse_url(app_api_url).host)]
5. exclude += [peer for peer in detect_active_ssh_sessions()]   # if applicable
6. effective = subtract_cidrs(server.allowedIPs, exclude)
7. write WG config with `AllowedIPs = effective`
8. apply config — `wg syncconf` (hot reload, preferred) or
                  full `wg-quick down + up` (only when DNS/Address
                  changed)
```

Hot reload (no down/up flap) is critical for short TTLs — a daemon that
flaps the interface every refresh is unacceptable in the 5-15 minute
peer TTL range. See `olv-client/linux-client/olv_vpn/wireguard.py::hot_reload`
for the Linux pattern (`wg set private-key` + `ip address replace` +
`wg syncconf`).

## Per-platform notes

### Linux (reference impl: `olv-client/linux-client/`)

- All of the above
- TPM 2.0 for device identity (fall back to PEM file)
- systemd unit auto-refreshes on TTL via daemon

### Windows (planned)

- Killswitch (firewall blocking non-VPN) means the client CAN'T fall back
  to eth0 even with our exclusions — the firewall will drop those packets.
- → For Windows, the exclusion set MUST also be reflected in the firewall
  exception rules, not just in WG `AllowedIPs`. Equivalent flow:
  1. Compute `exclude` set as above.
  2. Set firewall exception: ALLOW outbound TCP/UDP to each IP in `exclude`
     via the physical interface (not VPN tap).
  3. Also subtract from `AllowedIPs` (so kernel routing actually sends
     them via physical interface).
- TPM 2.0 PCR-bound key (Microsoft Platform Crypto Provider)

### macOS / iOS (Apple Network Extension framework)

- `NEPacketTunnelProvider.includedRoutes` ↔ `AllowedIPs`
  `excludedRoutes` ↔ direct exclusions (Apple supports this natively!)
- → simpler than Linux: **don't** subtract from `includedRoutes`; instead
  pass exclusions into `excludedRoutes`. Apple's stack handles the rest.
- Identity key = Secure Enclave EC P-256 (already implemented in
  `olv-client/apple-client/`)
- iOS doesn't host inbound SSH → skip SSH-peer exclusion

### Android

- VpnService `Builder.addRoute()` adds routes to the tunnel. Inverse
  semantics — there's no "exclude" call.
- → Have to compute the effective AllowedIPs (same subtraction algorithm)
  and call `addRoute()` for each piece.
- Identity = StrongBox / Android Keystore EC P-256

## Testing checklist

For each client implementation:

1. **Refresh under route-all**: with `AllowedIPs = 0.0.0.0/0`, server
   TTL = 6 minutes, observe 3 consecutive refreshes complete with
   no flap and no API errors. Refresh request must reach server
   even after server-side peer is evicted.
2. **SSH lock-out (Linux/Windows servers)**: SSH into the box, then
   `connect`. SSH session must survive across the connect AND across
   subsequent refreshes.
3. **Killswitch (Windows)**: enable killswitch, kill tunnel manually,
   confirm refresh still reaches server (because mgmt IP is in
   firewall exception even though AllowedIPs subtracted).
4. **DisallowedDomains rotation** (when phase 2 ships): change
   the domain's A record mid-session, force daemon refresh, confirm
   client picks up the new IP and re-subtracts correctly.
5. **CIDR math**: unit-test the subtraction with edge cases —
   `0.0.0.0/0 − 0.0.0.0/0` (empty), single-IP exclusions, multiple
   overlapping exclusions, IPv6 mixed with IPv4.

## Migration from the old "broad AllowedIPs" model

Older clients ignore `disallowedIPs` / `disallowedDomains` and write the
server's raw `allowedIPs` into the WG config. They'll work but suffer the
chicken-egg under the same conditions. Operationally:

- Server-side: include the client-side fix in your release notes — it's
  the difference between "tunnel auto-recovers" and "user must reboot".
- Server admin: keep `enterprise_settings.disallowed_ips` empty if your
  client fleet hasn't all upgraded yet — old clients can't make use of it
  anyway, and if they DID parse it incorrectly they could break routing.
- Once 100% of your fleet is on a release that respects
  `disallowedIPs[]`, populate it with at least the management server's
  network so admin doesn't need to rely on each client to resolve the
  hostname itself.
