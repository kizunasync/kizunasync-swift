import Foundation
#if canImport(KsyncFfi)
import KsyncFfi
#endif

/// One attachment column: Storage bucket + owner column used to derive the object key.
public struct KsyncAttachmentSpec: Equatable, Sendable {
  public var storageBucket: String
  public var ownerColumn: String

  public init(storageBucket: String, ownerColumn: String) {
    self.storageBucket = storageBucket
    self.ownerColumn = ownerColumn
  }
}

/// Table declaration that encodes to the UniFFI `create` JSON.
public struct KsyncTableConfig: Equatable, Sendable {
  public var bucketColumn: String
  public var bucketParams: [String: String]
  public var attachments: [String: KsyncAttachmentSpec]

  public init(
    bucketColumn: String = "user_id",
    bucketParams: [String: String] = [:],
    attachments: [String: KsyncAttachmentSpec] = [:]
  ) {
    self.bucketColumn = bucketColumn
    self.bucketParams = bucketParams
    self.attachments = attachments
  }
}

/// PostgREST remote. A present remote must have url + anonKey; the engine
/// rejects null/incomplete objects instead of falling back to ScriptedRemote.
public struct KsyncRemoteConfig: Equatable, Sendable {
  public var url: String
  public var anonKey: String
  public var accessToken: String?
  public var schema: String?
  public var localOnlyColumns: [String]

  public init(
    url: String,
    anonKey: String,
    accessToken: String? = nil,
    schema: String? = nil,
    localOnlyColumns: [String] = []
  ) {
    self.url = url
    self.anonKey = anonKey
    self.accessToken = accessToken
    self.schema = schema
    self.localOnlyColumns = localOnlyColumns
  }
}

/// Typed `create(config_json)` payload.
public struct KsyncClientConfig: Equatable, Sendable {
  public var clientId: String
  public var schemaVersion: Int
  public var tables: [String: KsyncTableConfig]
  public var databasePath: String?
  public var remote: KsyncRemoteConfig?
  public var attachmentRoot: String?

  public init(
    clientId: String,
    schemaVersion: Int = 1,
    tables: [String: KsyncTableConfig],
    databasePath: String? = nil,
    remote: KsyncRemoteConfig? = nil,
    attachmentRoot: String? = nil
  ) {
    self.clientId = clientId
    self.schemaVersion = schemaVersion
    self.tables = tables
    self.databasePath = databasePath
    self.remote = remote
    self.attachmentRoot = attachmentRoot
  }

  public var declaresAttachments: Bool {
    tables.values.contains { !$0.attachments.isEmpty }
  }

  public func jsonObject() -> [String: Any] {
    var object: [String: Any] = [
      "client_id": clientId,
      "schema_version": schemaVersion,
      "tables": tables.mapValues { table -> [String: Any] in
        var encoded: [String: Any] = [
          "bucket_column": table.bucketColumn,
          "bucket_params": table.bucketParams,
        ]
        if !table.attachments.isEmpty {
          encoded["attachments"] = table.attachments.mapValues { spec in
            [
              "storage_bucket": spec.storageBucket,
              "owner_column": spec.ownerColumn,
            ]
          }
        }
        return encoded
      },
    ]
    if let databasePath {
      object["database_path"] = databasePath
    }
    if let remote {
      var remoteObject: [String: Any] = [
        "url": remote.url,
        "anon_key": remote.anonKey,
      ]
      if let accessToken = remote.accessToken {
        remoteObject["access_token"] = accessToken
      }
      if let schema = remote.schema {
        remoteObject["schema"] = schema
      }
      if !remote.localOnlyColumns.isEmpty {
        remoteObject["local_only_columns"] = remote.localOnlyColumns
      }
      object["remote"] = remoteObject
    }
    if let attachmentRoot {
      object["attachment_root"] = attachmentRoot
    }
    return object
  }

  public func jsonString() throws -> String {
    let data = try JSONSerialization.data(withJSONObject: jsonObject(), options: [])
    guard let string = String(data: data, encoding: .utf8) else {
      throw KsyncError.engine("config is not utf8")
    }
    return string
  }
}

public enum KsyncOp: String, Sendable {
  case insert
  case update
  case delete
}

