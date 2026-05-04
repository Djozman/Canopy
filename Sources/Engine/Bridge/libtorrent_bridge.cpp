// libtorrent_bridge.cpp
// C wrapper implementation — translates C API calls to libtorrent C++ API.

#include "libtorrent_bridge.h"

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
#include <fstream>
#include <memory>

namespace lt = libtorrent;

static void safe_copy(char *dst, const std::string &src, size_t dst_size) {
    strncpy(dst, src.c_str(), dst_size - 1);
    dst[dst_size - 1] = '\0';
}

static void copy_hash(uint8_t *dst, const lt::sha1_hash &hash) {
    memcpy(dst, hash.data(), 20);
}

static lt::torrent_handle* to_cpp_handle(lt_torrent_handle h) {
    return static_cast<lt::torrent_handle*>(h);
}

// ─── Session ─────────────────────────────────────────────────────────────────

lt_session_handle lt_session_create(void) {
    try {
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
                   lt::alert_category::tracker);      // `progress` category removed
        auto *session = new lt::session(std::move(sp));
        return static_cast<lt_session_handle>(session);
    } catch (...) { return nullptr; }
}

void lt_session_destroy(lt_session_handle session) { delete static_cast<lt::session*>(session); }
void lt_session_pause(lt_session_handle session)   { static_cast<lt::session*>(session)->pause(); }
void lt_session_resume(lt_session_handle session)  { static_cast<lt::session*>(session)->resume(); }

// ─── Add / Remove ────────────────────────────────────────────────────────────

lt_torrent_handle lt_torrent_add_file(lt_session_handle session, const char *torrent_path, const char *save_path) {
    try {
        lt::add_torrent_params p;
        lt::error_code ec;
        p.ti        = std::make_shared<lt::torrent_info>(torrent_path, ec);
        if (ec) return nullptr;
        p.save_path = save_path;
        lt::torrent_handle h = static_cast<lt::session*>(session)->add_torrent(p);
        if (!h.is_valid()) return nullptr;
        return static_cast<lt_torrent_handle>(new lt::torrent_handle(h));
    } catch (...) { return nullptr; }
}

lt_torrent_handle lt_torrent_add_magnet(lt_session_handle session, const char *magnet_uri, const char *save_path) {
    try {
        lt::add_torrent_params p = lt::parse_magnet_uri(magnet_uri);
        p.save_path = save_path;
        lt::torrent_handle h = static_cast<lt::session*>(session)->add_torrent(p);
        if (!h.is_valid()) return nullptr;
        return static_cast<lt_torrent_handle>(new lt::torrent_handle(h));
    } catch (...) { return nullptr; }
}

void lt_torrent_remove(lt_session_handle session, lt_torrent_handle handle, bool delete_files) {
    auto *h = to_cpp_handle(handle);
    auto flags = delete_files ? lt::session::delete_files : lt::remove_flags_t{};
    static_cast<lt::session*>(session)->remove_torrent(*h, flags);
    delete h;
}

void lt_torrent_pause(lt_torrent_handle handle)      { to_cpp_handle(handle)->pause(); }
void lt_torrent_resume(lt_torrent_handle handle)     { to_cpp_handle(handle)->resume(); }
void lt_torrent_recheck(lt_torrent_handle handle)    { to_cpp_handle(handle)->force_recheck(); }
void lt_torrent_reannounce(lt_torrent_handle handle) { to_cpp_handle(handle)->force_reannounce(); }
void lt_torrent_set_download_limit(lt_torrent_handle handle, int limit) { to_cpp_handle(handle)->set_download_limit(limit); }
void lt_torrent_set_upload_limit(lt_torrent_handle handle, int limit)   { to_cpp_handle(handle)->set_upload_limit(limit); }

// ─── Status ──────────────────────────────────────────────────────────────────

