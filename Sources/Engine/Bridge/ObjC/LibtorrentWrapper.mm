#import "LibtorrentWrapper.h"

#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/announce_entry.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/load_torrent.hpp>

#include <vector>
#include <string>
#include <sstream>
#include <algorithm>
#include <fstream>
#include <filesystem>
#include <chrono>

namespace lt = libtorrent;

static NSString *LTString(std::string const& value) {
    NSString *result = [[NSString alloc] initWithBytes:value.data()
                                                length:value.size()
                                              encoding:NSUTF8StringEncoding];
    return result ?: @"";
}

static std::string hashString(lt::info_hash_t const& hashes) {
    std::ostringstream stream;
    if (hashes.has_v1()) stream << hashes.v1;
    else if (hashes.has_v2()) stream << hashes.v2;
    return stream.str();
}

// ─── LTTorrentHandle ───────────────────────────────────────────────────────

@interface LTTorrentHandle ()
- (lt::torrent_handle)cppHandle;
- (instancetype)initWithHandle:(lt::torrent_handle)handle;
- (void)refresh;
@end

@implementation LTTorrentHandle {
    lt::torrent_handle _handle;
    lt::torrent_status _cachedStatus;
    BOOL _cached;
}

- (lt::torrent_handle)cppHandle { return _handle; }

- (instancetype)initWithHandle:(lt::torrent_handle)handle {
    if (self = [super init]) {
        _handle = handle;
        _cached = NO;
    }
    return self;
}

- (void)refresh {
    if (_handle.is_valid()) {
        _cachedStatus = _handle.status();
        _cached = YES;
    }
}

static int mapState(lt::torrent_status::state_t s) {
    switch (s) {
        case lt::torrent_status::checking_files:       return 0;
        case lt::torrent_status::downloading_metadata:  return 1;
        case lt::torrent_status::downloading:           return 2;
        case lt::torrent_status::finished:              return 3;
        case lt::torrent_status::seeding:               return 4;
        case lt::torrent_status::checking_resume_data:  return 6;
        default:                                         return 2;
    }
}

- (NSString *)name {
    if (!_cached) [self refresh];
    if (!_handle.is_valid()) return @"";
    auto ti = _handle.torrent_file();
    if (!ti) return @"";
    return LTString(ti->name());
}

- (float)progress {
    if (!_cached) [self refresh];
    return _cachedStatus.progress;
}

- (int64_t)downloadRate {
    if (!_cached) [self refresh];
    return _cachedStatus.download_rate;
}

- (int64_t)uploadRate {
    if (!_cached) [self refresh];
    return _cachedStatus.upload_rate;
}

- (int64_t)totalDone {
    if (!_cached) [self refresh];
    return _cachedStatus.total_done;
}

- (int64_t)totalSize {
    if (!_cached) [self refresh];
    auto tf = _cachedStatus.torrent_file.lock();
    if (tf) return tf->total_size();
    return _cachedStatus.total_wanted;
}

- (int64_t)totalUploaded {
    if (!_cached) [self refresh];
    return _cachedStatus.total_upload;
}

- (int)numSeeds {
    if (!_cached) [self refresh];
    return _cachedStatus.num_seeds;
}

- (int)numPeers {
    if (!_cached) [self refresh];
    return _cachedStatus.num_peers;
}

- (int64_t)etaSeconds {
    if (!_cached) [self refresh];
    int64_t remaining = [self totalSize] - _cachedStatus.total_done;
    return (_cachedStatus.download_rate > 0) ? (remaining / _cachedStatus.download_rate) : -1;
}

- (NSString *)infoHash {
    if (!_cached) [self refresh];
    auto const &ih = _cachedStatus.info_hashes;
    if (ih.has_v1()) {
        std::ostringstream ss;
        ss << ih.v1;
        return [NSString stringWithUTF8String:ss.str().c_str()];
    } else if (ih.has_v2()) {
        std::ostringstream ss;
        ss << ih.v2;
        return [NSString stringWithUTF8String:ss.str().c_str()];
    }
    return @"";
}

- (NSString *)savePath {
    if (!_cached) [self refresh];
    return LTString(_cachedStatus.save_path);
}

