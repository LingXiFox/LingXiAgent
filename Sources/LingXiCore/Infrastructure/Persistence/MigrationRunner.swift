import Foundation

public struct PersistenceMigrationError: Error, Sendable, Equatable {
    public let version: Int

    public init(version: Int) { self.version = version }
}

/// SQLite migration 的唯一入口。调用者负责提供 SQLite transaction；失败时绝不允许以空库替代旧数据。
public enum MigrationRunner {

    /// 单步数据库迁移定义。
    public struct SchemaMigration: Sendable {
        public let from: Int
        public let apply: @Sendable () throws -> Void

        public init(from: Int, apply: @escaping @Sendable () throws -> Void) {
            self.from = from
            self.apply = apply
        }
    }

    /// 阶梯式执行数据库迁移。
    public static func migrate(
        from version: Int,
        targetVersion: Int = SQLitePersistenceStore.databaseSchemaVersion,
        migrations: [SchemaMigration]
    ) throws {
        guard version <= targetVersion else {
            throw PersistenceMigrationError(version: version)
        }
        for migration in migrations.sorted(by: { $0.from < $1.from }) {
            if version <= migration.from {
                try migration.apply()
            }
        }
    }

    @available(*, deprecated, message: "Use migrate(from:targetVersion:migrations:) with SchemaMigration ladder instead")
    public static func migrate(from version: Int, applyV0ToV1: () throws -> Void) throws {
        try migrate(from: version, applyV0ToV1: applyV0ToV1, applyV1ToV2: {}, applyV2ToV3: {}, applyV3ToV4: {}, applyV4ToV5: {}, applyV5ToV6: {})
    }

    @available(*, deprecated, message: "Use migrate(from:targetVersion:migrations:) with SchemaMigration ladder instead")
    public static func migrate(from version: Int, applyV0ToV1: () throws -> Void, applyV1ToV2: () throws -> Void) throws {
        try migrate(from: version, applyV0ToV1: applyV0ToV1, applyV1ToV2: applyV1ToV2, applyV2ToV3: {}, applyV3ToV4: {}, applyV4ToV5: {}, applyV5ToV6: {})
    }

    @available(*, deprecated, message: "Use migrate(from:targetVersion:migrations:) with SchemaMigration ladder instead")
    public static func migrate(from version: Int, applyV0ToV1: () throws -> Void, applyV1ToV2: () throws -> Void, applyV2ToV3: () throws -> Void) throws {
        try migrate(from: version, applyV0ToV1: applyV0ToV1, applyV1ToV2: applyV1ToV2, applyV2ToV3: applyV2ToV3, applyV3ToV4: {}, applyV4ToV5: {}, applyV5ToV6: {})
    }

    @available(*, deprecated, message: "Use migrate(from:targetVersion:migrations:) with SchemaMigration ladder instead")
    public static func migrate(from version: Int, applyV0ToV1: () throws -> Void, applyV1ToV2: () throws -> Void, applyV2ToV3: () throws -> Void, applyV3ToV4: () throws -> Void, applyV4ToV5: () throws -> Void, applyV5ToV6: () throws -> Void, applyV6ToV7: () throws -> Void = {}) throws {
        guard version <= SQLitePersistenceStore.databaseSchemaVersion else {
            throw PersistenceMigrationError(version: version)
        }
        if version == 0 { try applyV0ToV1() }
        if version <= 1 { try applyV1ToV2() }
        if version <= 2 { try applyV2ToV3() }
        if version <= 3 { try applyV3ToV4() }
        if version <= 4 { try applyV4ToV5() }
        if version <= 5 { try applyV5ToV6() }
        if version <= 6 { try applyV6ToV7() }
    }
}
