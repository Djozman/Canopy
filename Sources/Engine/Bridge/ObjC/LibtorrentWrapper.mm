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
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <vector>
#include <string>
#include <cstring>
#include <sstream>
#include <fstream>
#include <memory>

namespace lt = libtorrent;

// ─── LTTorrentHandle ───────────────────────────────────────────────────────

@interface LTTorrentHandle ()
@property lt::torrent_handle handle;
- (instancetype)initWithHandle:(lt::torrent_handle)handle;
- (void)refresh;
@end

@implementation LTTorrentHandle {
    lt::torrent_status _cachedStatus;
    BOOL _cached;
}

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
        case lt::torrent_status::allocating:            return 5;
        case lt::torrent_status::checking_resume_data:  return 6;
        default:                                         return 2;
    }
}

- (NSString *)name {
    if (!_cached) [self refresh];
    if (!_handle.is_valid()) return @"";
    auto ti = _handle.torrent_file();
    if (!ti) return @"";
    return [NSString stringWithUTF8String:ti->name().c_str()];
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
    return tf ? tf->total_size() : 0;
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
    return [NSString stringWithUTF8String:_cachedStatus.save_path.c_str()];
}

- (LTTorrentState)state {
    if (!_cached) [self refresh];
    return (LTTorrentState)mapState(_cachedStatus.state);
}

- (BOOL)paused {
    if (!_cached) [self refresh];
    return (_cachedStatus.flags & lt::torrent_flags::paused);
}

- (NSString * _Nullable)errorMessage {
    if (!_cached) [self refresh];
    if (!_cachedStatus.errc) return nil;
    return [NSString stringWithUTF8String:_cachedStatus.errc.message().c_str()];
}

- (void)pause      { _handle.pause(); }
- (void)resume     { _handle.resume(); }
- (void)recheck    { _handle.force_recheck(); }
- (void)reannounce { _handle.force_reannounce(); }
- (void)setDownloadLimit:(int)limit { _handle.set_download_limit(limit); }
- (void)setUploadLimit:(int)limit   { _handle.set_upload_limit(limit); }

// ─── File tree ────────────────────────────────────────────────────────────

- (int)fileCount {
    auto ti = _handle.torrent_file();
    return ti ? (int)ti->files().num_files() : 0;
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
    if (!ti || index < 0 || index >= ti->files().num_files()) return nil;
    auto fs = ti->files();
    if (outSize)     *outSize     = fs.file_size(lt::file_index_t{index});
    if (outPriority) *outPriority = (int)_handle.file_priority(lt::file_index_t{index});
    return [NSString stringWithUTF8String:fs.file_path(lt::file_index_t{index}).c_str()];
}

- (void)setFilePriority:(int)priority atIndex:(int)index {
    _handle.file_priority(lt::file_index_t{index},
                          lt::download_priority_t{(std::uint8_t)priority});
}

@end

// ─── LibtorrentSession ─────────────────────────────────────────────────────

@interface LibtorrentSession () {
    lt::session *_session;
    NSMutableArray<LTTorrentHandle *> *_handles;
}
@end

@implementation LibtorrentSession

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
        _session = new lt::session(std::move(sp));
        _handles = [NSMutableArray new];
    }
    return self;
}

- (void)dealloc {
    delete _session;
}

- (nullable LTTorrentHandle *)addTorrentFile:(NSString *)filePath
                                    savePath:(NSString *)savePath {
    try {
        lt::error_code ec;
        auto ti = std::make_shared<lt::torrent_info>(
            std::string(filePath.UTF8String), ec);
        if (ec) return nil;

        lt::add_torrent_params p;
        p.ti = ti;
        p.save_path = std::string(savePath.UTF8String);

        lt::torrent_handle h = _session->add_torrent(p);
        if (!h.is_valid()) return nil;

        auto *wrapper = [[LTTorrentHandle alloc] initWithHandle:h];
        [_handles addObject:wrapper];
        return wrapper;
    } catch (...) { return nil; }
}

- (nullable LTTorrentHandle *)addMagnetURI:(NSString *)magnetURI
                                  savePath:(NSString *)savePath {
    try {
        lt::add_torrent_params p = lt::parse_magnet_uri(std::string(magnetURI.UTF8String));
        p.save_path = std::string(savePath.UTF8String);

        lt::torrent_handle h = _session->add_torrent(p);
        if (!h.is_valid()) return nil;

        auto *wrapper = [[LTTorrentHandle alloc] initWithHandle:h];
        [_handles addObject:wrapper];
        return wrapper;
    } catch (...) { return nil; }
}

- (NSArray<LTTorrentHandle *> *)allTorrents {
    for (LTTorrentHandle *h in _handles) {
        [h refresh];
    }
    return [_handles copy];
}

- (void)removeTorrent:(LTTorrentHandle *)handle deleteFiles:(BOOL)deleteFiles {
    lt::remove_flags_t flags = {};
    if (deleteFiles) {
        flags = lt::session_handle::delete_files | lt::session_handle::delete_partfile;
    }
    _session->remove_torrent(handle.handle, flags);
    [_handles removeObject:handle];
}

- (void)pause  { _session->pause(); }
- (void)resume { _session->resume(); }

- (void)saveResumeDataAll {
    std::vector<lt::torrent_status> statuses;
    _session->get_torrent_status(&statuses, [](const lt::torrent_status&){ return true; });
    for (auto &st : statuses) {
        if (st.handle.is_valid() && st.has_metadata) {
            st.handle.save_resume_data(lt::torrent_handle::save_info_dict);
        }
    }
}

- (void)popAlerts:(void (^)(LTAlertType type, LTTorrentHandle * _Nullable handle, NSString *message, int errorCode))callback {
    if (!callback) return;
    std::vector<lt::alert *> alerts;
    _session->pop_alerts(&alerts);
    for (auto *a : alerts) {
        LTAlertType type = LTAlertTypeUnknown;
        LTTorrentHandle * _Nullable wrapper = nil;
        int errorCode = 0;

        if      (auto *x = lt::alert_cast<lt::add_torrent_alert>(a))      {
            type = LTAlertTypeTorrentAdded;
            wrapper = [[LTTorrentHandle alloc] initWithHandle:x->handle];
        }
        else if (auto *x = lt::alert_cast<lt::torrent_removed_alert>(a))  { type = LTAlertTypeTorrentRemoved; }
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
        }
        else if (auto *x = lt::alert_cast<lt::state_changed_alert>(a))    {
            type = LTAlertTypeStateChanged;
            wrapper = [[LTTorrentHandle alloc] initWithHandle:x->handle];
        }
        else if (auto *x = lt::alert_cast<lt::metadata_received_alert>(a)){
            type = LTAlertTypeMetadataReceived;
            wrapper = [[LTTorrentHandle alloc] initWithHandle:x->handle];
        }

        NSString *msg = [NSString stringWithUTF8String:a->message().c_str()];
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
    if (listenPort)       *listenPort       = 6881;
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
    _session->apply_settings(sp);
}

@end