- (LTTorrentState)state {
    if (!_cached) [self refresh];
    return (LTTorrentState)mapState(_cachedStatus.state);
}

- (BOOL)paused {
    if (!_cached) [self refresh];
    return static_cast<bool>(_cachedStatus.flags & lt::torrent_flags::paused);
}

- (NSString * _Nullable)errorMessage {
    if (!_cached) [self refresh];
    if (!_cachedStatus.errc) return nil;
    return LTString(_cachedStatus.errc.message());
}

- (BOOL)hasMetadata {
    if (!_cached) [self refresh];
    return _cachedStatus.has_metadata;
}

- (void)pause      { _handle.pause(); }
- (void)resume     { _handle.resume(); }
- (void)recheck    { _handle.force_recheck(); }
- (void)reannounce { _handle.force_reannounce(); }
- (void)setDownloadLimit:(int)limit { _handle.set_download_limit(limit); }
- (void)setUploadLimit:(int)limit   { _handle.set_upload_limit(limit); }
- (BOOL)sequentialDownload {
    if (!_cached) [self refresh];
    return static_cast<bool>(_cachedStatus.flags & lt::torrent_flags::sequential_download);
}
- (void)setSequentialDownload:(BOOL)sequential {
    if (sequential) {
        _handle.set_flags(lt::torrent_flags::sequential_download);
    } else {
        _handle.unset_flags(lt::torrent_flags::sequential_download);
    }
}

// ─── File tree ────────────────────────────────────────────────────────────

- (int)fileCount {
    auto ti = _handle.torrent_file();
    return ti ? ti->num_files() : 0;
}

- (NSArray<NSNumber *> *)fileProgressAll {
    int count = [self fileCount];
    if (count <= 0) return @[];
    std::vector<int64_t> v;
    _handle.file_progress(v, lt::torrent_handle::piece_granularity);
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:count];
    int n = std::min((int)v.size(), count);
    for (int i = 0; i < n; i++) {
        [a addObject:@(v[i])];
    }
    for (int i = n; i < count; i++) {
        [a addObject:@(0)];
    }
    return a;
}

- (nullable NSString *)filePathAtIndex:(int)index
                                  size:(int64_t *)outSize
                              priority:(int *)outPriority {
    auto ti = _handle.torrent_file();
    if (!ti || index < 0 || index >= ti->num_files()) return nil;
    auto const& fs = ti->layout();
    if (outSize)     *outSize     = fs.file_size(lt::file_index_t{index});
    if (outPriority) {
        *outPriority = static_cast<std::uint8_t>(
            _handle.file_priority(lt::file_index_t{index}));
    }
    return LTString(fs.file_path(lt::file_index_t{index}));
}

- (void)setFilePriority:(int)priority atIndex:(int)index {
    _handle.file_priority(lt::file_index_t{index},
                          lt::download_priority_t{(std::uint8_t)priority});
}

- (int)trackerCount {
    try { return (int)_handle.trackers().size(); } catch (...) { return 0; }
}

- (NSDictionary *)trackerInfoAtIndex:(int)index {
    try {
        auto trackers = _handle.trackers();
        if (index < 0 || index >= (int)trackers.size()) return nil;
        auto &t = trackers[index];
        return @{
            @"url": LTString(t.url),
            @"tier": @(t.tier),
            @"working": @(t.verified),
            @"verified": @(t.verified),
        };
    } catch (...) { return nil; }
}

- (int)peerCount {
    try {
        std::vector<lt::peer_info> peers;
        _handle.get_peer_info(peers);
        return (int)peers.size();
    } catch (...) { return 0; }
}

- (NSDictionary *)peerInfoAtIndex:(int)index {
    try {
        std::vector<lt::peer_info> peers;
        _handle.get_peer_info(peers);
        if (index < 0 || index >= (int)peers.size()) return nil;
        auto &p = peers[index];
        auto const endpoint = p.remote_endpoint();
        return @{
            @"ip": LTString(endpoint.address().to_string()),
            @"port": @(endpoint.port()),
            @"client": LTString(p.client),
            @"progress": @(p.progress),
            @"downSpeed": @(p.down_speed),
            @"upSpeed": @(p.up_speed),
            @"seeder": @(p.flags & lt::peer_info::seed ? YES : NO),
            @"encrypted": @(p.flags & lt::peer_info::rc4_encrypted ? YES : NO),
        };
    } catch (...) { return nil; }
}

