import os

enum Log {
    static let peer    = Logger(subsystem: "com.canopy.engine", category: "peer")
    static let mse     = Logger(subsystem: "com.canopy.engine", category: "mse")
    static let tracker = Logger(subsystem: "com.canopy.engine", category: "tracker")
    static let dht     = Logger(subsystem: "com.canopy.engine", category: "dht")
    static let piece   = Logger(subsystem: "com.canopy.engine", category: "piece")
    static let engine  = Logger(subsystem: "com.canopy.engine", category: "engine")
    static let coord   = Logger(subsystem: "com.canopy.engine", category: "coordinator")
    static let debug   = Logger(subsystem: "com.canopy.engine", category: "debug")
}
