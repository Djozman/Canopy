#import "LTSession.h"

#include <memory>
#include <unordered_map>
#include <vector>
#include <string>
#include <cstdint>

#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/info_hash.hpp>
#include <libtorrent/sha1_hash.hpp>
#include <libtorrent/hex.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/span.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/announce_entry.hpp>
#include <chrono>

namespace lt = libtorrent;

// ---- helpers ---------------------------------------------------------------

static NSString *NSFromStd(const std::string &s) {
    return [NSString stringWithUTF8String:s.c_str()];
}

static std::string StdFromNS(NSString *s) {
    return std::string(s.UTF8String ?: "");
}

/// Stable hex info-hash string. Prefers the v1 hash for compatibility.
static std::string HashKey(const lt::info_hash_t &ih) {
    lt::sha1_hash best = ih.has_v1() ? ih.v1 : lt::sha1_hash(ih.v2.data());
    return lt::aux::to_hex(best.to_string());
}

static LTTorrentState MapState(lt::torrent_status const &st) {
    if (st.errc) return LTTorrentStateError;
    switch (st.state) {
        case lt::torrent_status::checking_resume_data:
            return LTTorrentStateCheckingResumeData;
        case lt::torrent_status::checking_files:
            return LTTorrentStateCheckingFiles;
        case lt::torrent_status::downloading_metadata:
            return LTTorrentStateDownloadingMetadata;
        case lt::torrent_status::downloading:
            return LTTorrentStateDownloading;
        case lt::torrent_status::finished:
            return LTTorrentStateFinished;
        case lt::torrent_status::seeding:
            return LTTorrentStateSeeding;
        default:
            return LTTorrentStateUnknown;
    }
}

// ---- value objects ---------------------------------------------------------

@implementation LTTorrentStats
@end

@implementation LTFileEntry
@end

@implementation LTSessionStats
@end

@implementation LTPeerEntry
@end

@implementation LTTrackerEntry
@end

@implementation LTTorrentDetail
@end

// ---- LTSession -------------------------------------------------------------

@implementation LTSession {
    std::unique_ptr<lt::session> _session;
    std::unordered_map<std::string, lt::torrent_handle> _handles;
    std::string _defaultSavePath;
    std::string _resumeDir;
}

- (instancetype)initWithSavePath:(NSString *)savePath
                      configPath:(NSString *)configPath {
    if ((self = [super init])) {
        _defaultSavePath = StdFromNS(savePath);
        _resumeDir = StdFromNS([configPath stringByAppendingPathComponent:@"resume"]);
    }
    return self;
}

- (void)start {
    lt::settings_pack pack;
    pack.set_str(lt::settings_pack::user_agent, "Canopy/0.1 libtorrent/2.0");
    pack.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:6881,[::]:6881");
    pack.set_int(lt::settings_pack::alert_mask,
                 lt::alert_category::status
                 | lt::alert_category::error
                 | lt::alert_category::storage);
    pack.set_bool(lt::settings_pack::enable_dht, true);
    pack.set_bool(lt::settings_pack::enable_lsd, true);
    pack.set_bool(lt::settings_pack::enable_upnp, true);
    pack.set_bool(lt::settings_pack::enable_natpmp, true);

    lt::session_params params(pack);
    _session = std::make_unique<lt::session>(params);

    [[NSFileManager defaultManager] createDirectoryAtPath:NSFromStd(_resumeDir)
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [self loadPersistedTorrents];
}

- (void)stop {
    if (_session) {
        [self saveResumeData];
        _session.reset();
    }
    _handles.clear();
}

- (lt::torrent_handle)handleFor:(NSString *)infoHash {
    auto it = _handles.find(StdFromNS(infoHash));
    if (it != _handles.end()) return it->second;
    return lt::torrent_handle();
}

// MARK: - Persistence

- (NSString *)resumePathForKey:(const std::string &)key {
    NSString *file = [NSFromStd(key) stringByAppendingPathExtension:@"fastresume"];
    return [NSFromStd(_resumeDir) stringByAppendingPathComponent:file];
}

- (void)writeResume:(const std::vector<char> &)buf forKey:(const std::string &)key {
    NSData *data = [NSData dataWithBytes:buf.data() length:(NSUInteger)buf.size()];
    [data writeToFile:[self resumePathForKey:key] atomically:YES];
}

- (void)deleteResumeForKey:(const std::string &)key {
    [[NSFileManager defaultManager] removeItemAtPath:[self resumePathForKey:key] error:nil];
}

- (void)loadPersistedTorrents {
    if (!_session) return;
    NSString *dir = NSFromStd(_resumeDir);
    NSArray<NSString *> *entries =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *name in entries) {
        if (![name hasSuffix:@".fastresume"]) continue;
        NSString *full = [dir stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:full];
        if (!data || data.length == 0) continue;
        std::vector<char> buf((const char *)data.bytes,
                              (const char *)data.bytes + data.length);
        lt::error_code ec;
        lt::span<const char> sp(buf.data(), (std::ptrdiff_t)buf.size());
        lt::add_torrent_params p = lt::read_resume_data(sp, ec);
        if (ec) continue;
        if (p.save_path.empty()) p.save_path = _defaultSavePath;
        _session->async_add_torrent(std::move(p));
    }
}