// ─── Piece map ────────────────────────────────────────────────────────────

- (int)pieceCount {
    if (!_handle.is_valid()) return 0;
    return (int)_handle.status().pieces.size();
}

- (int64_t)pieceSize {
    auto ti = _handle.torrent_file();
    return ti ? ti->piece_length() : 0;
}

- (NSData *)pieceDownloadedBits {
    if (!_handle.is_valid()) return [NSData data];
    auto status = _handle.status();
    int count = (int)status.pieces.size();
    if (count <= 0) return [NSData data];
    NSMutableData *data = [NSMutableData dataWithLength:count];
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    for (int i = 0; i < count; i++) {
        bytes[i] = status.pieces.get_bit(lt::piece_index_t{i}) ? 1 : 0;
    }
    return data;
}

@end

// ─── LibtorrentSession ─────────────────────────────────────────────────────

@interface LibtorrentSession () {
    lt::session *_session;
    NSMutableArray<LTTorrentHandle *> *_handles;
    NSString *_resumeDataDir;
    int _listenPort;
}
@end

@implementation LibtorrentSession

@synthesize resumeDataDir = _resumeDataDir;

- (instancetype)init {
    if (self = [super init]) {
        lt::settings_pack sp;
        sp.set_bool(lt::settings_pack::enable_dht,    true);
        sp.set_bool(lt::settings_pack::enable_lsd,    true);
        sp.set_bool(lt::settings_pack::enable_upnp,   true);
        sp.set_bool(lt::settings_pack::enable_natpmp, true);
        sp.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:6881,[::]:6881");
        sp.set_int(lt::settings_pack::alert_mask,
                   lt::alert_category::status   |
                   lt::alert_category::error    |
                   lt::alert_category::storage  |
                   lt::alert_category::tracker);
        _listenPort = 6881;
        _session = new lt::session(std::move(sp));
        _handles = [NSMutableArray new];
    }
    return self;
}

- (void)dealloc {
    delete _session;
}

- (nullable LTTorrentHandle *)addTorrentFile:(NSString *)path
                                    savePath:(NSString *)savePath
                                  priorities:(nullable NSArray<NSNumber *> *)priorities
                                renamedFiles:(nullable NSArray<NSString *> *)renamedFiles {
    try {
        // The single-argument overload is shared by Homebrew's libtorrent
        // 2.0 and 2.1 headers. Parse failures throw and are handled below.
        lt::add_torrent_params p = lt::load_torrent_file(
            std::string(path.UTF8String));
        if (!p.ti) return nil;
        auto ti = p.ti;
        p.save_path = std::string(savePath.UTF8String);
        if (p.save_path.empty()) return nil;
        std::filesystem::create_directories(p.save_path);

        if (priorities && (int)priorities.count == ti->num_files()) {
            p.file_priorities.resize(ti->num_files());
            for (int i = 0; i < (int)priorities.count; i++) {
                p.file_priorities[i] = lt::download_priority_t{
                    (std::uint8_t)[priorities[i] intValue]
                };
            }
        }

        if (renamedFiles) {
            for (NSUInteger i = 0; i < renamedFiles.count; i++) {
                NSString *newPath = renamedFiles[i];
                if (newPath.length == 0) continue;
                p.renamed_files[lt::file_index_t{ (int)i }] =
                    std::string(newPath.UTF8String);
            }
        }

        lt::torrent_handle h = _session->add_torrent(p);
        if (!h.is_valid()) return nil;

        auto *wrapper = [[LTTorrentHandle alloc] initWithHandle:h];
        [_handles addObject:wrapper];
        return wrapper;
    } catch (...) { return nil; }
}

