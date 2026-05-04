// libtorrent_bridge.h
// C-compatible bridge between libtorrent (C++) and Swift.
//
// HOW IT WORKS
// ─────────────────────────────────────────────────────────────────────────────
// Swift cannot import C++ headers directly (without Swift 5.9 C++ interop, which
// is still experimental for complex RAII types). The safest, most portable path
// is a thin C wrapper:
//
//   libtorrent (C++) ──► C wrapper (libtorrent_bridge.cpp) ──► Swift
//
// This header declares only plain C types and functions.  The implementation
// file (libtorrent_bridge.cpp) translates them to/from libtorrent's C++ API.
//
// SETUP STEPS
// ─────────────────────────────────────────────────────────────────────────────
// 1. Install libtorrent-rasterbar via Homebrew:
//      brew install libtorrent-rasterbar
//
// 2. In Xcode → Build Settings:
//      Header Search Paths:     $(brew --prefix libtorrent-rasterbar)/include
//      Library Search Paths:    $(brew --prefix libtorrent-rasterbar)/lib
//      Other Linker Flags:      -ltorrent-rasterbar -lc++
//
// 3. Add this file + libtorrent_bridge.cpp to your Xcode target.
//
// 4. In your project's Bridging-Header.h add:
//      #include "libtorrent_bridge.h"
//
// ─────────────────────────────────────────────────────────────────────────────

#ifndef LIBTORRENT_BRIDGE_H
#define LIBTORRENT_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─────────────────────────────────────────────────────────────────────────────
// OPAQUE SESSION HANDLE
// ─────────────────────────────────────────────────────────────────────────────

typedef void* lt_session_handle;

lt_session_handle lt_session_create(void);
void lt_session_destroy(lt_session_handle session);
void lt_session_pause(lt_session_handle session);
void lt_session_resume(lt_session_handle session);

// ─────────────────────────────────────────────────────────────────────────────
// TORRENT STATUS
// ─────────────────────────────────────────────────────────────────────────────

typedef struct {
    uint8_t info_hash[20];
    char    name[512];
    char    save_path[1024];
    int64_t total_size;
    int64_t total_done;
    int64_t total_upload;
    int     download_rate;
    int     upload_rate;
    float   progress;
    int     num_seeds;
    int     num_peers;
    int64_t eta_seconds;
    int     state;
    bool    paused;
    char    error[256];
} lt_torrent_status;

// ─────────────────────────────────────────────────────────────────────────────
// TORRENT HANDLE
// ─────────────────────────────────────────────────────────────────────────────

typedef void* lt_torrent_handle;

lt_torrent_handle lt_torrent_add_file(lt_session_handle session, const char *torrent_path, const char *save_path);
lt_torrent_handle lt_torrent_add_magnet(lt_session_handle session, const char *magnet_uri, const char *save_path);
void lt_torrent_remove(lt_session_handle session, lt_torrent_handle handle, bool delete_files);
void lt_torrent_pause(lt_torrent_handle handle);
void lt_torrent_resume(lt_torrent_handle handle);
void lt_torrent_recheck(lt_torrent_handle handle);
void lt_torrent_reannounce(lt_torrent_handle handle);
void lt_torrent_set_download_limit(lt_torrent_handle handle, int limit);
void lt_torrent_set_upload_limit(lt_torrent_handle handle, int limit);
bool lt_torrent_get_status(lt_torrent_handle handle, lt_torrent_status *out_status);

// ─────────────────────────────────────────────────────────────────────────────
// BULK STATUS POLL
// ─────────────────────────────────────────────────────────────────────────────

typedef void (*lt_status_callback)(lt_torrent_handle handle, const lt_torrent_status *status, void *ctx);
void lt_session_poll_status(lt_session_handle session, lt_status_callback callback, void *ctx);

// ─────────────────────────────────────────────────────────────────────────────
// ALERTS
// ─────────────────────────────────────────────────────────────────────────────