static int map_state(lt::torrent_status::state_t s) {
    switch (s) {
        case lt::torrent_status::checking_files:       return 0;
        case lt::torrent_status::downloading_metadata: return 1;
        case lt::torrent_status::downloading:          return 2;
        case lt::torrent_status::finished:             return 3;
        case lt::torrent_status::seeding:              return 4;
        case lt::torrent_status::allocating:           return 5;
        case lt::torrent_status::checking_resume_data: return 6;
        default:                                        return 2;
    }
}

static void fill_status(lt_torrent_status *out, const lt::torrent_status &s) {
    copy_hash(out->info_hash, s.info_hashes.v1);
    safe_copy(out->name,      s.name,      sizeof(out->name));
    safe_copy(out->save_path, s.save_path, sizeof(out->save_path));
    auto tf = s.torrent_file.lock();   // `torrent_file` is a weak_ptr in libtorrent 2.x
    out->total_size    = tf ? tf->total_size() : 0;
    out->total_done    = s.total_done;
    out->total_upload  = s.total_upload;
    out->download_rate = s.download_rate;
    out->upload_rate   = s.upload_rate;
    out->progress      = s.progress;
    out->num_seeds     = s.num_seeds;
    out->num_peers     = s.num_peers;
    out->state         = map_state(s.state);
    out->paused        = s.flags & lt::torrent_flags::paused;
    int64_t remaining  = out->total_size - out->total_done;
    out->eta_seconds   = (out->download_rate > 0) ? (remaining / out->download_rate) : -1;
    if (s.errc) safe_copy(out->error, s.errc.message(), sizeof(out->error));
    else out->error[0] = '\0';
}

bool lt_torrent_get_status(lt_torrent_handle handle, lt_torrent_status *out_status) {
    try { auto s = to_cpp_handle(handle)->status(); fill_status(out_status, s); return true; }
    catch (...) { return false; }
}

void lt_session_poll_status(lt_session_handle session, lt_status_callback callback, void *ctx) {
    try {
        std::vector<lt::torrent_status> statuses;
        static_cast<lt::session*>(session)->get_torrent_status(&statuses, [](const lt::torrent_status&){ return true; });
        for (auto &s : statuses) {
            auto *tmp = new lt::torrent_handle(s.handle);
            lt_torrent_status out{};
            fill_status(&out, s);
            callback(static_cast<lt_torrent_handle>(tmp), &out, ctx);
            delete tmp;
        }
    } catch (...) {}
}

// ─── Alerts ──────────────────────────────────────────────────────────────────

void lt_session_pop_alerts(lt_session_handle session, lt_alert_callback callback, void *ctx) {
    try {
        std::vector<lt::alert*> alerts;
        static_cast<lt::session*>(session)->pop_alerts(&alerts);
        for (auto *a : alerts) {
            lt_alert out{};
            out.type = LT_ALERT_UNKNOWN;
            out.handle = nullptr;
            out.error_code = 0;
            safe_copy(out.message, a->message(), sizeof(out.message));
            if      (auto *x = lt::alert_cast<lt::add_torrent_alert>(a))      { out.type = LT_ALERT_TORRENT_ADDED;     out.handle = new lt::torrent_handle(x->handle); }
            else if (auto *x = lt::alert_cast<lt::torrent_removed_alert>(a))  { out.type = LT_ALERT_TORRENT_REMOVED; }
            else if (auto *x = lt::alert_cast<lt::torrent_finished_alert>(a)) { out.type = LT_ALERT_TORRENT_FINISHED;  out.handle = new lt::torrent_handle(x->handle); }
            else if (auto *x = lt::alert_cast<lt::torrent_error_alert>(a))    { out.type = LT_ALERT_TORRENT_ERROR;     out.handle = new lt::torrent_handle(x->handle); out.error_code = x->error.value(); }
            else if (auto *x = lt::alert_cast<lt::tracker_error_alert>(a))    { out.type = LT_ALERT_TRACKER_ERROR;     out.handle = new lt::torrent_handle(x->handle); out.error_code = x->error.value(); }
            else if (auto *x = lt::alert_cast<lt::save_resume_data_alert>(a)) { out.type = LT_ALERT_SAVE_RESUME_DATA;  out.handle = new lt::torrent_handle(x->handle); }
            else if (auto *x = lt::alert_cast<lt::state_changed_alert>(a))    { out.type = LT_ALERT_STATE_CHANGED;     out.handle = new lt::torrent_handle(x->handle); }
            else if (auto *x = lt::alert_cast<lt::metadata_received_alert>(a)){ out.type = LT_ALERT_METADATA_RECEIVED; out.handle = new lt::torrent_handle(x->handle); }
            callback(&out, ctx);
            if (out.handle) { delete static_cast<lt::torrent_handle*>(out.handle); }
        }
    } catch (...) {}
}