- (nullable NSArray<LTFileEntry *> *)parseFileList:(NSString *)torrentPath {
    try {
        lt::add_torrent_params params = lt::load_torrent_file(
            std::string(torrentPath.UTF8String));
        if (!params.ti) return nil;

        NSMutableArray *result = [NSMutableArray array];
        const auto &fs = params.ti->layout();
        for (int i = 0; i < fs.num_files(); i++) {
            LTFileEntry *e = [[LTFileEntry alloc] init];
            e.path  = LTString(fs.file_path(lt::file_index_t{i}));
            e.size  = fs.file_size(lt::file_index_t{i});
            e.index = i;
            [result addObject:e];
        }
        return result;
    } catch (...) { return nil; }
}

- (nullable LTTorrentHandle *)addMagnetForMetadata:(NSString *)uri {
    try {
        auto params = lt::parse_magnet_uri(std::string(uri.UTF8String));
        // Paused torrents never announce, so they cannot fetch magnet metadata.
        // upload_mode prevents payload pieces while still allowing metadata traffic.
        params.flags |= lt::torrent_flags::upload_mode;
        params.save_path = std::filesystem::temp_directory_path().string();
        lt::torrent_handle h = _session->add_torrent(params);
        if (!h.is_valid()) return nil;
        auto *wrapper = [[LTTorrentHandle alloc] initWithHandle:h];
        // NOT added to _handles — hidden from UI until commitMagnet
        return wrapper;
    } catch (...) { return nil; }
}

- (void)commitMagnet:(LTTorrentHandle *)handle
            savePath:(NSString *)savePath
          priorities:(nullable NSArray<NSNumber *> *)priorities
        renamedFiles:(nullable NSArray<NSString *> *)renamedFiles {
    auto h = [handle cppHandle];
    if (!h.is_valid()) {
        NSLog(@"[Canopy-ObjC] commitMagnet: handle invalid");
        return;
    }
    NSLog(@"[Canopy-ObjC] commitMagnet: savePath=%s handles_before=%lu",
          savePath.UTF8String, (unsigned long)_handles.count);

    std::string destination(savePath.UTF8String);
    if (destination.empty()) return;
    try { std::filesystem::create_directories(destination); }
    catch (...) { return; }
    h.move_storage(destination);

    if (renamedFiles) {
        for (NSUInteger i = 0; i < renamedFiles.count; i++) {
            NSString *newPath = renamedFiles[i];
            if (newPath.length == 0) continue;
            h.rename_file(lt::file_index_t{ (int)i },
                          std::string(newPath.UTF8String));
        }
    }

    if (priorities && priorities.count > 0) {
        std::vector<lt::download_priority_t> prios;
        prios.reserve(priorities.count);
        for (NSNumber *n in priorities) {
            prios.push_back(lt::download_priority_t{(std::uint8_t)n.intValue});
        }
        h.prioritize_files(prios);
    }

    h.unset_flags(lt::torrent_flags::paused | lt::torrent_flags::upload_mode);
    h.set_flags(lt::torrent_flags::auto_managed);
    h.resume();

    if (![_handles containsObject:handle]) {
        [_handles addObject:handle];
        NSLog(@"[Canopy-ObjC] commitMagnet: added to _handles (now %lu)",
              (unsigned long)_handles.count);
    } else {
        NSLog(@"[Canopy-ObjC] commitMagnet: handle already in _handles");
    }
}

- (void)cancelMagnet:(LTTorrentHandle *)handle {
    auto h = [handle cppHandle];
    if (h.is_valid()) {
        _session->remove_torrent(h);
    }
    [_handles removeObject:handle];
}

- (void)setAlertNotify:(void (^)(void))block {
    id copied = [block copy];
    _session->set_alert_notify([copied] {
        dispatch_async(dispatch_get_main_queue(), ^{
            ((void (^)(void))copied)();
        });
    });
}

- (nullable LTTorrentHandle *)addMagnetURI:(NSString *)magnetURI
                                  savePath:(NSString *)savePath {
    try {
        lt::add_torrent_params p = lt::parse_magnet_uri(std::string(magnetURI.UTF8String));
        p.save_path = std::string(savePath.UTF8String);
        if (p.save_path.empty()) return nil;
        std::filesystem::create_directories(p.save_path);

        lt::torrent_handle h = _session->add_torrent(p);
        if (!h.is_valid()) return nil;

        auto *wrapper = [[LTTorrentHandle alloc] initWithHandle:h];
        [_handles addObject:wrapper];
        return wrapper;
    } catch (...) { return nil; }
}

