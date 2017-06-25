import Foundation
import PackStream
import Bolt
import Result

#if os(Linux)
import Dispatch
#endif

public struct QueryWithParameters {
    let query: String
    let parameters: Dictionary<String,Any>
}

public class Transaction {

    public var succeed: Bool = true
    public var bookmark: String? = nil
    public var autocommit: Bool = true
    internal var commitBlock: (Bool) throws -> Void = { _ in }

    public init() {
    }

    public func markAsFailed() {
        succeed = false
    }
}

typealias BoltRequest = Bolt.Request

open class BoltClient {

    private let hostname: String
    private let port: Int
    private let username: String
    private let password: String
    private let encrypted: Bool
    private let connection: Connection

    private var currentTransaction: Transaction?

    required public init(hostname: String = "localhost", port: Int = 7687, username: String = "neo4j", password: String = "neo4j", encrypted: Bool = true) throws {

        self.hostname = hostname
        self.port = port
        self.username = username
        self.password = password
        self.encrypted = encrypted

        let settings = ConnectionSettings(username: username, password: password, userAgent: "Theo 3.2.0")

        let noConfig = SSLConfiguration(json: [:])
        let configuration = EncryptedSocket.defaultConfiguration(sslConfig: noConfig,
            allowHostToBeSelfSigned: true)

        let socket = try EncryptedSocket(
            hostname: hostname,
            port: port,
            configuration: configuration)

        self.connection = Connection(
            socket: socket,
            settings: settings)
    }
    
    public enum BoltClientError: Error {
        case notImplemented // TODO: Remove me
        case syntaxError(message: String)
    }

    public func connect(completionBlock: ((Bool) -> ())? = nil) throws {

        if let completionBlock = completionBlock {
            try self.connection.connect { (success) in
                completionBlock(success)
            }
        }

        else {
            let dispatchGroup = DispatchGroup()
            dispatchGroup.enter()
            try self.connection.connect { (success) in
                dispatchGroup.leave()
            }
            dispatchGroup.wait()
        }

    }


    private func pullSynchronouslyAndIgnore() throws {
        let dispatchGroup = DispatchGroup()
        let pullRequest = BoltRequest.pullAll()
        dispatchGroup.enter()
        try self.connection.request(pullRequest) { (success, response) in

            if let bookmark = self.getBookmark() {
                currentTransaction?.bookmark = bookmark
            }
            dispatchGroup.leave()
        }
        dispatchGroup.wait()

    }

    public func pullAll(completionBlock: (Bool, [Response]) -> ()) throws {
        let pullRequest = BoltRequest.pullAll()
        try self.connection.request(pullRequest) { (success, response) in
            completionBlock(success, response)
        }

    }

    public func executeAsTransaction(bookmark: String? = nil, transactionBlock: @escaping (_ tx: Transaction) throws -> ()) throws {

        let transactionGroup = DispatchGroup()

        let transaction = Transaction()
        transaction.commitBlock = { succeed in
            if succeed {
                let commitRequest = BoltRequest.run(statement: "COMMIT", parameters: Map(dictionary: [:]))
                try self.connection.request(commitRequest) { (success, response) in
                    try self.pullSynchronouslyAndIgnore()
                    if !success {
                        print("Error committing transaction: \(response)")
                    }
                    self.currentTransaction = nil
                    transactionGroup.leave()
                }
            } else {

                let rollbackRequest = BoltRequest.run(statement: "ROLLBACK", parameters: Map(dictionary: [:]))
                try self.connection.request(rollbackRequest) { (success, response) in
                    try self.pullSynchronouslyAndIgnore()
                    if !success {
                        print("Error rolling back transaction: \(response)")
                    }
                    self.currentTransaction = nil
                    transactionGroup.leave()
                }
            }
        }

        currentTransaction = transaction

        let beginRequest = BoltRequest.run(statement: "BEGIN", parameters: Map(dictionary: [:]))

        transactionGroup.enter()

        try connection.request(beginRequest) { (success, response) in
            if success {

                try pullSynchronouslyAndIgnore()

                try transactionBlock(transaction)
                if transaction.autocommit == true {
                    try transaction.commitBlock(transaction.succeed)
                    transaction.commitBlock = { _ in }
                }

            } else {
                print("Error beginning transaction: \(response)")
                transaction.commitBlock = { _ in }
                transactionGroup.leave()
            }
        }

        transactionGroup.wait()
    }

    public func executeTransaction(parameteredQueries: [QueryWithParameters], completionBlock: ClientProtocol.TheoCypherQueryCompletionBlock? = nil) -> Void {

    }