// MARK: - Alerts

- (void)processAlerts {
    if (!_session) return;
    std::vector<lt::alert *> alerts;
    _session->pop_alerts(&alerts);
    for (lt::alert *a : alerts) {
        if (auto *at = lt::alert_cast<lt::add_torrent_alert>(a)) {
            if (!at->error && at->handle.is_valid()) {
                _handles[HashKey(at->handle.info_hashes())] = at->handle;
            }
        } else if (auto *rd = lt::alert_cast<lt::save_resume_data_alert>(a)) {
            std::vector<char> buf = lt::write_resume_data_buf(rd->params);
            [self writeResume:buf forKey:HashKey(rd->handle.info_hashes())];
        } else if (auto *mr = lt::alert_cast<lt::metadata_received_alert>(a)) {
            if (mr->handle.is_valid()) {
                mr->handle.save_resume_data(lt::torrent_handle::save_info_dict);
            }
        }
        // save_resume_data_failed_alert / errors are ignored for now.
    }
}

// MARK: - Adding

- (nullable NSString *)addMagnet:(NSString *)magnetURI
                        savePath:(nullable NSString *)savePath
                          paused:(BOOL)paused
                           error:(NSError **)error {
    if (!_session) return nil;
    lt::error_code ec;
    lt::add_torrent_params p = lt::parse_magnet_uri(StdFromNS(magnetURI), ec);
    if (ec) {
        if (error) *error = [NSError errorWithDomain:@"LibtorrentKit" code:ec.value()
            userInfo:@{NSLocalizedDescriptionKey: NSFromStd(ec.message())}];
        return nil;
    }
    p.save_path = savePath ? StdFromNS(savePath) : _defaultSavePath;
    if (paused) p.flags |= lt::torrent_flags::paused;
    else        p.flags &= ~lt::torrent_flags::paused;

    lt::torrent_handle h = _session->add_torrent(std::move(p), ec);
    if (ec || !h.is_valid()) {
        if (error) *error = [NSError errorWithDomain:@"LibtorrentKit" code:ec.value()
            userInfo:@{NSLocalizedDescriptionKey: NSFromStd(ec.message())}];
        return nil;
    }
    std::string key = HashKey(h.info_hashes());
    _handles[key] = h;
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    return NSFromStd(key);
}

- (nullable NSString *)addTorrentFileAtPath:(NSString *)filePath
                                   savePath:(nullable NSString *)savePath
                                     paused:(BOOL)paused
                                      error:(NSError **)error {
    if (!_session) return nil;
    lt::error_code ec;
    auto ti = std::make_shared<lt::torrent_info>(StdFromNS(filePath), ec);
    if (ec) {
        if (error) *error = [NSError errorWithDomain:@"LibtorrentKit" code:ec.value()
            userInfo:@{NSLocalizedDescriptionKey: NSFromStd(ec.message())}];
        return nil;
    }
    lt::add_torrent_params p;
    p.ti = ti;
    p.save_path = savePath ? StdFromNS(savePath) : _defaultSavePath;
    if (paused) p.flags |= lt::torrent_flags::paused;
    else        p.flags &= ~lt::torrent_flags::paused;

    lt::torrent_handle h = _session->add_torrent(std::move(p), ec);
    if (ec || !h.is_valid()) {
        if (error) *error = [NSError errorWithDomain:@"LibtorrentKit" code:ec.value()
            userInfo:@{NSLocalizedDescriptionKey: NSFromStd(ec.message())}];
        return nil;
    }
    std::string key = HashKey(h.info_hashes());
    _handles[key] = h;
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    return NSFromStd(key);
}

// MARK: - Control