- (NSArray<LTTorrentHandle *> *)allTorrents {
    NSIndexSet *invalid = [_handles indexesOfObjectsPassingTest:^BOOL(LTTorrentHandle *wrapper, NSUInteger idx, BOOL *stop) {
        return ![wrapper cppHandle].is_valid();
    }];
    if (invalid.count) [_handles removeObjectsAtIndexes:invalid];
    for (LTTorrentHandle *h in _handles) [h refresh];
    return [_handles copy];
}

- (void)removeTorrent:(LTTorrentHandle *)handle deleteFiles:(BOOL)deleteFiles {
    NSLog(@"[Canopy-ObjC] removeTorrent called with deleteFiles=%d", deleteFiles);
    auto flags = deleteFiles
        ? (lt::session::delete_partfile | lt::session::delete_files)
        : lt::remove_flags_t{};
    _session->remove_torrent([handle cppHandle], flags);
    [_handles removeObject:handle];
}
- (void)pause  { _session->pause(); }
- (void)resume { _session->resume(); }

- (void)saveResumeDataAll {
    auto statuses = _session->get_torrent_status(
        [](const lt::torrent_status&){ return true; });
    for (auto &st : statuses) {
        if (st.handle.is_valid() && st.has_metadata) {
            st.handle.save_resume_data(lt::torrent_handle::save_info_dict);
        }
    }
}

- (void)saveResumeDataAllAndWait {
    NSString *dir = _resumeDataDir;
    if (!dir || dir.length == 0) return;
    try { std::filesystem::create_directories(std::string(dir.UTF8String)); }
    catch (...) { return; }

    auto statuses = _session->get_torrent_status(
        [](const lt::torrent_status&){ return true; });
    int remaining = 0;
    for (auto &status : statuses) {
        if (status.handle.is_valid() && status.has_metadata) {
            status.handle.save_resume_data(lt::torrent_handle::save_info_dict);
            remaining++;
        }
    }

    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (remaining > 0 && std::chrono::steady_clock::now() < deadline) {
        _session->wait_for_alert(lt::milliseconds(500));
        std::vector<lt::alert *> alerts;
        _session->pop_alerts(&alerts);
        for (auto *alert : alerts) {
            if (auto *saved = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
                std::vector<char> buffer = lt::write_resume_data_buf(saved->params);
                std::string hash = hashString(saved->handle.status().info_hashes);
                if (!buffer.empty() && !hash.empty()) {
                    std::string finalPath = std::string(dir.UTF8String) + "/" + hash + ".resume";
                    std::string tempPath = finalPath + ".tmp";
                    std::ofstream out(tempPath, std::ios::binary | std::ios::trunc);
                    out.write(buffer.data(), (std::streamsize)buffer.size());
                    out.close();
                    if (out) std::filesystem::rename(tempPath, finalPath);
                    else std::filesystem::remove(tempPath);
                }
                remaining--;
            } else if (lt::alert_cast<lt::save_resume_data_failed_alert>(alert)) {
                remaining--;
            }
        }
    }
}

- (void)loadResumeTorrentsFromDir:(NSString *)dir {
    if (!dir || dir.length == 0) return;
    std::string dirStr(dir.UTF8String);
    try {
        if (!std::filesystem::exists(dirStr)) return;
        for (auto const &entry : std::filesystem::directory_iterator(dirStr)) {
            if (!entry.is_regular_file()) continue;
            std::string path = entry.path().string();
            if (path.size() < 7 || path.substr(path.size() - 7) != ".resume") continue;
            std::ifstream in(path, std::ios::binary | std::ios::ate);
            if (!in) continue;
            size_t size = in.tellg();
            in.seekg(0);
            std::vector<char> buf(size);
            in.read(buf.data(), size);
            lt::error_code ec;
            lt::add_torrent_params params = lt::read_resume_data(buf, ec);
            if (ec) continue;
            lt::torrent_handle h = _session->add_torrent(params);
            if (!h.is_valid()) continue;
            auto *wrapper = [[LTTorrentHandle alloc] initWithHandle:h];
            [_handles addObject:wrapper];
        }
    } catch (...) {}
}

