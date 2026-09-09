import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

@Suite struct DoctorCLITests {
    private func makeTestStores() throws -> (URL, FileCredentialStore, ConfigurationStore) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-doctor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let credStore = try FileCredentialStore(dataRoot: tempDir, passphrase: "test-passphrase-1234")
        let configStore = try ConfigurationStore(dataRoot: tempDir)
        return (tempDir, credStore, configStore)
    }

    @Test func doctorRunsAndProducesHealthReport() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await DoctorCLI.run(
            dataRoot: dir,
            projectRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        #expect(output.contains("LingXiAgent Doctor"))
        #expect(output.contains("Operating System"))
        #expect(output.contains("Data & Config Root"))
        #expect(output.contains("Secure Vault"))
        #expect(output.contains("Providers & Models"))
        #expect(output.contains("Status:"))
    }

    @Test func doctorEvaluatesHealthyVault() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = await DoctorCLI.evaluate(
            dataRoot: dir,
            projectRoot: dir,
            credStore: credStore,
            configStore: configStore
        )

        #expect(report.isHealthy == true)
        #expect(report.vaultStatus.contains("AES-256-GCM Vault operational"))
        #expect(report.storageStatus.contains("secure"))
    }
}
