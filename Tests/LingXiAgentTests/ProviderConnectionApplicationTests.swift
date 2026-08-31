import Foundation
import Testing
import LingXiApplication
import LingXiClient
import LingXiProtocol
@testable import LingXiCore

struct ProviderConnectionApplicationTests {
    @Test func apiKeyConnectionIsProductDrivenAndDoesNotExposeSecretInState() async throws {
        let endpoint = FakeProviderEndpoint(products: [product(id: "api", auth: .bearerToken)])
        let service = ProviderConnectionService(client: .inProcess(endpoint: endpoint))
        let flowID = try await service.beginConnection(productID: "api")
        #expect(try await service.state(flowID: flowID) == .requestingCredential(.apiKey))
        let state = try await service.submitCredential(flowID: flowID, credential: "secret-value")
        guard case let .connected(account) = state else { Issue.record("expected connected state"); return }
        #expect(account.productID == "api")
        #expect(await endpoint.createdRequest?.credentialRef != nil)
        #expect(!(try await service.state(flowID: flowID) == .failed))
    }

    @Test func localConnectionRequestsEndpointWithoutCredential() async throws {
        let endpoint = FakeProviderEndpoint(products: [product(id: "local", auth: .none, local: true)])
        let service = ProviderConnectionService(client: .inProcess(endpoint: endpoint))
        let flowID = try await service.beginConnection(productID: "local")
        #expect(try await service.state(flowID: flowID) == .requestingLocalEndpoint)
        let state = try await service.submitLocalEndpoint(flowID: flowID, endpoint: "http://127.0.0.1:1234/v1")
        guard case .connected = state else { Issue.record("expected connected state"); return }
        #expect(await endpoint.createdRequest?.credentialRef == nil)
    }

    @Test func requiredMetadataIsSubmittedBeforeAccountCreation() async throws {
        let endpoint = FakeProviderEndpoint(products: [product(id: "regional", auth: .bearerToken, fields: ["region", "workspace"])])
        let service = ProviderConnectionService(client: .inProcess(endpoint: endpoint))
        let flowID = try await service.beginConnection(productID: "regional")
        _ = try await service.submitCredential(flowID: flowID, credential: "regional-secret")
        #expect(try await service.state(flowID: flowID) == .requestingAccountFields(["region", "workspace"]))
        _ = try await service.submitAccountFields(flowID: flowID, fields: ["region": "cn", "workspace": "workspace-1"])
        #expect(await endpoint.createdRequest?.fields == ["region": "cn", "workspace": "workspace-1"])
    }

    @Test func unverifiedProductIsNotConnectable() async throws {
        let endpoint = FakeProviderEndpoint(products: [product(id: "unverified", auth: .bearerToken, verified: false)])
        let service = ProviderConnectionService(client: .inProcess(endpoint: endpoint))
        #expect((try? await service.listConnectableProducts())?.isEmpty == true)
        do {
            _ = try await service.beginConnection(productID: "unverified")
            Issue.record("unverified product should be rejected")
        } catch let error as ProviderConnectionError {
            #expect(error == .productNotConnectable)
        }
    }

    @Test func credentialAndAccountFailuresLeaveNoCredentialThroughCleanup() async throws {
        let endpoint = FakeProviderEndpoint(products: [product(id: "api", auth: .bearerToken)], failCredential: true)
        let service = ProviderConnectionService(client: .inProcess(endpoint: endpoint))
        let failedFlow = try await service.beginConnection(productID: "api")
        do { _ = try await service.submitCredential(flowID: failedFlow, credential: "secret") } catch {}
        #expect(try await service.state(flowID: failedFlow) == .failed)

        let accountEndpoint = FakeProviderEndpoint(products: [product(id: "api", auth: .bearerToken)], failAccount: true)
        let accountService = ProviderConnectionService(client: .inProcess(endpoint: accountEndpoint))
        let accountFlow = try await accountService.beginConnection(productID: "api")
        do { _ = try await accountService.submitCredential(flowID: accountFlow, credential: "secret") } catch {}
        #expect(await accountEndpoint.deletedCredentialCount == 1)
    }

    @Test func cancellationCleansPendingCredentialAndDisconnectDelegatesSharedCredentialPolicy() async throws {
        let endpoint = FakeProviderEndpoint(products: [product(id: "api", auth: .bearerToken)])
        let service = ProviderConnectionService(client: .inProcess(endpoint: endpoint))
        let flowID = try await service.beginConnection(productID: "api")
        try await service.cancelConnection(flowID: flowID)
        #expect(await endpoint.deletedCredentialCount == 0)

        _ = try await service.disconnect(accountID: "account", deleteUnusedCredential: false)
        #expect(await endpoint.deletedAccountIDs == ["account"])
        #expect(await endpoint.lastDeleteUnusedCredential == false)
    }

    @Test func applicationUsesCorePrimitivesForPersistenceWithoutPuttingSecretInProvidersJSON() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configurationStore = try ConfigurationStore(dataRoot: root)
        let credentialStore = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase")
        let host = try CoreHost(configurationStore: configurationStore, credentialStore: credentialStore)
        await host.start()
        defer { Task { await host.shutdown() } }