- (void)popAlerts:(void (^)(LTAlertType type, LTTorrentHandle * _Nullable handle, NSString *message, int errorCode))callback {
    if (!callback) return;
    std::vector<lt::alert *> alerts;
    _session->pop_alerts(&alerts);
    for (auto *a : alerts) {
        LTAlertType type = LTAlertTypeUnknown;
        LTTorrentHandle * _Nullable wrapper = nil;
        int errorCode = 0;
        NSString *removedHashMsg = nil;

        if      (auto *x = lt::alert_cast<lt::add_torrent_alert>(a))      {
            type = LTAlertTypeTorrentAdded;
            wrapper = [[LTTorrentHandle alloc] initWithHandle:x->handle];
        }
        else if (auto *x = lt::alert_cast<lt::torrent_removed_alert>(a))  {
            type = LTAlertTypeTorrentRemoved;
            removedHashMsg = LTString(hashString(x->info_hashes));
        }
        else if (auto *x = lt::alert_cast<lt::torrent_finished_alert>(a)) {
            type = LTAlertTypeTorrentFinished;
            wrapper = [[LTTorrentHandle alloc] initWithHandle:x->handle];
        }
        else if (auto *x = lt::alert_cast<lt::torrent_error_alert>(a))    {
            type = LTAlertTypeTorrentError;
            wrapper = [[LTTorrentHandle alloc] initWithHandle:x->handle];
            errorCode = x->error.value();
        }
        else if (auto *x = lt::alert_cast<lt::tracker_error_alert>(a))    {
            type = LTAlertTypeTrackerError;
            wrapper = [[LTTorrentHandle alloc] initWithHandle:x->handle];
            errorCode = x->error.value();
        }
        else if (auto *x = lt::alert_cast<lt::save_resume_data_alert>(a)) {
            type = LTAlertTypeSaveResumeData;
            wrapper = [[LTTorrentHandle alloc] initWithHandle:x->handle];
            NSString *dir = _resumeDataDir;
            std::string hash = hashString(x->handle.status().info_hashes);
            if (dir.length > 0 && !hash.empty()) {
                try {
                    std::filesystem::create_directories(std::string(dir.UTF8String));
                    std::vector<char> buffer = lt::write_resume_data_buf(x->params);
                    std::string finalPath = std::string(dir.UTF8String) + "/" + hash + ".resume";
                    std::string tempPath = finalPath + ".tmp";
                    std::ofstream out(tempPath, std::ios::binary | std::ios::trunc);
                    out.write(buffer.data(), (std::streamsize)buffer.size());
                    out.close();
                    if (out) std::filesystem::rename(tempPath, finalPath);
                    else std::filesystem::remove(tempPath);
                } catch (...) {}
            }
        }
        else if (auto *x = lt::alert_cast<lt::state_changed_alert>(a))    {
            type = LTAlertTypeStateChanged;
            wrapper = [[LTTorrentHandle alloc] initWithHandle:x->handle];
        }
        else if (auto *x = lt::alert_cast<lt::metadata_received_alert>(a)){
            type = LTAlertTypeMetadataReceived;
            wrapper = [[LTTorrentHandle alloc] initWithHandle:x->handle];
        }

        NSString *msg;
        if (type == LTAlertTypeTorrentRemoved) {
            msg = removedHashMsg ?: @"";
        } else {
            msg = LTString(a->message());
        }
        callback(type, wrapper, msg, errorCode);
    }
}