- (void)pause:(NSArray<NSString *> *)infoHashes {
    for (NSString *hash in infoHashes) {
        lt::torrent_handle h = [self handleFor:hash];
        if (h.is_valid()) {
            h.unset_flags(lt::torrent_flags::auto_managed);
            h.pause();
        }
    }
}

- (void)resume:(NSArray<NSString *> *)infoHashes {
    for (NSString *hash in infoHashes) {
        lt::torrent_handle h = [self handleFor:hash];
        if (h.is_valid()) {
            h.set_flags(lt::torrent_flags::auto_managed);
            h.resume();
        }
    }
}

- (void)forceRecheck:(NSArray<NSString *> *)infoHashes {
    for (NSString *hash in infoHashes) {
        lt::torrent_handle h = [self handleFor:hash];
        if (h.is_valid()) h.force_recheck();
    }
}

- (void)remove:(NSArray<NSString *> *)infoHashes deleteFiles:(BOOL)deleteFiles {
    for (NSString *hash in infoHashes) {
        std::string key = StdFromNS(hash);
        auto it = _handles.find(key);
        if (it == _handles.end()) continue;
        if (it->second.is_valid()) {
            _session->remove_torrent(it->second,
                deleteFiles ? lt::session::delete_files : lt::remove_flags_t{});
        }
        _handles.erase(it);
        [self deleteResumeForKey:key];
    }
}

- (void)queueTop:(NSArray<NSString *> *)infoHashes {
    for (NSString *hash in infoHashes) { auto h=[self handleFor:hash]; if (h.is_valid()) h.queue_position_top(); }
}
- (void)queueUp:(NSArray<NSString *> *)infoHashes {
    for (NSString *hash in infoHashes) { auto h=[self handleFor:hash]; if (h.is_valid()) h.queue_position_up(); }
}
- (void)queueDown:(NSArray<NSString *> *)infoHashes {
    for (NSString *hash in infoHashes) { auto h=[self handleFor:hash]; if (h.is_valid()) h.queue_position_down(); }
}
- (void)queueBottom:(NSArray<NSString *> *)infoHashes {
    for (NSString *hash in infoHashes) { auto h=[self handleFor:hash]; if (h.is_valid()) h.queue_position_bottom(); }
}

// MARK: - Queries

- (NSArray<LTTorrentStats *> *)torrents {
    [self processAlerts];
    NSMutableArray<LTTorrentStats *> *result = [NSMutableArray array];
    if (!_session) return result;

    for (auto const &kv : _handles) {
        lt::torrent_handle const &h = kv.second;
        if (!h.is_valid()) continue;
        lt::torrent_status st = h.status();

        LTTorrentStats *s = [LTTorrentStats new];
        s.infoHash = NSFromStd(kv.first);
        s.name = NSFromStd(st.name);
        s.savePath = NSFromStd(st.save_path);
        s.totalWanted = st.total_wanted;
        s.totalDone = st.total_done;
        s.progress = st.progress;
        s.downloadRate = st.download_payload_rate;
        s.uploadRate = st.upload_payload_rate;
        s.allTimeDownload = st.all_time_download;
        s.allTimeUpload = st.all_time_upload;
        s.numSeeds = st.num_seeds;
        s.numPeers = st.num_peers - st.num_seeds;
        s.numComplete = st.num_complete;
        s.numIncomplete = st.num_incomplete;
        s.connectionsCount = st.num_connections;
        s.queuePosition = static_cast<int>(static_cast<int>(st.queue_position));
        s.addedTime = st.added_time;
        s.completedTime = st.completed_time;
        s.paused = bool(st.flags & lt::torrent_flags::paused);
        s.hasMetadata = st.has_metadata;
        s.sequentialDownload = bool(st.flags & lt::torrent_flags::sequential_download);
        s.superSeeding = bool(st.flags & lt::torrent_flags::super_seeding);
        s.state = MapState(st);
        if (st.errc) s.errorMessage = NSFromStd(st.errc.message());

        s.ratio = st.all_time_download > 0
            ? (double)st.all_time_upload / (double)st.all_time_download
            : 0.0;

        int64_t remaining = st.total_wanted - st.total_done;
        s.eta = (st.download_payload_rate > 0 && remaining > 0)
            ? remaining / st.download_payload_rate
            : -1;

        [result addObject:s];
    }
    return result;
}

