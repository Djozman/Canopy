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

/// Global rate limits (bytes/sec, 0 = unlimited).
- (void)setDownloadRateLimit:(int)bytesPerSecond;
- (void)setUploadRateLimit:(int)bytesPerSecond;
/// Listen port for incoming connections.
- (void)setListenPort:(int)port;

/// Requests a resume-data save for any torrent that needs it. Resulting
/// .fastresume files are written asynchronously to the config path.
- (void)saveResumeData;

@end

NS_ASSUME_NONNULL_END