// ─── Files ───────────────────────────────────────────────────────────────────

int lt_torrent_file_count(lt_torrent_handle handle) {
    try { auto ti = to_cpp_handle(handle)->torrent_file(); return ti ? (int)ti->files().num_files() : -1; }
    catch (...) { return -1; }
}

bool lt_torrent_file_info(lt_torrent_handle handle, int index, lt_file_info *out) {
    try {
        auto ti = to_cpp_handle(handle)->torrent_file();
        if (!ti) return false;
        const auto &fs = ti->files();
        if (index < 0 || index >= fs.num_files()) return false;
        out->size     = fs.file_size(lt::file_index_t{index});
        out->offset   = fs.file_offset(lt::file_index_t{index});
        out->downloaded = 0;
        safe_copy(out->path, fs.file_path(lt::file_index_t{index}), sizeof(out->path));
        out->priority = (lt_file_priority)(int)to_cpp_handle(handle)->file_priority(lt::file_index_t{index});
        return true;
    } catch (...) { return false; }
}

void lt_torrent_set_file_priority(lt_torrent_handle handle, int index, lt_file_priority priority) {
    try { to_cpp_handle(handle)->file_priority(lt::file_index_t{index}, lt::download_priority_t{(uint8_t)priority}); }
    catch (...) {}
}

// ─── Trackers ────────────────────────────────────────────────────────────────

int lt_torrent_tracker_count(lt_torrent_handle handle) {
    try { return (int)to_cpp_handle(handle)->trackers().size(); } catch (...) { return 0; }
}

bool lt_torrent_tracker_info(lt_torrent_handle handle, int index, lt_tracker_info *out) {
    try {
        auto trackers = to_cpp_handle(handle)->trackers();
        if (index < 0 || index >= (int)trackers.size()) return false;
        safe_copy(out->url, trackers[index].url, sizeof(out->url));
        out->working = !trackers[index].endpoints.empty();
        out->num_seeds = out->num_peers = out->next_announce_seconds = 0;
        out->message[0] = '\0';
        return true;
    } catch (...) { return false; }
}

void lt_torrent_add_tracker(lt_torrent_handle handle, const char *url, int tier) {
    try { lt::announce_entry e(url); e.tier = (uint8_t)tier; to_cpp_handle(handle)->add_tracker(e); } catch (...) {}
}

void lt_torrent_remove_tracker(lt_torrent_handle handle, const char *url) {
    try {
        auto t = to_cpp_handle(handle)->trackers();
        t.erase(std::remove_if(t.begin(), t.end(), [url](const lt::announce_entry &e){ return e.url == url; }), t.end());
        to_cpp_handle(handle)->replace_trackers(t);
    } catch (...) {}
}

// ─── Peers ───────────────────────────────────────────────────────────────────

int lt_torrent_peer_count(lt_torrent_handle handle) {
    try { std::vector<lt::peer_info> p; to_cpp_handle(handle)->get_peer_info(p); return (int)p.size(); } catch (...) { return 0; }
}

bool lt_torrent_peer_info(lt_torrent_handle handle, int index, lt_peer_info *out) {
    try {
        std::vector<lt::peer_info> peers;
        to_cpp_handle(handle)->get_peer_info(peers);
        if (index < 0 || index >= (int)peers.size()) return false;
        const auto &p = peers[index];
        safe_copy(out->ip, p.ip.address().to_string(), sizeof(out->ip));
        out->port          = p.ip.port();
        safe_copy(out->client, p.client, sizeof(out->client));
        out->progress      = p.progress;
        out->download_rate = p.down_speed;
        out->upload_rate   = p.up_speed;
        out->seeder        = p.flags & lt::peer_info::seed;
        return true;
    } catch (...) { return false; }
}