- (LTSessionStats *)sessionStats {
    LTSessionStats *s = [LTSessionStats new];
    int64_t dl = 0, ul = 0, td = 0, tu = 0;
    for (auto const &kv : _handles) {
        if (!kv.second.is_valid()) continue;
        lt::torrent_status st = kv.second.status();
        dl += st.download_payload_rate;
        ul += st.upload_payload_rate;
        td += st.all_time_download;
        tu += st.all_time_upload;
    }
    s.downloadRate = dl;
    s.uploadRate = ul;
    s.totalDownload = td;
    s.totalUpload = tu;
    s.dhtNodes = 0;
    s.isListening = _session ? _session->is_listening() : NO;
    return s;
}

- (NSArray<LTFileEntry *> *)filesFor:(NSString *)infoHash {
    NSMutableArray<LTFileEntry *> *out = [NSMutableArray array];
    lt::torrent_handle h = [self handleFor:infoHash];
    if (!h.is_valid()) return out;
    std::shared_ptr<const lt::torrent_info> ti = h.torrent_file();
    if (!ti) return out;

    lt::file_storage const &fs = ti->files();
    std::vector<lt::download_priority_t> prios = h.get_file_priorities();
    std::vector<std::int64_t> prog;
    h.file_progress(prog);

    int n = fs.num_files();
    for (int i = 0; i < n; ++i) {
        lt::file_index_t idx{i};
        LTFileEntry *e = [LTFileEntry new];
        e.index = i;
        e.path = NSFromStd(fs.file_path(idx));
        e.size = fs.file_size(idx);
        e.downloaded = (i < (int)prog.size()) ? prog[i] : 0;
        e.priority = (i < (int)prios.size())
            ? (int)static_cast<std::uint8_t>(prios[i]) : 4;
        e.progress = e.size > 0 ? (double)e.downloaded / (double)e.size : 0.0;
        [out addObject:e];
    }
    return out;
}

- (void)setFilePriorities:(NSArray<NSNumber *> *)priorities
                      for:(NSString *)infoHash {
    lt::torrent_handle h = [self handleFor:infoHash];
    if (!h.is_valid()) return;
    std::vector<lt::download_priority_t> v;
    v.reserve(priorities.count);
    for (NSNumber *n in priorities) {
        v.push_back(lt::download_priority_t{static_cast<std::uint8_t>(n.intValue)});
    }
    h.prioritize_files(v);
    h.save_resume_data(lt::torrent_handle::save_info_dict
                       | lt::torrent_handle::only_if_modified);
}

// MARK: - Settings / persistence

- (void)setDownloadRateLimit:(int)bytesPerSecond {
    if (!_session) return;
    lt::settings_pack p;
    p.set_int(lt::settings_pack::download_rate_limit, bytesPerSecond);
    _session->apply_settings(p);
}

- (void)setUploadRateLimit:(int)bytesPerSecond {
    if (!_session) return;
    lt::settings_pack p;
    p.set_int(lt::settings_pack::upload_rate_limit, bytesPerSecond);
    _session->apply_settings(p);
}

- (void)setListenPort:(int)port {
    if (!_session) return;
    lt::settings_pack p;
    char buf[64];
    snprintf(buf, sizeof(buf), "0.0.0.0:%d,[::]:%d", port, port);
    p.set_str(lt::settings_pack::listen_interfaces, buf);
    _session->apply_settings(p);
}

- (void)moveStorage:(NSString *)infoHash to:(NSString *)path {
    lt::torrent_handle h = [self handleFor:infoHash];
    if (h.is_valid()) h.move_storage(StdFromNS(path));
}

- (void)setMaxConnections:(int)maxConnections {
    if (!_session) return;
    lt::settings_pack p;
    p.set_int(lt::settings_pack::connections_limit, maxConnections <= 0 ? 200 : maxConnections);
    _session->apply_settings(p);
}

- (void)setMaxUploads:(int)maxUploads {
    if (!_session) return;
    lt::settings_pack p;
    p.set_int(lt::settings_pack::unchoke_slots_limit, maxUploads <= 0 ? -1 : maxUploads);
    _session->apply_settings(p);
}

- (void)setDHTEnabled:(BOOL)dht lsd:(BOOL)lsd upnp:(BOOL)upnp natpmp:(BOOL)natpmp {
    if (!_session) return;
    lt::settings_pack p;
    p.set_bool(lt::settings_pack::enable_dht, dht);
    p.set_bool(lt::settings_pack::enable_lsd, lsd);
    p.set_bool(lt::settings_pack::enable_upnp, upnp);
    p.set_bool(lt::settings_pack::enable_natpmp, natpmp);
    _session->apply_settings(p);
}

