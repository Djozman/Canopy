#import <Foundation/Foundation.h>
#import "LTTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// A thin Objective-C facade over a libtorrent session. All libtorrent and
/// Boost types are hidden behind this interface so Swift never sees C++.
@interface LTSession : NSObject

/// Creates a session.
/// - savePath: default destination for downloaded content.
/// - configPath: directory where resume/.fastresume files are persisted.
- (instancetype)initWithSavePath:(NSString *)savePath
                      configPath:(NSString *)configPath;

/// Starts listening and reloads any persisted torrents from the config path.
- (void)start;
/// Saves resume data and stops the session.
- (void)stop;

/// Adds a magnet link. Returns the torrent info-hash, or nil on failure.
- (nullable NSString *)addMagnet:(NSString *)magnetURI
                        savePath:(nullable NSString *)savePath
                          paused:(BOOL)paused
                           error:(NSError **)error;

/// Adds a .torrent file from disk. Returns the info-hash, or nil on failure.
- (nullable NSString *)addTorrentFileAtPath:(NSString *)filePath
                                   savePath:(nullable NSString *)savePath
                                     paused:(BOOL)paused
                                      error:(NSError **)error;

- (void)pause:(NSArray<NSString *> *)infoHashes;
- (void)resume:(NSArray<NSString *> *)infoHashes;
- (void)forceRecheck:(NSArray<NSString *> *)infoHashes;
- (void)remove:(NSArray<NSString *> *)infoHashes deleteFiles:(BOOL)deleteFiles;

/// Queue priority controls.
- (void)queueTop:(NSArray<NSString *> *)infoHashes;
- (void)queueUp:(NSArray<NSString *> *)infoHashes;
- (void)queueDown:(NSArray<NSString *> *)infoHashes;
- (void)queueBottom:(NSArray<NSString *> *)infoHashes;

/// Current snapshot of all torrents.
- (NSArray<LTTorrentStats *> *)torrents;
/// Aggregate session stats.
- (LTSessionStats *)sessionStats;

/// Files within a torrent (empty until metadata is available).
- (NSArray<LTFileEntry *> *)filesFor:(NSString *)infoHash;
/// Sets per-file download priorities (libtorrent 0..7; 0 = skip).
- (void)setFilePriorities:(NSArray<NSNumber *> *)priorities
                      for:(NSString *)infoHash;

/// Connected peers for a torrent (Peers tab).
- (NSArray<LTPeerEntry *> *)peersFor:(NSString *)infoHash;
/// Trackers for a torrent (Trackers tab).
- (NSArray<LTTrackerEntry *> *)trackersFor:(NSString *)infoHash;
/// Extended detail for a torrent (General tab). nil if not found.
- (nullable LTTorrentDetail *)detailFor:(NSString *)infoHash;

/// Moves a torrent's storage to a new save path.
- (void)moveStorage:(NSString *)infoHash to:(NSString *)path;

/// Global rate limits (bytes/sec, 0 = unlimited).
- (void)setDownloadRateLimit:(int)bytesPerSecond;
- (void)setUploadRateLimit:(int)bytesPerSecond;
/// Listen port for incoming connections.
- (void)setListenPort:(int)port;

/// Global connection / upload-slot limits (-1 or 0 = unlimited where noted).
- (void)setMaxConnections:(int)maxConnections;
- (void)setMaxUploads:(int)maxUploads;

/// Network feature toggles.
- (void)setDHTEnabled:(BOOL)dht lsd:(BOOL)lsd upnp:(BOOL)upnp natpmp:(BOOL)natpmp;

/// Encryption policy: 0 = enabled/prefer, 1 = forced, 2 = disabled.
- (void)setEncryptionPolicy:(int)policy;

/// Torrent queueing limits. Pass -1 for unlimited.
- (void)setQueueLimitsDownloads:(int)maxDownloads seeds:(int)maxSeeds total:(int)maxTotal;

/// Per-torrent BitTorrent toggles.
- (void)setSequentialDownload:(BOOL)enabled for:(NSArray<NSString *> *)infoHashes;
- (void)setSuperSeeding:(BOOL)enabled for:(NSArray<NSString *> *)infoHashes;
- (void)setFirstLastPiecePriority:(BOOL)enabled for:(NSArray<NSString *> *)infoHashes;

/// Per-torrent rate limits (bytes/sec, 0 = unlimited).
- (void)setTorrentDownloadLimit:(int)bytesPerSecond for:(NSString *)infoHash;
- (void)setTorrentUploadLimit:(int)bytesPerSecond for:(NSString *)infoHash;

/// Force a tracker + DHT reannounce now.
- (void)forceReannounce:(NSArray<NSString *> *)infoHashes;
/// Force-resume, bypassing the queue (disables auto-management).
- (void)forceResume:(NSArray<NSString *> *)infoHashes;

/// Magnet URI for a torrent (nil if unavailable).
- (nullable NSString *)magnetURIFor:(NSString *)infoHash;

/// Renames a single file within a torrent.
- (void)renameFile:(NSInteger)fileIndex to:(NSString *)newRelativePath for:(NSString *)infoHash;

/// Tracker editing.
- (void)addTracker:(NSString *)url for:(NSString *)infoHash;
- (void)removeTracker:(NSString *)url for:(NSString *)infoHash;

/// Adds a peer manually. `ipPort` is "host:port" (IPv6 as "[::1]:port").
- (BOOL)addPeer:(NSString *)ipPort for:(NSString *)infoHash;

/// Creates a .torrent file from a file or folder. Returns the output path or
/// nil on failure. `pieceSize` in bytes (0 = auto).
- (nullable NSString *)createTorrentAtPath:(NSString *)sourcePath
                                    output:(NSString *)outputPath
                                  trackers:(NSArray<NSString *> *)trackers
                                   comment:(NSString *)comment
                                 isPrivate:(BOOL)isPrivate
                                 pieceSize:(int)pieceSize
                                     error:(NSError **)error;

/// Requests a resume-data save for any torrent that needs it. Resulting
/// .fastresume files are written asynchronously to the config path.
- (void)saveResumeData;

@end

NS_ASSUME_NONNULL_END