    public typealias QueryMetaResult = [Bolt.Response]
    public typealias QueryResult = [Bolt.Response]
    
    
    public func executeCypher(_ query: String, params: Dictionary<String,PackProtocol>? = nil) -> Result<(QueryMetaResult, QueryResult), BoltClientError> {

        var success = false
        
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        
        var queryMetaResult: QueryMetaResult? = nil
        var queryResult: QueryResult? = nil
        
        let cypherRequest = BoltRequest.run(statement: query, parameters: Map(dictionary: params ?? [:]))
        do {
            try connection.request(cypherRequest) { (theSuccess, response) in
                queryMetaResult = response
                success = theSuccess
                
                if theSuccess == true {
                    let pullRequest = BoltRequest.pullAll()
                    try self.connection.request(pullRequest) { (theSuccess, response) in
                        queryResult = response
                        success = theSuccess
                        
                        if let currentTransaction = self.currentTransaction,
                            theSuccess == false {
                            currentTransaction.markAsFailed()
                        }
                        
                        dispatchGroup.leave()
                    }
                    
                } else {
                    if let currentTransaction = self.currentTransaction {
                        currentTransaction.markAsFailed()
                    }
                    dispatchGroup.leave()
                }
            }
            
            dispatchGroup.wait()
        } catch (let error as Response.ResponseError) {
            
            switch error {
            case let .syntaxError(message: message):
                return .failure(BoltClientError.syntaxError(message: message))
            default:
                print(error)
                assert(false)
                return .failure(BoltClientError.notImplemented) // TODO: Return proper error
                
            }
            
        } catch (let error) {
            print(error)
            assert(false)
            return .failure(BoltClientError.notImplemented) // TODO: Return proper error

        }

        if success,
            let queryMetaResult = queryMetaResult,
            let queryResult = queryResult {
            return .success((queryMetaResult, queryResult))
        } else {
            return .failure(BoltClientError.notImplemented)
        }
    }

    public func executeCypher(_ query: String, params: Dictionary<String,PackProtocol>? = nil, completionBlock: ((Bool) throws -> ())) throws -> Void {

        let cypherRequest = BoltRequest.run(statement: query, parameters: Map(dictionary: params ?? [:]))

        try connection.request(cypherRequest) { (success, response) in
            try completionBlock(success)
        }
    }

    public func getBookmark() -> String? {
        return connection.currentTransactionBookmark
    }

}

extension BoltClient {
    open func fetchNode(_ nodeID: NodeID, completionBlock: ClientProtocol.TheoNodeRequestCompletionBlock? = nil) -> Void {
    }
    
    open func createNode(_ node: Node, completionBlock: ClientProtocol.TheoNodeRequestCompletionBlock? = nil) -> Void {
    }
    
    open func createNode(_ node: Node, labels: Array<String>, completionBlock: ClientProtocol.TheoNodeRequestCompletionBlock? = nil) -> Void {
    }
    
    open func updateNode(_ node: Node, properties: Dictionary<String,Any>, completionBlock: ClientProtocol.TheoNodeRequestCompletionBlock? = nil) -> Void {
    }
    
    open func deleteNode(_ nodeID: NodeID, completionBlock: ClientProtocol.TheoNodeRequestDeleteCompletionBlock? = nil) -> Void {
    }
    
    open func fetchRelationshipsForNode(_ nodeID: NodeID, direction: String? = nil, types: Array<String>? = nil, completionBlock: ClientProtocol.TheoRelationshipRequestCompletionBlock? = nil) -> Void {
    }
    
    open func createRelationship(_ relationship: Relationship, completionBlock: ClientProtocol.TheoNodeRequestRelationshipCompletionBlock? = nil) -> Void {
    }
    
    open func updateRelationship(_ relationship: Relationship, properties: Dictionary<String,Any>, completionBlock: ClientProtocol.TheoNodeRequestRelationshipCompletionBlock? = nil) -> Void {
    }
    
    open func deleteRelationship(_ relationshipID: String, completionBlock: ClientProtocol.TheoNodeRequestDeleteCompletionBlock? = nil) -> Void {
    }
    
    open func executeTransaction(_ statements: Array<Dictionary<String, Any>>, completionBlock: ClientProtocol.TheoTransactionCompletionBlock? = nil) -> Void {
    }
    
    open func executeRequest(_ uri: String, completionBlock: ClientProtocol.TheoRawRequestCompletionBlock? = nil) -> Void {
    }
    
    open func executeCypher(_ query: String, params: Dictionary<String,Any>? = nil, completionBlock: ClientProtocol.TheoCypherQueryCompletionBlock? = nil) -> Void {
    }
}
