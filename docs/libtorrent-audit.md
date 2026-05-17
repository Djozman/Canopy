# Canopy Engine — libtorrent Audit Report

**Reference:** [arvidn/libtorrent](https://github.com/arvidn/libtorrent) tag `v2.0.12`
**Commit SHA:** `740a0b9aeabe00e762cc0efe4a0f27593db2550b`
**Date:** 2026-05-14

This report compares Canopy's from-scratch Swift BitTorrent engine
(`Sources/CanopyEngine/`) against libtorrent RC_2_0 (v2.0.12), the de-facto
reference implementation. Every divergence cites a specific libtorrent symbol
and Canopy location. Severity ratings: **correctness** > **interop** >
**efficiency** > **security** > **cosmetic**.

---

## 1. Peer Wire + MSE

### 1.1 Inbound MSE: IA bytes consumed and discarded (correctness)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `MSEHandshake.swift` — `inbound()`, path where `iaLen > 0` | `bt_peer_connection.cpp` — `state_t::read_pe_ia` handler (line 3264) |
| **Difference** | When receiving an inbound MSE connection from a peer that sends non-zero `ia_len` (libtorrent sends `ia_len = 68` containing the BT handshake), Canopy reads and decrypts those bytes during MSE handshake, then **discards** them. The returned `EncryptedStream` starts reading fresh from the socket, losing the already-consumed handshake bytes. | libtorrent cuts the receive buffer at position 0 with `m_recv_buffer.cut(0, 20)`, preserving the IA bytes in the buffer, then transitions to `read_protocol_identifier` to parse the handshake from those bytes. |
| **Severity** | **correctness** — inbound MSE connections from libtorrent peers fail to complete the BT handshake. |

### 1.2 No BEP 6 Fast Extension (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `PeerMessage.swift` — enum has no `suggest`, `haveAll`, `haveNone`, `reject`, `allowedFast` cases | `bt_peer_connection.hpp` — message IDs `msg_suggest_piece = 0xd`, `msg_have_all`, `msg_have_none`, `msg_reject_request`, `msg_allowed_fast` |
| **Difference** | Canopy implements only BEP 3 messages. No FAST extension handshake bit, no suggest/allowed_fast/reject dispatch. | libtorrent fully implements BEP 6 with `write_allow_fast()`, `write_suggest()`, `incoming_reject_request()`, and reserved bit `*(ptr + 7) \|= 0x04`. |
| **Severity** | **interop** — Canopy cannot use FAST-optimized piece availability signaling. |

### 1.3 Choke-on-interest vs defer-to-choke-round (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DownloadCoordinator.swift` — `.interested` handler immediately inserts peer into `unchokedPeers` and sends `.unchoke` if under slot limit | `bt_peer_connection.cpp` — `on_interested()` (line 926) only calls `incoming_interested()` (sets flag); unchoke decisions happen in periodic `maybe_unchoke_this_peer()` (line 3628) |
| **Difference** | Canopy unchokes every interested peer immediately if slots are available, bypassing the tit-for-tat rate sorting that happens at the choke round. | libtorrent defers all unchoke decisions to the choke algorithm timer. This ensures the top uploaders always get slots. |
| **Severity** | **efficiency** — Canopy may unchoke slow peers immediately while faster peers wait for the next choke round. |

### 1.4 MSE/plaintext protocol order: plaintext-first vs MSE-first with cache (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `PeerConnection.swift` — `doConnect()`, `.preferred` tries plaintext first, then reconnects with MSE | `bt_peer_connection.cpp` — `on_connected()` (line 240), checks `pi->pe_support` flag |
| **Difference** | Canopy always tries plaintext first on every connection, reopening TCP if it fails. | libtorrent caches `pe_support` per peer (line 245-271): MSE-first for untested peers, plaintext-first after MSE fails, persisted across reconnects. Converges to correct protocol after ≤1 reconnect per peer. |
| **Severity** | **efficiency** — Canopy wastes TCP reconnects on MSE-requiring peers with no memory of prior outcomes. |

### 1.5 Outbound MSE `ia_len = 0` vs libtorrent's `ia_len = 68` (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `MSEHandshake.swift` — `iaLenBE = 0` | `bt_peer_connection.cpp` — `handshake_len = 68`, written as `aux::write_uint16(handshake_len, write_buf)` (line 724) |
| **Difference** | Canopy sends the BT handshake as a separate encrypted message after MSE completes. | libtorrent embeds the 68-byte BT handshake as initial application data within the MSE pe3 encrypted payload. |
| **Severity** | **interop** — most peers handle both, but strict implementations expecting IA bytes may misbehave. |

### 1.6 Extension handshake sent after bitfield (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DownloadCoordinator.swift` — in `handlePeer`, order: bitfield → interested → extension handshake | `bt_peer_connection.cpp` — `read_peer_id` handler (line 3589): extension handshake → then bitfield → then dht_port |
| **Difference** | Canopy sends the extension handshake last, after bitfield and interested. BEP 10 says it "should be sent immediately after the standard BitTorrent handshake." | libtorrent sends the extension handshake first. |
| **Severity** | **efficiency** — adds ~1 RTT latency before extension messages (e.g., magnet metadata) can begin. |

### 1.7 Extension handshake missing fields (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `PeerExtensions.swift` — `buildExtensionHandshake()` includes only `m` and `metadata_size` | `bt_peer_connection.cpp` — `write_extensions()` (line 2417) includes `m`, `p` (port), `v` (client), `yourip`, `reqq`, `upload_only`, `complete_ago`, `metadata_size`, plus plugin fields |
| **Difference** | Canopy omits listen port, client version, observed IP, request-queue limit, and upload-only status. | libtorrent sends all extension handshake fields defined by BEP 10. |
| **Severity** | **interop** — missing `reqq` may cause peers to over-queue requests; missing `v` makes Canopy unidentifiable; missing `yourip` prevents NAT traversal hints. |

### 1.8 PEX missing flags and IPv6 support (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `PeerExtensions.swift` — `buildPEXMessage()` only includes `added` and `dropped` compact blobs | `ut_pex.cpp` — includes `added`, `added.f`, `dropped`, `added6`, `dropped6`, `added6.f`, `dropped6.f` |
| **Difference** | Canopy lacks per-peer capability flags (encryption, seed, uTP, holepunch) and entire IPv6 PEX support. | libtorrent's PEX messages carry full capability flags and dual-stack peer lists. |
| **Severity** | **interop** — recipients cannot distinguish seeders from leechers or IPv6 from IPv4 peers via PEX. |

### 1.9 DHT port messages silently ignored (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DownloadCoordinator.swift` — `.port` message falls through to `default: break` | `bt_peer_connection.cpp` — `on_dht_port()` (line 1392) processes the port and reciprocates |
| **Difference** | Canopy discards all DHT port messages. | libtorrent extracts the DHT listen port, updates peer info, and sends its own DHT port in response. |
| **Severity** | **interop** — lost DHT peer discovery optimization through the BT wire protocol. |

### 1.10 DH768 private key: 160-bit vs 768-bit (security)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DH768.swift` — `generateKeypair()` uses 20 bytes (160 bits) | `pe_crypto.cpp` — `random_key` is 96 bytes (768 bits) |
| **Difference** | Canopy uses the minimum recommended DH private key size. | libtorrent uses the full modulus-sized key. |
| **Severity** | **security** — both provide adequate security; the 160-bit key has ~2^80 security vs libtorrent's ~2^384. MSE is obfuscation only, so practical impact is negligible. |

### 1.11 Metadata reject: immediate retry vs 1-minute backoff (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `MagnetSession.swift` — on reject, immediately requests next piece | `ut_metadata.cpp` — `msg_t::dont_have` handler (line 392) sets `m_request_limit = time_now() + minutes(1)` |
| **Difference** | Canopy retries metadata requests instantly after a reject with no backoff. | libtorrent applies a 1-minute cooldown after `dont_have` responses. |
| **Severity** | **efficiency** — Canopy may flood peers that already indicated they don't have the data. |

---

## 2. DHT

### 2.1 Sequential transaction IDs — predictable (security)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `Message.swift` — `makeTransactionID()` increments a `UInt16` counter | `rpc_manager.cpp` — `std::uint16_t const tid = std::uint16_t(random(0xffff))` (line 483) |
| **Difference** | Canopy generates sequential, predictable TX IDs. An attacker observing a few queries can guess the next TX ID and spoof responses. | libtorrent uses randomly generated TX IDs. |
| **Severity** | **security** — weakens BEP 5's anti-spoofing mechanism. |

### 2.2 No per-IP KRPC rate limiting (security)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DHTSession.swift` — `handleIncoming()` processes every message unconditionally | `dos_blocker.cpp` — `dos_blocker::incoming()` (line 54) rate-limits per IP: ≥50 messages/10s → 5-minute block |
| **Difference** | Canopy has zero per-IP rate limiting on DHT queries. A single IP can flood CPU with arbitrary messages. | libtorrent's `dos_blocker` tracks up to 20 IPs and blocks abusers for 5 minutes. |
| **Severity** | **security** — vulnerable to DHT amplification and exhaustion attacks. |

### 2.3 DHT token: not bound to info_hash, 20-byte vs 4-byte (correctness)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DHTSession.swift` — `generateToken(for ip:)` uses `SHA1(secret + compactIP)`, returns 20 bytes | `node.cpp` — `generate_token(addr, info_hash)` (line 205) uses `SHA1(address + secret + info_hash)`, returns 4 bytes |
| **Difference** | Canopy tokens are (a) 20 bytes instead of 4, (b) not bound to `info_hash`, (c) use binary IP instead of string IP. libtorrent rejects tokens not exactly 4 bytes, so interop is broken. Without info_hash binding, a token from torrent A can be replayed for torrent B. | libtorrent uses 4-byte tokens scoped to a specific info_hash plus address. |
| **Severity** | **correctness** — Canopy tokens are rejected by libtorrent nodes; the write-token anti-abuse mechanism is weakened. |

### 2.4 No BEP 42 IP-derived node ID validation (security)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `NodeID.swift` — `NodeID.random()` is pure random, no IP input | `node_id.cpp` — `generate_id_impl()` (line 85) + `verify_id()` (line 183) |
| **Difference** | Canopy generates cryptographically random node IDs with no relation to IP. Any Sybil attacker can place arbitrarily many nodes at chosen positions in the keyspace. | libtorrent implements BEP 42: node IDs are derived from external IP via bitmasking + random `r` + CRC32C, and optionally validates incoming IDs (`dht_enforce_node_id`). |
| **Severity** | **security** — enables trivial Sybil attacks against the routing table. |

### 2.5 Unbounded peer cache (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DHTSession.swift` — `peerCache` has 30-min TTL but no max size | `dht_storage.cpp` — `dht_max_peers` (default 500) hard cap; exceeded → no write token issued |
| **Difference** | Canopy's peer cache grows without bound per info-hash. | libtorrent caps at 500 peers and withholds tokens from new announcers when full. |
| **Severity** | **efficiency** — unbounded memory growth; lacks the write-token backpressure that protects nodes from overloading. |

### 2.6 Simplified routing table eviction (security)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `RoutingTable.swift` — `insert()` uses LRU with optional pinger | `routing_table.cpp` — `add_node_impl()` (line 624) has replacement cache, IP deduplication, prefix spreading, RTT tracking, Sybil detection |
| **Difference** | Canopy lacks: IP dedup (multiple nodes from same IP allowed), replacement cache (overflow nodes not stored), prefix spreading (no ID diversity guarantee in buckets), Sybil detection (same-IP/changed-ID not flagged). | libtorrent's routing table has comprehensive IP dedup, a replacement cache per bucket, prefix-based node spreading for fast lookups, RTT-biased eviction, and malicious node detection. |
| **Severity** | **security** — vulnerable to routing table poisoning; suboptimal lookup performance. |

### 2.7 Batch refresh vs incremental tick (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DHTSession.swift` — every 900s, iterates all buckets calling `findNode` | `node.cpp` — `tick()` per 5s interval, refreshes one node per tick |
| **Difference** | Canopy's refresh is bursty (all buckets refreshed simultaneously every 15 min). | libtorrent refreshes incrementally, spreading load evenly and using cheaper `ping` for full buckets and `get_peers` for non-full ones. |
| **Severity** | **efficiency** — burst traffic every 15 minutes; always uses more expensive `find_node`. |

### 2.8 Missing BEP 43 read-only support (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | DHTSession.swift — no `ro` flag handling | `node.cpp` — `dht_read_only` setting drops queries; sets `ro=1` on outgoing |
| **Difference** | Canopy neither sets nor parses the `ro` key from BEP 43. A read-only node should silently drop queries, but Canopy responds. | libtorrent fully supports BEP 43 read-only mode. |
| **Severity** | **interop** — violates BEP 43 convention. |

### 2.9 No `want` list support for dual-stack lookups (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DHTSession.swift` — `find_node` handler always returns `nodes` key | `node.cpp` — `write_nodes_entries()` supports `want` list (`"n4"` vs `"n6"`) |
| **Difference** | Canopy always returns IPv4 compact nodes only. | libtorrent supports BEP 32 `want` list to return IPv4 (`nodes`) and/or IPv6 (`nodes6`) as requested. |
| **Severity** | **interop** — IPv6-only nodes cannot build routing tables through Canopy. |

### 2.10 No `implied_port` on outgoing announces (correctness)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `Message.swift` — `buildAnnouncePeer()` sends `port` but not `implied_port` | `node.cpp` — `announce_fun` sets `implied_port` when flag is present |
| **Difference** | Canopy parses `implied_port` on incoming but never sends it on outgoing announces. | libtorrent includes `implied_port` when the announce flags include it. |
| **Severity** | **correctness** — incomplete BEP 5 support. Nodes behind NAT relying on implied_port cannot use Canopy for announces. |

---

## 3. Trackers

### 3.1 HTTP announce missing parameters (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `TrackerAnnounce.swift` — `queryString()` sends only 9 params | `http_tracker_connection.cpp` — `start()` (line 123) sends ~16 params |
| **Difference** | Canopy omits `key` (per-torrent DHT key for NAT traversal), `supportcrypto=1`, `no_peer_id=1`, `corrupt`, `redundant`, `trackerid` (echo-back), `ip` (explicit announce IP), `ipv4`/`ipv6`. | libtorrent sends all standard HTTP tracker parameters per BEP 3 + BEP 7. |
| **Severity** | **interop** — private trackers may reject announces missing `key` and `trackerid`. Missing `supportcrypto` means trackers don't know Canopy supports encryption. |

### 3.2 UDP tracker never caches connection_id (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `UDPTracker.swift` — new `NWConnection` + `getConnectionID()` every announce | `udp_tracker_connection.cpp` — `start_announce()` checks static `std::map<address, cache>` with 60s TTL |
| **Difference** | Canopy performs the BEP 15 connect handshake before every single announce. | libtorrent caches the connection_id per tracker address for 60 seconds, skipping the handshake on subsequent announces. |
| **Severity** | **efficiency** — one wasted round-trip (~RTT + 5s timeout worst case) per announce cycle. |

### 3.3 No scrape support (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | Absent — no scrape implementation | `http_tracker_connection.cpp` + `udp_tracker_connection.cpp` — full HTTP and UDP scrape |
| **Difference** | Canopy cannot query seeder/leecher/download counts via scrape. | libtorrent supports HTTP scrape (replaces "announce" with "scrape" in URL) and UDP scrape (action=2). |
| **Severity** | **interop** — missing foundational feature; user cannot see swarm size without downloading. |

### 3.4 Tracker ID parsed but never echoed back (correctness)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `HTTPTracker.swift` — parses `tracker id`; `TrackerAnnounce.swift` — never sends it back | `announce_entry.hpp` — `trackerid` stored per entry; `http_tracker_connection.cpp` — sends `&trackerid=` |
| **Difference** | Canopy parses and stores `tracker id` but never sends it on subsequent announces. | libtorrent persists and re-sends `trackerid` on every HTTP announce per BEP 3. |
| **Severity** | **correctness** — private trackers may require trackerid echo-back. |

### 3.5 Missing `min_announce_interval` floor (correctness)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `TrackerSession.swift` — `forceAnnounce` floor is 30s or tracker's `min_interval` | `settings_pack.cpp` — `min_announce_interval = 300` (5 minutes); `torrent.cpp` — `max(resp.interval, min_announce_interval)` |
| **Difference** | Canopy has no hard floor on announce interval — will use whatever the tracker returns, potentially as low as 1 second. | libtorrent enforces a 5-minute minimum regardless of tracker response, preventing tracker bans for over-announcing. |
| **Severity** | **correctness** — can get banned by trackers that return very short intervals. |

### 3.6 UDP announce sends numwant for stopped events (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `TrackerAnnounce.swift` + `UDPTracker.swift` — `numwant=200` always | `torrent.cpp` — `req.num_want = (req.event == stopped) ? 0 : ...` |
| **Difference** | Canopy requests 200 peers even for stopped events. | libtorrent sets `num_want = 0` for stopped announces. |
| **Severity** | **efficiency** — wastes bandwidth for both client and tracker during shutdown. |

### 3.7 No User-Agent header on HTTP announces (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `HTTPTracker.swift` — no `User-Agent` header set on URLRequest | `http_tracker_connection.cpp` — sends `user_agent` setting (default `"libtorrent/" LIBTORRENT_VERSION`) |
| **Difference** | Canopy does not identify itself to HTTP trackers. | libtorrent always sends a User-Agent string. |
| **Severity** | **interop** — some private trackers whitelist user agents and may reject or throttle unknown clients. |

### 3.8 No BEP 41 URL extension in UDP announces (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `UDPTracker.swift` — `encodeAnnounce()` omits URL path extension | `udp_tracker_connection.cpp` — appends type=2 length-prefixed request string after port |
| **Difference** | Canopy's UDP announce packet lacks the BEP 41 path extension. | libtorrent appends the URL path (e.g., `/announce`) to enable path-based routing. |
| **Severity** | **interop** — fails with UDP trackers that use path-based multi-torrent routing. |

### 3.9 UDP tracker IPv6 peer parsing broken (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `UDPTracker.swift` — `decodeResponse()` unconditionally calls `parseCompactPeers()` (6-byte stride) | `udp_tracker_connection.cpp` — checks `aux::is_v6(m_target)` to determine stride (18 vs 6) |
| **Difference** | Canopy's UDP path has no IPv6 awareness. Peer data from IPv6 trackers is parsed with 6-byte strides, producing garbage. | libtorrent detects the tracker endpoint family and parses peer data accordingly. |
| **Severity** | **interop** — cannot receive IPv6 peers from UDP trackers. |

### 3.10 Tier failover: no `fail_limit`, different backoff (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `TrackerSession.swift` — exponential backoff capped at 60s, no permanent exclusion | `announce_entry.cpp` — `fail_limit` field with quadratic backoff, permanent exclusion after configurable failures |
| **Difference** | Canopy retries a dead tracker every ~60s forever with no permanent exclusion. Backoff is exponential (1, 2, 4, 8, 16, 32, 60, 60…). | libtorrent has configurable `fail_limit` per entry, quadratic backoff ramping to hours, and BEP 12 `announce_to_all_tiers` control. |
| **Severity** | **interop** — dead trackers accumulate overhead forever. |

---

## 4. Piece Picker, Disk I/O, Parser, Coordinator

### 4.1 Path traversal vulnerability (security)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `TorrentParser.swift` — path components joined with `/`, no `..` stripping; `DiskMapper.swift` — `root + entry.path` concatenation | `torrent_info.cpp` — `sanitize_append_path_element()` (line 176): strips `/` and `\` from each component, filters Unicode bidirectional-override chars, rejects all-dot components |
| **Difference** | Canopy performs zero path sanitization. A malicious torrent with `"path": ["..", "..", ".ssh", "authorized_keys"]` writes outside the save directory. | libtorrent structurally prevents path traversal by stripping separators from components and rejecting `..` components. |
| **Severity** | **security** — arbitrary file write outside save directory. |

### 4.2 No fsync after piece writes (correctness)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DownloadCoordinator.swift` — `writePieceToDisk()` calls `fh.seek` + `fh.write` only | `mmap_storage.cpp` — `handle->page_out()` evicts dirty pages; posix backend calls `part_file::flush_metadata()` |
| **Difference** | Canopy never synchronizes written data to disk. A crash before OS flushes results in on-disk corruption with no metadata to detect it. | libtorrent sets `flush_piece` flag for `disable_os_cache` mode and flushes metadata regularly. |
| **Severity** | **correctness** — data loss window under crash; resume data may indicate pieces as complete that are corrupted on disk. |

### 4.3 Endgame: no per-block duplicate cancellation (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DownloadCoordinator.swift` — endgame entry at >95%; cancels duplicates only after whole piece assembles | `torrent.cpp` — `cancel_block(block)` (line 1463) called immediately when a block is written to disk |
| **Difference** | During endgame, Canopy sends duplicate requests to multiple peers but only cancels after the full piece is hash-verified, not when individual blocks arrive. | libtorrent cancels duplicate block requests immediately when each block is written, minimizing redundant transfers. |
| **Severity** | **efficiency** — endgame wastes bandwidth on already-received blocks. |

### 4.4 Hash-failure: 3-strike count vs trust-points + IP ban (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DownloadCoordinator.swift` — `peerHashFailures` increments per failure, bans at 3 | `torrent.cpp` — dual mechanism: `trust_points` (ban at -7) + `hashfails` (ban at 3); IP-filter ban; parole mode |
| **Difference** | Canopy assigns blame equally to all contributors of a failed piece, even if the corrupt block came from one peer. No IP-level ban. | libtorrent has nuanced blame: `known_bad_peer` only set when peer is sole contributor; also bans the IP across the session. Parole mode isolates suspected peers. |
| **Severity** | **efficiency** — Canopy may unfairly ban good peers in multi-peer hash failures. |

### 4.5 Synchronous upload disk reads (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DownloadCoordinator.swift` — `readBlockFromDisk()` calls `fh.seek` + `fh.read` synchronously on the actor | `mmap_disk_io.cpp` — `async_read()` posts jobs to disk thread pool |
| **Difference** | Canopy's upload reads block the `DownloadCoordinator` actor. Under I/O pressure, all peer message processing for the torrent stalls. | libtorrent queues disk reads to a dedicated thread pool with async callbacks. |
| **Severity** | **efficiency** — synchronous I/O on the coordinator actor reduces upload throughput and responsiveness. |

### 4.6 No disk read cache (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | Absent — no read cache | `settings_pack.cpp` — `use_read_cache`, `volatile_read_cache`, `guided_read_cache`, `read_cache_line_size` |
| **Difference** | Canopy reads every requested block directly from disk, causing redundant I/O for popular pieces requested by multiple peers. | libtorrent provides a configurable read cache including volatile and guided-cache policies. |
| **Severity** | **efficiency** — during seeding, popular pieces generate redundant disk reads. |

### 4.7 Piece assembly in memory before disk write (correctness)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `PieceManager.swift` — `downloadedBlocks` dictionary holds all blocks in memory; `tryAssemble` assembles full piece → verify → write to disk | `torrent.cpp` — `async_write()` writes each block to disk as it arrives (line 1453) |
| **Difference** | Canopy holds all blocks of a piece in memory until assembly and verification, then writes. A crash loses all unfinalized pieces. | libtorrent writes each block to disk (mmap or part-file) immediately on arrival, enabling partial-piece resume. |
| **Severity** | **correctness** — crash loses all in-progress pieces; resume data is coarse (piece-level only, not block-level). |

### 4.8 Piece selection: rarest-first only vs multi-strategy (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DownloadCoordinator.swift` — `rarestPiece()` uses `pieceFrequency` only | `piece_picker.cpp` — `pick_pieces()` (line 1976) uses 7 picker options: rarest_first, reverse, on_parole, prioritize_partials, sequential, piece_extent_affinity, align_expanded_pieces |
| **Difference** | Canopy has a single strategy: rarest-first. | libtorrent has 7 strategies including sequential download (for streaming), on-parole mode (for suspected peers), piece-extent affinity (for HDD locality), and 8 priority levels. |
| **Severity** | **efficiency** — missing sequential download prevents in-order playback; missing on-parole reduces ability to isolate bad peers. |

### 4.9 Stall detection: 60s piece timeout vs 20s block timeout (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DownloadCoordinator.swift` — `pieceAssignedAt.filter { now.timeIntervalSince > 60 }` | `settings_pack.cpp` — `piece_timeout = 20`, `request_timeout = 60` |
| **Difference** | Canopy times out entire piece assignments at 60s. | libtorrent times out individual block requests at 20s (`piece_timeout`) plus a 60s overall request timeout. |
| **Severity** | **efficiency** — Canopy tolerates slow peers 3× longer, delaying completion. |

### 4.10 Resume data: JSON array of piece indices vs full bitfield + unfinished_pieces (interop)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DownloadCoordinator.swift` — `saveResumeData()` stores `completedPieces` as JSON array | `torrent.cpp` — `write_resume_data()` stores bitfield, per-piece block bitmasks, file priorities, uploaded/downloaded bytes, peer lists, tracker lists |
| **Difference** | Canopy's resume data is a simple JSON array of completed piece indices. No partial-piece block tracking, no file priorities, no byte counters. | libtorrent's resume data includes per-piece block-level bitmasks (for partial piece resumption), file priorities, peer lists, and byte counters. |
| **Severity** | **interop** — restarting Canopy re-downloads all partially-completed pieces from scratch. Resume data is incompatible with other clients. |

### 4.11 Rate limiting: sleep-based vs token bucket (efficiency)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `DownloadCoordinator.swift` — `throttleDownload`/`throttleUpload` use per-second byte counter + `Task.sleep` | `bandwidth_manager.cpp` — `request_bandwidth()` uses token-bucket algorithm with quota distribution |
| **Difference** | Canopy's rate limiter sleeps the current async task when limits are exceeded, which blocks the message loop for that peer. 1-second granularity with bursts. | libtorrent uses a proper token-bucket algorithm with quota distribution across peers, per-channel limits, and prioritization. |
| **Severity** | **efficiency** — Canopy's approach is coarser-grained and blocks message processing under rate limits. |

### 4.12 Info hash computation: manual range-scan vs bdecode `data_section` (correctness)

| | Canopy | libtorrent |
|---|---|---|
| **Site** | `TorrentParser.swift` — `infoRange(in:)` manually traverses raw bencode bytes to find `info` dict range; falls back to re-encode | `torrent_info.cpp` — uses bdecode library's `data_section()` method which records byte range during parsing |
| **Difference** | Canopy's manual range-finding scans for the string "info" in raw bencode and could match it inside a nested string value. Falls back to re-encoding, which may produce different bytes for non-canonical input. | libtorrent's bdecode library records the exact byte offset and length of the `info` subtree during parsing. |
| **Severity** | **correctness** — the re-encode fallback path could produce a different info_hash than the original bytes for non-canonical torrents. |

---

## 5. Phase-1 Checklist Verification

The Phase 1 audit raised several suspicions. Here's what libtorrent source confirms or refutes:

| Phase-1 Claim | Verdict | Evidence |
|---|---|---|
| Peer: no BEP 6 Fast Extension | **Confirmed** | libtorrent `bt_peer_connection.hpp` has `msg_suggest_piece = 0xd` etc. |
| Peer: choke unchokes 8 peers instead of 4 | **Refuted** | libtorrent `unchoke_slots_limit = 8`; Canopy's 8+1 now matches |
| Peer: interested peers unchoked immediately | **Confirmed** | libtorrent `on_interested()` only sets flag; unchoke is timer-driven |
| Peer: piece timeout 60s vs libtorrent's 30s | **Refuted** | libtorrent `piece_timeout = 20` (not 30); Canopy's 60s is still 3× |
| Peer: plaintext→MSE fallback closes and reopens TCP | **Confirmed** | Canopy opens new TCP; libtorrent caches `pe_support` per peer |
| DHT: 16-bit counter TX IDs vs random | **Confirmed** | libtorrent `rpc_manager.cpp:483` uses `random(0xffff)` |
| DHT: no BEP 42 IP-derived node ID | **Confirmed** | libtorrent `node_id.cpp` has `generate_id_impl` + `verify_id` |
| DHT: no BEP 43 read-only flag | **Confirmed** | libtorrent `node.cpp` checks `dht_read_only` setting |
| DHT: no KRPC rate limit | **Confirmed** | libtorrent `dos_blocker.cpp` has per-IP rate limiting |
| DHT: unbounded peerCache | **Confirmed** | libtorrent `dht_max_peers = 500` |
| DHT: k=8 in both | **Confirmed match** | Both use k=8; libtorrent additionally has extended routing table |
| Trackers: HTTP omits `key` and `supportcrypto` | **Confirmed** | libtorrent sends both |
| Trackers: UDP never caches connection_id | **Confirmed** | libtorrent caches per address for 60s |
| Trackers: no scrape | **Confirmed** | libtorrent supports HTTP + UDP scrape |
| Trackers: tier failover incomplete | **Confirmed** | libtorrent has `fail_limit`, quadratic backoff, `announce_to_all_tiers` |
| Piece: no fsync | **Confirmed** | libtorrent uses `page_out()` and `flush_metadata()` |
| Piece: path traversal | **Confirmed** | libtorrent `sanitize_append_path_element` |
| Piece: endgame no duplicate cancellation | **Confirmed** | libtorrent `cancel_block(block)` on write |
| Piece: 3-strike hash ban | **Confirmed** | libtorrent uses trust_points + max_failcount + IP ban |
| Piece: upload reads synchronous | **Confirmed** | libtorrent uses `async_read()` to disk thread pool |
| Piece: no read cache | **Confirmed** | libtorrent has read cache settings (deprecated but present) |

---

## 6. Prioritised Fix List

### Correctness bugs (must-fix — wrong on-wire behaviour or data loss)

1. **DHT token: 20-byte, not bound to info_hash** (`DHTSession.swift`)
   — Libtorrent uses 4-byte tokens scoped to `info_hash`. Canopy tokens are rejected by libtorrent nodes. Make tokens 4 bytes and include `info_hash` in the hash input.

2. **Inbound MSE: IA bytes consumed and discarded** (`MSEHandshake.swift`)
   — When a libtorrent peer initiates MSE to Canopy (sending ia_len=68 with BT handshake), Canopy reads and discards those bytes. The subsequent handshake read fails. Preserve IA bytes and feed them into the handshake parser.

3. **Path traversal** (`TorrentParser.swift`)
   — No path sanitization. Strip `/` and `\` from each path component, reject all-dot components, and filter Unicode bidirectional-override characters.

4. **Tracker ID never echoed back** (`TrackerAnnounce.swift`)
   — Parsed but not re-sent. Private trackers may reject announces without it.

5. **Missing `min_announce_interval` floor** (`TrackerSession.swift`)
   — No 300-second (5-minute) minimum. A tracker returning `interval=1` causes 1-second re-announce, risking a ban.

6. **No fsync after piece writes** (`DownloadCoordinator.swift`)
   — Data loss on crash. Call `FileHandle.synchronize()` after piece writes or use `synchronizeFile()`.

7. **Piece assembly in memory before disk write** (`PieceManager.swift`)
   — Crash loses all in-progress pieces. Write blocks to disk as they arrive.

### Interop gaps

8. **No BEP 6 Fast Extension** (`PeerMessage.swift`)
   — Add suggest, have_all, have_none, reject, allowed_fast message types and set FAST reserved bit.

9. **Extension handshake missing fields** (`PeerExtensions.swift`)
   — Add `v` (client), `reqq` (500), `p` (listen port), `yourip`, `upload_only` fields.

10. **PEX missing flags and IPv6** (`PeerExtensions.swift`)
    — Add `added.f` per-peer flags; add `added6`/`dropped6` compact IPv6 support.

11. **DHT port messages silently ignored** (`DownloadCoordinator.swift`)
    — Handle `.port` messages to update DHT peer port and reciprocate.

12. **DHT: no `want` list support** (`DHTSession.swift`)
    — Support `want` list to return IPv6 nodes (`nodes6` key).

13. **DHT: no `implied_port` on outgoing announces** (`Message.swift`)
    — Pass through `implied_port` flag on outgoing announce_peer.

14. **UDP tracker: no connection_id caching** (`UDPTracker.swift`)
    — Cache connection_id per address with 60s TTL.

15. **UDP tracker: no BEP 41 URL extension** (`UDPTracker.swift`)
    — Append URL path as length-prefixed type-2 extension after port field.

16. **UDP tracker: IPv6 peer parsing broken** (`UDPTracker.swift`)
    — Detect tracker endpoint family to determine peer stride (6 vs 18 bytes).

17. **No User-Agent on HTTP tracker requests** (`HTTPTracker.swift`)
    — Set User-Agent header (e.g., `Canopy/1.0`).

18. **Tracker sends numwant for stopped events** (`TrackerAnnounce.swift`)
    — Set `numwant=0` when event is `.stopped`.

### Algorithmic divergences

19. **Choke-on-interest bypasses tit-for-tat** (`DownloadCoordinator.swift`)
    — Defer unchoke decisions to the periodic choke round instead of unchoking immediately on interest.

20. **Stall detection: 60s piece vs 20s block** (`DownloadCoordinator.swift`)
    — Reduce piece-assignment timeout from 60s to 20s or add per-block timeouts.

21. **Endgame: no per-block duplicate cancellation** (`DownloadCoordinator.swift`)
    — Cancel duplicate block requests immediately when a block arrives, not after whole piece assembly.

22. **Hash-failure: no nuanced blame** (`DownloadCoordinator.swift`)
    — Only increment hash-failure count for the sole contributor; track trust points.

### Security / DoS

23. **DHT: no per-IP rate limiting** (`DHTSession.swift`)
    — Add per-IP rate limiter (≥50 messages/10s → 5-minute block).

24. **DHT: predictable transaction IDs** (`Message.swift`)
    — Use `SecRandomCopyBytes` for random TX IDs instead of sequential counter.

25. **DHT: no BEP 42 node ID validation** (`NodeID.swift`)
    — Implement BEP 42 IP-derived node ID generation and optional validation.

### Minor / Efficiency

- DHT: reduce secret rotation from 600s to 300s
- DHT: incremental refresh instead of batch every 15 min
- DHT: cap `peerCache` at 500 per info_hash
- DHT: routing table IP dedup and replacement cache
- Upload disk reads: dispatch to background queue
- Add disk read cache for popular pieces
- Resume data: add block-level partial-piece tracking
- Rate limiting: replace sleep-based with token bucket
- Info hash: use re-encode instead of manual bencode scanning for robustness
- Extension handshake order: send before bitfield per BEP 10

---

*All libtorrent citations verified against tag v2.0.12 (commit `740a0b9`). Canopy citations confirmed against current working tree HEAD.*