- (void)setEncryptionPolicy:(int)policy {
    if (!_session) return;
    lt::settings_pack p;
    int enc, level;
    switch (policy) {
        case 1: // forced
            enc = lt::settings_pack::pe_forced; level = lt::settings_pack::pe_rc4; break;
        case 2: // disabled
            enc = lt::settings_pack::pe_disabled; level = lt::settings_pack::pe_both; break;
        default: // enabled / prefer
            enc = lt::settings_pack::pe_enabled; level = lt::settings_pack::pe_both; break;
    }
    p.set_int(lt::settings_pack::out_enc_policy, enc);
    p.set_int(lt::settings_pack::in_enc_policy, enc);
    p.set_int(lt::settings_pack::allowed_enc_level, level);
    _session->apply_settings(p);
}

- (void)setQueueLimitsDownloads:(int)maxDownloads seeds:(int)maxSeeds total:(int)maxTotal {
    if (!_session) return;
    lt::settings_pack p;
    p.set_int(lt::settings_pack::active_downloads, maxDownloads);
    p.set_int(lt::settings_pack::active_seeds, maxSeeds);
    p.set_int(lt::settings_pack::active_limit, maxTotal);
    _session->apply_settings(p);
}

- (void)setSequentialDownload:(BOOL)enabled for:(NSArray<NSString *> *)infoHashes {
    for (NSString *hh in infoHashes) {
        lt::torrent_handle h = [self handleFor:hh];
        if (!h.is_valid()) continue;
        if (enabled) h.set_flags(lt::torrent_flags::sequential_download);
        else         h.unset_flags(lt::torrent_flags::sequential_download);
    }
}

- (void)setSuperSeeding:(BOOL)enabled for:(NSArray<NSString *> *)infoHashes {
    for (NSString *hh in infoHashes) {
        lt::torrent_handle h = [self handleFor:hh];
        if (!h.is_valid()) continue;
        if (enabled) h.set_flags(lt::torrent_flags::super_seeding);
        else         h.unset_flags(lt::torrent_flags::super_seeding);
    }
}

- (void)setFirstLastPiecePriority:(BOOL)enabled for:(NSArray<NSString *> *)infoHashes {
    for (NSString *hh in infoHashes) {
        lt::torrent_handle h = [self handleFor:hh];
        if (!h.is_valid()) continue;
        std::shared_ptr<const lt::torrent_info> ti = h.torrent_file();
        if (!ti) continue;
        int n = ti->num_pieces();
        if (n <= 0) continue;
        lt::download_priority_t pr = enabled ? lt::top_priority : lt::default_priority;
        h.piece_priority(lt::piece_index_t{0}, pr);
        h.piece_priority(lt::piece_index_t{n - 1}, pr);
    }
}

- (void)saveResumeData {
    if (!_session) return;
    for (auto const &kv : _handles) {
        if (!kv.second.is_valid()) continue;
        // only_if_modified makes libtorrent post a save_resume_data_alert only
        // when there is something new to persist, so we don't need the
        // version-specific torrent_status::need_save_resume(_data) flag.
        kv.second.save_resume_data(lt::torrent_handle::save_info_dict
                                   | lt::torrent_handle::only_if_modified);
    }
    [self processAlerts];
}


// MARK: - Detail queries (Peers / Trackers / General)

- (NSArray<LTPeerEntry *> *)peersFor:(NSString *)infoHash {
    NSMutableArray<LTPeerEntry *> *out = [NSMutableArray array];
    lt::torrent_handle h = [self handleFor:infoHash];
    if (!h.is_valid()) return out;
    std::vector<lt::peer_info> peers;
    h.get_peer_info(peers);
    for (lt::peer_info const &pi : peers) {
        LTPeerEntry *e = [LTPeerEntry new];
        std::string ip = pi.ip.address().to_string();
        char addr[128];
        snprintf(addr, sizeof(addr), "%s:%d", ip.c_str(), (int)pi.ip.port());
        e.address = NSFromStd(addr);
        e.client = NSFromStd(pi.client);
        e.progress = pi.progress;
        e.downSpeed = pi.payload_down_speed;
        e.upSpeed = pi.payload_up_speed;
        e.downloaded = pi.total_download;
        e.uploaded = pi.total_upload;
        e.isSeed = bool(pi.flags & lt::peer_info::seed);
        e.connection = (pi.flags & lt::peer_info::utp_socket) ? @"uTP" : @"BT";
        std::string f;
        if ((pi.flags & lt::peer_info::interesting) && !(pi.flags & lt::peer_info::remote_choked)) f += 'D';
        if ((pi.flags & lt::peer_info::remote_interested) && !(pi.flags & lt::peer_info::choked)) f += 'U';
        if (pi.flags & lt::peer_info::supports_extensions) f += 'E';
        if (pi.flags & lt::peer_info::local_connection) f += 'L';
        if (pi.source & lt::peer_info::dht) f += 'H';
        if (pi.source & lt::peer_info::pex) f += 'X';
        if (pi.flags & lt::peer_info::utp_socket) f += 'P';
        if (pi.flags & (lt::peer_info::rc4_encrypted | lt::peer_info::plaintext_encrypted)) f += 'e';
        e.flags = NSFromStd(f);
        [out addObject:e];
    }
    return out;
}