/// Minimal query-plan helpers. They serialize the local AST; they are not a
/// second query engine.
public enum KsyncQuery {
  public static func eq(_ column: String, _ value: Any) -> [String: Any] {
    ["kind": "eq", "column": column, "value": value]
  }

  public static func order(_ column: String, ascending: Bool = true) -> [String: Any] {
    ["column": column, "ascending": ascending]
  }

  public static func plan(
    filters: [[String: Any]] = [],
    order: [[String: Any]] = [],
    limit: Int? = nil,
    cardinality: String = "many"
  ) -> [String: Any] {
        var plan: [String: Any] = ["filters": filters, "cardinality": cardinality]
    if !order.isEmpty {
      plan["orders"] = order
    }
    if let limit {
      plan["limit"] = limit
    }
    return plan
  }

  public static func many(filters: [[String: Any]] = []) -> [String: Any] {
    plan(filters: filters, cardinality: "many")
  }

  public static func single(filters: [[String: Any]] = []) -> [String: Any] {
    plan(filters: filters, cardinality: "single")
  }
}

#if canImport(KsyncFfi)

public typealias KsyncEngineEvent = FfiEngineEvent
public typealias KsyncAttachmentStatus = FfiAttachmentStatus
public typealias KsyncRejection = FfiRejection
public typealias KsyncCheckpoint = FfiCheckpoint
public typealias KsyncFromFileResult = FfiFromFileResult

private final class HostEventObserver: EventObserver, @unchecked Sendable {
  let handler: @Sendable (FfiEngineEvent) -> Void
  init(_ handler: @escaping @Sendable (FfiEngineEvent) -> Void) {
    self.handler = handler
  }
  func onEvent(event: FfiEngineEvent) {
    handler(event)
  }
}

private final class HostAttachmentListener: AttachmentListener, @unchecked Sendable {
  let handler: @Sendable (FfiAttachmentStatus) -> Void
  init(_ handler: @escaping @Sendable (FfiAttachmentStatus) -> Void) {
    self.handler = handler
  }
  func onStatus(status: FfiAttachmentStatus) {
    handler(status)
  }
}

/// Idiomatic host over the generated UniFFI engine. Every call hops off the
/// calling thread so `sync()` cannot block the iOS main actor.
public final class KsyncClient: @unchecked Sendable {
  private let engine = KsyncFfi.KsyncEngine()

  public init() {}

  public func create(_ config: KsyncClientConfig) async throws {
    if config.declaresAttachments && config.attachmentRoot == nil {
      throw KsyncError.engine(
        "ATTACHMENT_PORTS_MISSING: a table declares attachments but attachmentRoot is unset"
      )
    }
    let json = try config.jsonString()
    try await runOffCallingThread { try self.engine.create(configJson: json) }
  }

  public func apply(
    table: String,
    pk: String,
    op: KsyncOp,
    columns: [String: Any] = [:],
    mutationId: String? = nil,
    transforms: [String: Any]? = nil,
    precondition: [String: Any]? = nil
  ) async throws {
    if table.isEmpty || pk.isEmpty {
      throw KsyncError.engine("apply requires table and pk")
    }
    var mutation: [String: Any] = [
      "table": table,
      "pk": pk,
      "op": op.rawValue,
      "columns": columns,
    ]
    if let mutationId {
      mutation["mutation_id"] = mutationId
    }
    if let transforms {
      mutation["transforms"] = transforms
    }
    if let precondition {
      mutation["precondition"] = precondition
    }
    let json = try encode(mutation)
    try await runOffCallingThread { try self.engine.apply(mutationJson: json) }
  }

  public func applyWhere(
    table: String,
    op: KsyncOp,
    filters: [[String: Any]],
    columns: [String: Any] = [:],
    transforms: [String: Any]? = nil,
    precondition: [String: Any]? = nil
  ) async throws -> [String] {
    try await runOffCallingThread {
      try self.engine.applyWhere(
        table: table,
        op: op.rawValue,
        filtersJson: try self.encode(filters),
        columnsJson: try self.encode(columns),
        transformsJson: try self.encode(transforms ?? [:]),
        preconditionJson: try self.encode(precondition ?? [:])
      )
    }
  }