- (void)getSettingsWithDownloadRate:(int *)downloadRate
                         uploadRate:(int *)uploadRate
                    activeDownloads:(int *)activeDownloads
                        activeSeeds:(int *)activeSeeds
                        activeLimit:(int *)activeLimit
                          enableDHT:(BOOL *)enableDHT
                          enableLSD:(BOOL *)enableLSD
                         enableUPnP:(BOOL *)enableUPnP
                       enableNatPMP:(BOOL *)enableNatPMP
                      anonymousMode:(BOOL *)anonymousMode
                         listenPort:(int *)listenPort {
    auto sp = _session->get_settings();
    if (downloadRate)     *downloadRate     = sp.get_int(lt::settings_pack::download_rate_limit);
    if (uploadRate)       *uploadRate       = sp.get_int(lt::settings_pack::upload_rate_limit);
    if (activeDownloads)  *activeDownloads  = sp.get_int(lt::settings_pack::active_downloads);
    if (activeSeeds)      *activeSeeds      = sp.get_int(lt::settings_pack::active_seeds);
    if (activeLimit)      *activeLimit      = sp.get_int(lt::settings_pack::active_limit);
    if (enableDHT)        *enableDHT        = sp.get_bool(lt::settings_pack::enable_dht);
    if (enableLSD)        *enableLSD        = sp.get_bool(lt::settings_pack::enable_lsd);
    if (enableUPnP)       *enableUPnP       = sp.get_bool(lt::settings_pack::enable_upnp);
    if (enableNatPMP)     *enableNatPMP     = sp.get_bool(lt::settings_pack::enable_natpmp);
    if (anonymousMode)    *anonymousMode    = sp.get_bool(lt::settings_pack::anonymous_mode);
    if (listenPort)       *listenPort       = _listenPort;
}

- (void)applySettingsWithDownloadRate:(int)downloadRate
                           uploadRate:(int)uploadRate
                      activeDownloads:(int)activeDownloads
                          activeSeeds:(int)activeSeeds
                          activeLimit:(int)activeLimit
                            enableDHT:(BOOL)enableDHT
                            enableLSD:(BOOL)enableLSD
                           enableUPnP:(BOOL)enableUPnP
                         enableNatPMP:(BOOL)enableNatPMP
                        anonymousMode:(BOOL)anonymousMode
                           listenPort:(int)listenPort {
    lt::settings_pack sp;
    sp.set_int(lt::settings_pack::download_rate_limit, downloadRate);
    sp.set_int(lt::settings_pack::upload_rate_limit,   uploadRate);
    sp.set_int(lt::settings_pack::active_downloads,    activeDownloads);
    sp.set_int(lt::settings_pack::active_seeds,        activeSeeds);
    sp.set_int(lt::settings_pack::active_limit,        activeLimit);
    sp.set_bool(lt::settings_pack::enable_dht,         enableDHT);
    sp.set_bool(lt::settings_pack::enable_lsd,         enableLSD);
    sp.set_bool(lt::settings_pack::enable_upnp,        enableUPnP);
    sp.set_bool(lt::settings_pack::enable_natpmp,      enableNatPMP);
    sp.set_bool(lt::settings_pack::anonymous_mode,     anonymousMode);
    sp.set_str(lt::settings_pack::listen_interfaces,
               std::string("0.0.0.0:") + std::to_string(listenPort));
    _listenPort = listenPort;
    _session->apply_settings(sp);
}

- (void)applySettingsDictionary:(NSDictionary<NSString *, NSNumber *> *)settings {
    int download = MAX(0, settings[@"downloadRate"].intValue);
    int upload = MAX(0, settings[@"uploadRate"].intValue);
    int activeDownloads = MAX(1, settings[@"activeDownloads"].intValue);
    int activeSeeds = MAX(1, settings[@"activeSeeds"].intValue);
    int activeLimit = MAX(activeDownloads + activeSeeds, settings[@"activeLimit"].intValue);
    int port = MIN(65535, MAX(1, settings[@"listenPort"].intValue));
    [self applySettingsWithDownloadRate:download
                            uploadRate:upload
                       activeDownloads:activeDownloads
                           activeSeeds:activeSeeds
                           activeLimit:activeLimit
                             enableDHT:settings[@"enableDHT"].boolValue
                             enableLSD:settings[@"enableLSD"].boolValue
                            enableUPnP:settings[@"enableUPnP"].boolValue
                          enableNatPMP:settings[@"enableNatPMP"].boolValue
                         anonymousMode:settings[@"anonymousMode"].boolValue
                            listenPort:port];
}

@end

@implementation LTFileEntry
@end
