#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Mirrors libtorrent's torrent_status::state_t plus a paused flag.
typedef NS_ENUM(NSInteger, LTTorrentState) {
    LTTorrentStateUnknown = 0,
    LTTorrentStateCheckingResumeData,
    LTTorrentStateCheckingFiles,
    LTTorrentStateDownloadingMetadata,
    LTTorrentStateDownloading,
    LTTorrentStateFinished,
    LTTorrentStateSeeding,
    LTTorrentStateError,
};

/// A snapshot of a single torrent's status. Field names mirror the
/// libtorrent torrent_status fields qBittorrent reads.
@interface LTTorrentStats : NSObject
@property (nonatomic, copy) NSString *infoHash;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *savePath;
@property (nonatomic) int64_t totalWanted;       // total_wanted
@property (nonatomic) int64_t totalDone;          // total_done
@property (nonatomic) double progress;            // progress (0..1)
@property (nonatomic) int64_t downloadRate;       // download_payload_rate
@property (nonatomic) int64_t uploadRate;         // upload_payload_rate
@property (nonatomic) int64_t allTimeDownload;    // all_time_download
@property (nonatomic) int64_t allTimeUpload;      // all_time_upload
@property (nonatomic) int numSeeds;               // num_seeds
@property (nonatomic) int numPeers;               // num_peers - num_seeds
@property (nonatomic) int numComplete;            // num_complete (swarm)
@property (nonatomic) int numIncomplete;          // num_incomplete (swarm)
@property (nonatomic) int connectionsCount;       // num_connections
@property (nonatomic) int queuePosition;          // queue_position (-1 if none)
@property (nonatomic) double ratio;               // all_time_up / all_time_down
@property (nonatomic) int64_t eta;                // seconds, -1 = unknown/infinite
@property (nonatomic) int64_t addedTime;          // unix seconds
@property (nonatomic) int64_t completedTime;      // unix seconds, 0 if not done
@property (nonatomic) LTTorrentState state;
@property (nonatomic) BOOL paused;
@property (nonatomic) BOOL hasMetadata;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@end

/// A single file within a torrent (for content / file-priority views).
@interface LTFileEntry : NSObject
@property (nonatomic) NSInteger index;
@property (nonatomic, copy) NSString *path;       // relative path within the torrent
@property (nonatomic) int64_t size;
@property (nonatomic) int64_t downloaded;
@property (nonatomic) double progress;            // 0..1
@property (nonatomic) int priority;               // libtorrent 0..7 (0 = skip)
@end

/// A connected peer (Peers tab).
@interface LTPeerEntry : NSObject
@property (nonatomic, copy) NSString *address;    // ip:port
@property (nonatomic, copy) NSString *client;     // peer client/version
@property (nonatomic, copy) NSString *flags;      // compact flag string
@property (nonatomic, copy) NSString *connection; // "BT" / "uTP"
@property (nonatomic) double progress;            // 0..1
@property (nonatomic) int64_t downSpeed;          // payload_down_speed
@property (nonatomic) int64_t upSpeed;            // payload_up_speed
@property (nonatomic) int64_t downloaded;         // total_download
@property (nonatomic) int64_t uploaded;           // total_upload
@property (nonatomic) BOOL isSeed;
@end

/// A tracker (Trackers tab), aggregated across endpoints.
@interface LTTrackerEntry : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic) int tier;
@property (nonatomic, copy) NSString *status;     // Working / Updating / Not working / Disabled
@property (nonatomic, copy) NSString *message;
@property (nonatomic) int numSeeds;               // scrape_complete (-1 if unknown)
@property (nonatomic) int numLeeches;             // scrape_incomplete (-1 if unknown)
@property (nonatomic) int numDownloaded;          // scrape_downloaded (-1 if unknown)
@end

/// Extended, on-demand detail for the General tab.
@interface LTTorrentDetail : NSObject
@property (nonatomic, copy) NSString *infoHash;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *savePath;
@property (nonatomic, copy) NSString *comment;
@property (nonatomic, copy) NSString *creator;
@property (nonatomic) int64_t creationDate;       // unix seconds (0 if none)
@property (nonatomic) int64_t totalSize;          // ti total_size
@property (nonatomic) int64_t pieceLength;
@property (nonatomic) int numPieces;
@property (nonatomic) int piecesHave;             // status.num_pieces
@property (nonatomic) int64_t activeDuration;     // seconds
@property (nonatomic) int64_t seedingDuration;    // seconds
@property (nonatomic) int64_t finishedDuration;   // seconds
@property (nonatomic) int64_t addedTime;
@property (nonatomic) int64_t completedTime;
@property (nonatomic) int64_t lastSeenComplete;
@property (nonatomic) double distributedCopies;
@property (nonatomic) int64_t totalDownload;      // all_time_download
@property (nonatomic) int64_t totalUpload;        // all_time_upload
@property (nonatomic) int64_t sessionDownload;    // total_payload_download
@property (nonatomic) int64_t sessionUpload;      // total_payload_upload
@property (nonatomic) int64_t downloadRate;
@property (nonatomic) int64_t uploadRate;
@property (nonatomic) int numConnections;
@property (nonatomic) double ratio;
@property (nonatomic) double progress;
@end

/// Aggregate session-wide counters.
@interface LTSessionStats : NSObject
@property (nonatomic) int64_t downloadRate;
@property (nonatomic) int64_t uploadRate;
@property (nonatomic) int64_t totalDownload;
@property (nonatomic) int64_t totalUpload;
@property (nonatomic) int dhtNodes;
@property (nonatomic) BOOL isListening;
@end

NS_ASSUME_NONNULL_END