typedef enum {
    LT_ALERT_TORRENT_ADDED      = 0,
    LT_ALERT_TORRENT_REMOVED    = 1,
    LT_ALERT_TORRENT_FINISHED   = 2,
    LT_ALERT_TORRENT_ERROR      = 3,
    LT_ALERT_TRACKER_ERROR      = 4,
    LT_ALERT_SAVE_RESUME_DATA   = 5,
    LT_ALERT_STATE_CHANGED      = 6,
    LT_ALERT_METADATA_RECEIVED  = 7,
    LT_ALERT_HASH_FAILED        = 8,
    LT_ALERT_STORAGE_MOVED      = 9,
    LT_ALERT_UNKNOWN            = 99
} lt_alert_type;

typedef struct {
    lt_alert_type     type;
    lt_torrent_handle handle;
    char              message[512];
    int               error_code;
} lt_alert;

typedef void (*lt_alert_callback)(const lt_alert *alert, void *ctx);
void lt_session_pop_alerts(lt_session_handle session, lt_alert_callback callback, void *ctx);

// ─────────────────────────────────────────────────────────────────────────────
// FILE PRIORITIES
// ─────────────────────────────────────────────────────────────────────────────

typedef enum {
    LT_PRIORITY_DONT_DOWNLOAD = 0,
    LT_PRIORITY_LOW           = 1,
    LT_PRIORITY_NORMAL        = 4,
    LT_PRIORITY_HIGH          = 7
} lt_file_priority;

int  lt_torrent_file_count(lt_torrent_handle handle);

typedef struct {
    int64_t          size;
    int64_t          offset;
    int64_t          downloaded;
    char             path[1024];
    lt_file_priority priority;
} lt_file_info;

bool lt_torrent_file_info(lt_torrent_handle handle, int index, lt_file_info *out_info);
void lt_torrent_set_file_priority(lt_torrent_handle handle, int index, lt_file_priority priority);

// ─────────────────────────────────────────────────────────────────────────────
// TRACKERS
// ─────────────────────────────────────────────────────────────────────────────

typedef struct {
    char url[512];
    char message[256];
    int  num_seeds;
    int  num_peers;
    int  next_announce_seconds;
    bool working;
} lt_tracker_info;

int  lt_torrent_tracker_count(lt_torrent_handle handle);
bool lt_torrent_tracker_info(lt_torrent_handle handle, int index, lt_tracker_info *out_info);
void lt_torrent_add_tracker(lt_torrent_handle handle, const char *url, int tier);
void lt_torrent_remove_tracker(lt_torrent_handle handle, const char *url);

// ─────────────────────────────────────────────────────────────────────────────
// PEERS
// ─────────────────────────────────────────────────────────────────────────────

typedef struct {
    char     ip[64];
    uint16_t port;
    char     client[128];
    float    progress;
    int      download_rate;
    int      upload_rate;
    bool     seeder;
} lt_peer_info;

int  lt_torrent_peer_count(lt_torrent_handle handle);
bool lt_torrent_peer_info(lt_torrent_handle handle, int index, lt_peer_info *out_info);

// ─────────────────────────────────────────────────────────────────────────────
// SESSION SETTINGS
// ─────────────────────────────────────────────────────────────────────────────

typedef struct {
    int  download_rate_limit;
    int  upload_rate_limit;
    int  active_downloads;
    int  active_seeds;
    int  active_limit;
    bool enable_dht;
    bool enable_lsd;
    bool enable_upnp;
    bool enable_natpmp;
    int  listen_port;
    bool anonymous_mode;
    char proxy_hostname[256];
    int  proxy_port;
    int  proxy_type;
} lt_session_settings;

void lt_session_get_settings(lt_session_handle session, lt_session_settings *out_settings);
void lt_session_apply_settings(lt_session_handle session, const lt_session_settings *settings);

// ─────────────────────────────────────────────────────────────────────────────
// RESUME DATA
// ─────────────────────────────────────────────────────────────────────────────

void              lt_session_save_resume_data_all(lt_session_handle session);
lt_torrent_handle lt_torrent_load_resume(lt_session_handle session, const char *resume_file_path);

#ifdef __cplusplus
}
#endif

#endif /* LIBTORRENT_BRIDGE_H */