        let service = ProviderConnectionService(client: .inProcess(endpoint: host))
        let products = try await service.listConnectableProducts()
        #expect(products.contains(where: { $0.id == "openai-api" }))
        let flowID = try await service.beginConnection(productID: "openai-api")
        let state = try await service.submitCredential(flowID: flowID, credential: "integration-secret")
        guard case let .connected(account) = state else { Issue.record("expected Core-backed connection"); return }
        #expect(account.credentialRef != nil)
        let providersJSON = try String(contentsOf: root.appendingPathComponent("providers.json"), encoding: .utf8)
        #expect(!providersJSON.contains("integration-secret"))
        let accounts = try await service.accounts()
        let accountWasPersisted = accounts.contains { $0.id == account.id && $0.credentialRef == account.credentialRef }
        #expect(accountWasPersisted)
        let disconnected = try await service.disconnect(accountID: account.id, deleteUnusedCredential: false)
        #expect(disconnected.credentialDeleted == false)
        #expect(try await credentialStore.secret(for: account.credentialRef!) == "integration-secret")
    }

    @Test func disconnectDoesNotDeleteASharedCredentialUntilTheLastAccountIsGone() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configurationStore = try ConfigurationStore(dataRoot: root)
        let credentialStore = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase")
        let host = try CoreHost(configurationStore: configurationStore, credentialStore: credentialStore)
        await host.start()
        defer { Task { await host.shutdown() } }

        let client = LingXiClient.inProcess(endpoint: host)
        let reference = try await client.storeProviderCredential("shared-secret")
        let first = try await client.createProviderAccount(ProviderAccountCreateRequest(id: "first", productID: "openai-api", displayName: "First", accountType: .apiKey, credentialRef: reference, authentication: .bearer))
        _ = try await client.createProviderAccount(ProviderAccountCreateRequest(id: "second", productID: "openai-api", displayName: "Second", accountType: .apiKey, credentialRef: reference, authentication: .bearer))

        let firstResult = try await client.disconnectProviderAccount(first.id, deleteUnusedCredential: true)
        #expect(firstResult.credentialDeleted == false)
        #expect(try await credentialStore.secret(for: reference) == "shared-secret")
        let secondResult = try await client.disconnectProviderAccount("second", deleteUnusedCredential: true)
        #expect(secondResult.credentialDeleted == true)
        #expect(try await credentialStore.secret(for: reference) == nil)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-p14-application-\(UUID().uuidString)", isDirectory: true)
    }

    private func product(id: String, auth: ProviderRequestAuthentication, local: Bool = false, fields: [String] = [], verified: Bool = true) -> ProviderProductSummary {
        ProviderProductSummary(id: id, displayName: id, vendorID: "test", type: local ? .localRuntime : .cloudAPI, accountTypes: local ? [.anonymousLocal] : [.apiKey], requestAuthentication: auth, requestAuthenticationHeaderName: nil, requiresCredential: auth != .none, requiresLocalEndpoint: local, requiredAccountFields: fields, verificationStatus: verified ? .verified : .unverified, connectable: verified)
    }

    private actor FakeProviderEndpoint: CoreEndpoint {
        let products: [ProviderProductSummary]
        let failCredential: Bool
        let failAccount: Bool
        private(set) var createdRequest: ProviderAccountCreateRequest?
        private(set) var deletedCredentialCount = 0
        private(set) var deletedAccountIDs: [String] = []
        private(set) var lastDeleteUnusedCredential: Bool?

        init(products: [ProviderProductSummary], failCredential: Bool = false, failAccount: Bool = false) {
            self.products = products; self.failCredential = failCredential; self.failAccount = failAccount
        }

        func handle(_ command: ClientCommand) async throws -> CoreResponse {
            switch command {
            case .listProviderProducts: return .providerProducts(products)
            case .listProviderAccounts: return .providerAccounts([])
            case .storeProviderCredential:
                if failCredential { return .error(CoreError(code: .persistence, message: "credential write failed")) }
                return .providerCredential(ProviderCredentialResult(reference: CredentialRef("fake-credential")))
            case let .createProviderAccount(request):
                if failAccount { return .error(CoreError(code: .provider, message: "account create failed")) }
                createdRequest = request
                return .providerAccount(ProviderAccountInfo(id: "account", productID: request.productID, displayName: request.displayName, accountType: request.accountType, credentialRef: request.credentialRef, endpoint: request.endpoint, availability: "configured"))
            case let .deleteProviderAccount(accountID, deleteUnusedCredential):
                deletedAccountIDs.append(accountID); lastDeleteUnusedCredential = deleteUnusedCredential
                return .providerDisconnected(ProviderDisconnectResult(accountID: accountID, credentialDeleted: false))
            case .deleteProviderCredential:
                deletedCredentialCount += 1
                return .providerCredential(ProviderCredentialResult(reference: CredentialRef("fake-credential")))
            default: return .error(CoreError(code: .unsupportedCommand, message: "unsupported in fake"))
            }
        }

        func openDataStream(_ command: ClientCommand) async throws -> OpenedStream { throw CoreError(code: .unsupportedCommand, message: "unsupported") }
        func toolOutputEvents() async -> AsyncStream<ToolOutputChunk> { AsyncStream { $0.finish() } }
        func events() async -> AsyncStream<CoreEvent> { AsyncStream { $0.finish() } }
    }
}