- (NSArray<LTTrackerEntry *> *)trackersFor:(NSString *)infoHash {
    NSMutableArray<LTTrackerEntry *> *out = [NSMutableArray array];
    lt::torrent_handle h = [self handleFor:infoHash];
    if (!h.is_valid()) return out;
    std::vector<lt::announce_entry> trackers = h.trackers();
    for (lt::announce_entry const &ae : trackers) {
        LTTrackerEntry *e = [LTTrackerEntry new];
        e.url = NSFromStd(ae.url);
        e.tier = ae.tier;
        int seeds = -1, leeches = -1, downloaded = -1;
        bool anyWorking = false, anyUpdating = false, anyError = false;
        std::string message;
        for (lt::announce_endpoint const &ep : ae.endpoints) {
            for (lt::announce_infohash const &ai : ep.info_hashes) {
                if (ai.updating) anyUpdating = true;
                if (ai.last_error) anyError = true;
                else if (ai.start_sent) anyWorking = true;
                if (!ai.message.empty()) message = ai.message;
                else if (ai.last_error && message.empty()) message = ai.last_error.message();
                if (ai.scrape_complete > seeds) seeds = ai.scrape_complete;
                if (ai.scrape_incomplete > leeches) leeches = ai.scrape_incomplete;
                if (ai.scrape_downloaded > downloaded) downloaded = ai.scrape_downloaded;
            }
        }
        if (anyUpdating) e.status = @"Updating";
        else if (anyWorking) e.status = @"Working";
        else if (anyError) e.status = @"Not working";
        else e.status = @"Not contacted yet";
        e.message = NSFromStd(message);
        e.numSeeds = seeds;
        e.numLeeches = leeches;
        e.numDownloaded = downloaded;
        [out addObject:e];
    }
    return out;
}

- (nullable LTTorrentDetail *)detailFor:(NSString *)infoHash {
    lt::torrent_handle h = [self handleFor:infoHash];
    if (!h.is_valid()) return nil;
    lt::torrent_status st = h.status();
    LTTorrentDetail *d = [LTTorrentDetail new];
    d.infoHash = infoHash;
    d.name = NSFromStd(st.name);
    d.savePath = NSFromStd(st.save_path);
    d.progress = st.progress;
    d.piecesHave = st.num_pieces;
    d.addedTime = st.added_time;
    d.completedTime = st.completed_time;
    d.lastSeenComplete = st.last_seen_complete;
    d.distributedCopies = st.distributed_copies;
    d.totalDownload = st.all_time_download;
    d.totalUpload = st.all_time_upload;
    d.sessionDownload = st.total_payload_download;
    d.sessionUpload = st.total_payload_upload;
    d.downloadRate = st.download_payload_rate;
    d.uploadRate = st.upload_payload_rate;
    d.numConnections = st.num_connections;
    d.ratio = st.all_time_download > 0 ? (double)st.all_time_upload / (double)st.all_time_download : 0.0;
    d.activeDuration = (int64_t)std::chrono::duration_cast<std::chrono::seconds>(st.active_duration).count();
    d.seedingDuration = (int64_t)std::chrono::duration_cast<std::chrono::seconds>(st.seeding_duration).count();
    d.finishedDuration = (int64_t)std::chrono::duration_cast<std::chrono::seconds>(st.finished_duration).count();
    std::shared_ptr<const lt::torrent_info> ti = h.torrent_file();
    if (ti) {
        d.comment = NSFromStd(ti->comment());
        d.creator = NSFromStd(ti->creator());
        d.creationDate = (int64_t)ti->creation_date();
        d.totalSize = ti->total_size();
        d.pieceLength = ti->piece_length();
        d.numPieces = ti->num_pieces();
    } else {
        d.comment = @"";
        d.creator = @"";
    }
    return d;
}

@end
