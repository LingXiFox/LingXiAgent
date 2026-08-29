import Foundation

public struct PersistenceMigrationError: Error, Sendable, Equatable {
    public let version: Int

    public init(version: Int) { self.version = version }
}

/// SQLite migration 的唯一入口。调用者负责提供 SQLite transaction；失败时绝不允许以空库替代旧数据。
public enum MigrationRunner {
    public static func migrate(from version: Int, applyV0ToV1: () throws -> Void) throws {
        guard version <= SQLitePersistenceStore.databaseSchemaVersion else {
            throw PersistenceMigrationError(version: version)
        }
        if version == 0 {
            try applyV0ToV1()
        }
    }
}
