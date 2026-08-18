# Contract: Bridge Rename Before Add

**Layer**: ClibtorrentBridge (ObjC++) → libtorrent (C++)

## .torrent File Adds — addTorrentFile

Signature gains a renamed-paths parameter:

```objc
- (nullable LTTorrentHandle *)addTorrentFile:(NSString *)path
                                    savePath:(NSString *)savePath
                                  priorities:(nullable NSArray<NSNumber *> *)priorities
                                    renamedFiles:(nullable NSArray<NSString *> *)renamedPaths;
```

`renamedPaths`, when provided, maps by index to the new relative path for each
file. The bridge populates `add_torrent_params::renamed_files`:

```cpp
if (renamedPaths) {
    for (NSUInteger i = 0; i < renamedPaths.count; i++) {
        NSString *newPath = renamedPaths[i];
        if (newPath.length == 0) continue;
        p.renamed_files[lt::file_index_t{ (int)i }] = std::string(newPath.UTF8String);
    }
}
```

## Magnet Adds — commitMagnet

Signature gains renamed paths; applied to the already-existing handle via
`torrent_handle::rename_file` before resuming:

```objc
- (void)commitMagnet:(LTTorrentHandle *)handle
            savePath:(NSString *)savePath
          priorities:(nullable NSArray<NSNumber *> *)priorities
        renamedFiles:(nullable NSArray<NSString *> *)renamedPaths;
```

```cpp
if (renamedPaths) {
    for (NSUInteger i = 0; i < renamedPaths.count; i++) {
        NSString *newPath = renamedPaths[i];
        if (newPath.length == 0) continue;
        h.rename_file(lt::file_index_t{ (int)i },
                      std::string(newPath.UTF8String));
    }
}
```

## Engine (TorrentEngine)

`confirm(_:)` and `commitMagnet(handle:savePath:files:)` pass the resolved
renamed-path array (parallel to `priorities`, by file index) into the bridge
calls.

## ViewModel Contract

`PreAddViewModel.buildRenamedFiles() -> [Int: String]` produces a stable
`fileIndex → newRelativePath` map. The engine flattens it to an array ordered by
file index for the bridge (unrenamed entries left empty so libtorrent uses the
original path).