// Recording.swift — one row of Apple's ZCLOUDRECORDING table.

import Foundation

/// Seconds between the 2001 Core Data reference epoch and the 1970 unix epoch.
public let coreDataEpochOffset: Double = 978_307_200

/// Convert a Core Data `ZDATE` value (seconds since 2001) to a unix `Date`.
public func dateFromCoreData(_ zdate: Double) -> Date {
    Date(timeIntervalSince1970: zdate + coreDataEpochOffset)
}

public struct Recording: Sendable, Equatable {
    /// `ZUNIQUEID` — stable UUID, also embedded in the `.m4a` as `voice-memo-uuid`.
    public let id: String
    public let recordedAt: Date
    public let duration: Double
    public let title: String
    /// Absolute path to the `.m4a` within the Recordings directory.
    public let m4aPath: String

    public init(id: String, recordedAt: Date, duration: Double, title: String, m4aPath: String) {
        self.id = id
        self.recordedAt = recordedAt
        self.duration = duration
        self.title = title
        self.m4aPath = m4aPath
    }
}
