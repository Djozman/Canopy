import Foundation

actor WebSeedConnection: @preconcurrency AnyPeer {
    enum WebSeedState: Sendable { case idle, fetching, active, closed }

    private let url: URL
    private let connection: URLSession
    private(set) var webSeedState: WebSeedState = .idle

    let host: String
    let port: UInt16
    nonisolated let transportName: String = "HTTP"

    private var peerChokingVar = false
    private var peerInterestedVar = false
    private var amChokingVar = false
    private var bitfieldVar: [Bool] = []
    private var extMetadataVar: UInt8? = nil
    private var downloadSpeedVar: Int64 = 0
    private var uploadSpeedVar: Int64 = 0
    private var lastBlockReceivedTimeVar = Date.distantPast
    private var lastMessageReceivedTimeVar = Date.distantPast
    private var lastHandshakeReceivedTimeVar = Date.distantPast
    private var closedVar = false

    var peerChoking: Bool { get async { peerChokingVar } }
    var peerInterested: Bool { get async { peerInterestedVar } }
    var amChoking: Bool { get async { amChokingVar } }
    var bitfield: [Bool] { get async { bitfieldVar } }
    var extMetadata: UInt8? { get async { extMetadataVar } }
    var downloadSpeed: Int64 { get async { downloadSpeedVar } }
    var uploadSpeed: Int64 { get async { uploadSpeedVar } }
    var lastBlockReceivedTime: Date { get async { lastBlockReceivedTimeVar } }
    var lastMessageReceivedTime: Date { get async { lastMessageReceivedTimeVar } }
    var lastHandshakeReceivedTime: Date { get async { lastHandshakeReceivedTimeVar } }
    var state: PeerConnection.PeerState { get async { .active } }

    var isClosed: Bool { get async { closedVar } }

    private weak var delegate: PeerDelegate?
    private var totalSize: Int64 = 0
    private let pieceLength: Int

    init(url: URL, pieceLength: Int, totalPieces: Int) {
        self.url = url
        self.host = url.host ?? ""
        self.port = UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))
        self.pieceLength = pieceLength

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        self.connection = URLSession(configuration: config)

        self.closedVar = false
        self.bitfieldVar = Array(repeating: true, count: totalPieces)
    }

    func setDelegateInternal(_ d: PeerDelegate) async {
        self.delegate = d
    }

    func connect() async {}

    func disconnect() async {
        closedVar = true
        webSeedState = .closed
    }

    func sendBitfield(_ bits: [Bool]) async {}

    func sendHave(piece: Int) async {}

    func sendCancel(piece: Int, offset: Int, length: Int) async {}

    func sendPEX(added: [(String, UInt16)], dropped: [(String, UInt16)]) async {}

    func requestBlocks(_ requests: [(piece: Int, offset: Int, length: Int)]) async {
        guard webSeedState != .fetching, !closedVar else { return }
        await fetchPieces(requests)
    }

    private func fetchPieces(_ requests: [(piece: Int, offset: Int, length: Int)]) async {
        webSeedState = .fetching
        guard let delegate else { webSeedState = .active; return }

        var totalBytes: Int64 = 0
        let startTime = Date()

        for req in requests {
            let fileOffset = Int64(req.piece) * Int64(pieceLength) + Int64(req.offset)

            do {
                let data = try await fetchBytes(fileOffset: fileOffset, length: req.length)
                guard data.count == req.length else { continue }

                await delegate.peerSentBlock(self, piece: req.piece, offset: req.offset, data: data)
                totalBytes += Int64(data.count)
            } catch {
                break
            }
        }

        if totalBytes > 0 {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > 0 {
                downloadSpeedVar = Int64(Double(totalBytes) / elapsed)
            }
        }

        webSeedState = .active
    }

    private func fetchBytes(fileOffset: Int64, length: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=\(fileOffset)-\(fileOffset + Int64(length) - 1)", forHTTPHeaderField: "Range")

        let (data, response) = try await connection.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebSeedError.invalidResponse
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
            throw WebSeedError.httpError(httpResponse.statusCode)
        }

        if totalSize == 0, let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let cl = Int64(contentLength) {
            totalSize = cl
        }

        return data
    }

    func updateStats() async {
        lastMessageReceivedTimeVar = Date()
    }

    func sendPiece(index: Int, begin: Int, block: Data) async {}

    func sendUnchoke() async {}

    func sendChoke() async {}

    func requestMetadataPiece(_ piece: Int) async {}

    func sendMetadataPiece(_ piece: Int, totalSize: Int, data: Data) async {}

    func sendKeepAliveIfNeeded() async {}
}

enum WebSeedError: Error {
    case invalidResponse
    case httpError(Int)
}