  public func query(table: String, plan: [String: Any] = [:]) async throws -> Any {
    let raw = try await runOffCallingThread {
      try self.engine.queryTable(table: table, planJson: try self.encode(plan))
    }
    return try JSONSerialization.jsonObject(
      with: Data(raw.utf8),
      options: [.fragmentsAllowed]
    )
  }

  public func sync() async throws {
    try await runOffCallingThread { try self.engine.sync() }
  }

  public func pullOnce() async throws {
    try await runOffCallingThread { try self.engine.pullOnce() }
  }

  public func pushOnce() async throws {
    try await runOffCallingThread { try self.engine.pushOnce() }
  }

  public func outboxDepth() async throws -> Int {
    try await runOffCallingThread { Int(try self.engine.outboxDepth()) }
  }

  public func setAccessToken(_ token: String?) async throws {
    try await runOffCallingThread { try self.engine.setAccessToken(token: token) }
  }

  public func setBucket(_ params: [String: Any]) async throws {
    try await runOffCallingThread {
      try self.engine.setBucket(paramsJson: try self.encode(params))
    }
  }

  public func rejections(includeDismissed: Bool = false) async throws -> [KsyncRejection] {
    try await runOffCallingThread {
      try self.engine.rejections(includeDismissed: includeDismissed)
    }
  }

  public func dismissRejection(_ mutationId: String) async throws -> Bool {
    try await runOffCallingThread {
      try self.engine.dismissRejection(mutationId: mutationId)
    }
  }

  public func reset() async throws -> [String] {
    try await runOffCallingThread { try self.engine.reset() }
  }

  public func checkpoint() async throws -> KsyncCheckpoint {
    try await runOffCallingThread { try self.engine.checkpoint() }
  }

  public func seedCheckpoint(_ cursor: String) async throws {
    try await runOffCallingThread { try self.engine.seedCheckpoint(cursor: cursor) }
  }

  /// Subscribe to engine events. Returns an unsubscribe function.
  public func on(_ handler: @escaping @Sendable (KsyncEngineEvent) -> Void) async throws -> @Sendable () -> Void {
    let observer = HostEventObserver(handler)
    let id = try await runOffCallingThread {
      try self.engine.subscribe(observer: observer)
    }
    return {
      Task { try? await self.runOffCallingThread { try self.engine.unsubscribe(subscriptionId: id) } }
    }
  }

  public func fromFile(
    table: String,
    column: String,
    pk: String,
    sourcePath: String,
    mediaType: String? = nil
  ) async throws -> KsyncFromFileResult {
    try await runOffCallingThread {
      try self.engine.fromFile(
        table: table,
        column: column,
        pk: pk,
        sourcePath: sourcePath,
        mediaType: mediaType
      )
    }
  }

  public func resolveDownload(_ reference: String) async throws -> String? {
    try await runOffCallingThread { try self.engine.resolveDownload(reference: reference) }
  }

  public func vacuum() async throws {
    try await runOffCallingThread { try self.engine.vacuum() }
  }

  public func getStatus(_ reference: String) async throws -> KsyncAttachmentStatus? {
    try await runOffCallingThread { try self.engine.getStatus(reference: reference) }
  }

  public func watch(
    _ reference: String,
    onStatus: @escaping @Sendable (KsyncAttachmentStatus) -> Void
  ) async throws -> @Sendable () -> Void {
    let listener = HostAttachmentListener(onStatus)
    let id = try await runOffCallingThread {
      try self.engine.watch(reference: reference, listener: listener)
    }
    return {
      Task { try? await self.runOffCallingThread { try self.engine.unwatch(watchId: id) } }
    }
  }

  private func encode(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    guard let json = String(data: data, encoding: .utf8) else {
      throw KsyncError.engine("payload is not utf8")
    }
    return json
  }

  private func runOffCallingThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) {
      do {
        return try body()
      } catch let error as KsyncFfiError {
        throw mapFfi(error)
      }
    }.value
  }
}

private func mapFfi(_ error: KsyncFfiError) -> KsyncError {
  switch error {
  case .Engine(let code, let msg):
    return .engine("\(code): \(msg)")
  }
}

#endif
