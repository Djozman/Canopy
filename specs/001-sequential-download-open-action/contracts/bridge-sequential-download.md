# Contract: Bridge Sequential Download

**Layer**: ClibtorrentBridge (ObjC++) → libtorrent (C++)

## LTTorrentHandle (ObjC Class)

### Property

```objc
@property (nonatomic, assign) BOOL sequentialDownload;
```

### Getter Implementation

```objc
- (BOOL)sequentialDownload {
    return (_handle.flags() & lt::torrent_flags::sequential_download)
        != lt::torrent_flags::none;
}
```

### Setter Implementation

```objc
- (void)setSequentialDownload:(BOOL)sequential {
    queue.async(^{
        if (sequential) {
            _handle.set_flags(lt::torrent_flags::sequential_download);
        } else {
            _handle.unset_flags(lt::torrent_flags::sequential_download);
        }
    });
}
```

## TorrentEngine (Swift)

### Method

```swift
public func setSequentialDownload(
    _ torrent: TorrentStatus, enabled: Bool
) {
    guard let handle = torrent.handle else { return }
    queue.async {
        handle.sequentialDownload = enabled
    }
}
```

## TorrentStatus (Swift Struct)

### Field

```swift
public let isSequentialDownload: Bool
```

Populated during snapshot building by reading the handle's
`sequentialDownload` property.