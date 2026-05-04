#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int, LTTorrentState) {
    LTTorrentStateCheckingFiles       = 0,
    LTTorrentStateDownloadingMetadata = 1,
    LTTorrentStateDownloading         = 2,
    LTTorrentStateFinished            = 3,
    LTTorrentStateSeeding             = 4,
    LTTorrentStateAllocating          = 5,
    LTTorrentStateCheckingResumeData  = 6,
};

typedef NS_ENUM(int, LTAlertType) {
    LTAlertTypeTorrentAdded     = 0,
    LTAlertTypeTorrentRemoved   = 1,
    LTAlertTypeTorrentFinished  = 2,
    LTAlertTypeTorrentError     = 3,
    LTAlertTypeTrackerError     = 4,
    LTAlertTypeSaveResumeData   = 5,
    LTAlertTypeStateChanged     = 6,
    LTAlertTypeMetadataReceived = 7,
    LTAlertTypeHashFailed       = 8,
    LTAlertTypeStorageMoved     = 9,
    LTAlertTypeUnknown          = 99,
};

@interface LTTorrentHandle : NSObject
@property (readonly) NSString *name;
@property (readonly) float     progress;
@property (readonly) int64_t   downloadRate;
@property (readonly) int64_t   uploadRate;
@property (readonly) int64_t   totalDone;
@property (readonly) int64_t   totalSize;
@property (readonly) int64_t   totalUploaded;
@property (readonly) int       numSeeds;
@property (readonly) int       numPeers;
@property (readonly) int64_t   etaSeconds;
@property (readonly) NSString *infoHash;
@property (readonly) NSString *savePath;
@property (readonly) LTTorrentState state;
@property (readonly) BOOL      paused;
@property (readonly, nullable) NSString *errorMessage;

- (void)pause;
- (void)resume;
- (void)recheck;
- (void)reannounce;
- (void)setDownloadLimit:(int)limit;
- (void)setUploadLimit:(int)limit;

// File tree support
@property (readonly) int fileCount;
- (NSArray<NSNumber *> *)fileProgressAll;
- (nullable NSString *)filePathAtIndex:(int)index
                                  size:(int64_t *)outSize
                              priority:(int *)outPriority;
- (void)setFilePriority:(int)priority atIndex:(int)index;
@end

@interface LibtorrentSession : NSObject
- (instancetype)init;
- (nullable LTTorrentHandle *)addTorrentFile:(NSString *)filePath
                                    savePath:(NSString *)savePath;
- (nullable LTTorrentHandle *)addMagnetURI:(NSString *)magnetURI
                                  savePath:(NSString *)savePath;
- (NSArray<LTTorrentHandle *> *)allTorrents;
- (void)removeTorrent:(LTTorrentHandle *)handle deleteFiles:(BOOL)deleteFiles;
- (void)pause;
- (void)resume;
- (void)saveResumeDataAll;
- (void)popAlerts:(void (^)(LTAlertType type, LTTorrentHandle * _Nullable handle, NSString *message, int errorCode))callback;
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
                         listenPort:(int *)listenPort;
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
                           listenPort:(int)listenPort;
@end

NS_ASSUME_NONNULL_END