// ─── Session Settings ────────────────────────────────────────────────────────

void lt_session_get_settings(lt_session_handle session, lt_session_settings *out) {
    try {
        auto sp = static_cast<lt::session*>(session)->get_settings();
        out->download_rate_limit = sp.get_int(lt::settings_pack::download_rate_limit);
        out->upload_rate_limit   = sp.get_int(lt::settings_pack::upload_rate_limit);
        out->active_downloads    = sp.get_int(lt::settings_pack::active_downloads);
        out->active_seeds        = sp.get_int(lt::settings_pack::active_seeds);
        out->active_limit        = sp.get_int(lt::settings_pack::active_limit);
        out->enable_dht          = sp.get_bool(lt::settings_pack::enable_dht);
        out->enable_lsd          = sp.get_bool(lt::settings_pack::enable_lsd);
        out->enable_upnp         = sp.get_bool(lt::settings_pack::enable_upnp);
        out->enable_natpmp       = sp.get_bool(lt::settings_pack::enable_natpmp);
        out->anonymous_mode      = sp.get_bool(lt::settings_pack::anonymous_mode);
        out->listen_port         = 6881;
        out->proxy_hostname[0]   = '\0';
        out->proxy_port          = 0;
        out->proxy_type          = 0;
    } catch (...) {}
}

void lt_session_apply_settings(lt_session_handle session, const lt_session_settings *in) {
    try {
        lt::settings_pack sp;
        sp.set_int(lt::settings_pack::download_rate_limit, in->download_rate_limit);
        sp.set_int(lt::settings_pack::upload_rate_limit,   in->upload_rate_limit);
        sp.set_int(lt::settings_pack::active_downloads,    in->active_downloads);
        sp.set_int(lt::settings_pack::active_seeds,        in->active_seeds);
        sp.set_int(lt::settings_pack::active_limit,        in->active_limit);
        sp.set_bool(lt::settings_pack::enable_dht,         in->enable_dht);
        sp.set_bool(lt::settings_pack::enable_lsd,         in->enable_lsd);
        sp.set_bool(lt::settings_pack::enable_upnp,        in->enable_upnp);
        sp.set_bool(lt::settings_pack::enable_natpmp,      in->enable_natpmp);
        sp.set_bool(lt::settings_pack::anonymous_mode,     in->anonymous_mode);
        sp.set_str(lt::settings_pack::listen_interfaces, std::string("0.0.0.0:") + std::to_string(in->listen_port));
        static_cast<lt::session*>(session)->apply_settings(sp);
    } catch (...) {}
}

// ─── Resume data ─────────────────────────────────────────────────────────────

void lt_session_save_resume_data_all(lt_session_handle session) {
    try {
        std::vector<lt::torrent_status> statuses;
        auto *s = static_cast<lt::session*>(session);
        s->get_torrent_status(&statuses, [](const lt::torrent_status&){ return true; });
        for (auto &st : statuses)
            if (st.handle.is_valid() && st.has_metadata && !st.need_save_resume)
                st.handle.save_resume_data(lt::torrent_handle::save_info_dict);
    } catch (...) {}
}

lt_torrent_handle lt_torrent_load_resume(lt_session_handle session, const char *resume_file_path) {
    try {
        std::ifstream f(resume_file_path, std::ios::binary);
        if (!f) return nullptr;
        std::vector<char> buf((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        lt::error_code ec;
        lt::add_torrent_params p = lt::read_resume_data(buf, ec);
        if (ec) return nullptr;
        auto h = static_cast<lt::session*>(session)->add_torrent(p);
        return h.is_valid() ? new lt::torrent_handle(h) : nullptr;
    } catch (...) { return nullptr; }
}
