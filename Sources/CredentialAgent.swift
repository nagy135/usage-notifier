import Foundation
import Security
import Darwin

@objc protocol CredentialAgentProtocol {
    func credentials(reply: @escaping (Data?, String?) -> Void)
}

/// Owned by the agent's serial queue, independent of any card/window lifetime.
struct CredentialSession {
    private var cached: ClaudeCredentials?
    private var attemptedAuthorization = false
    let readCredentials: (Bool) throws -> ClaudeCredentials
    let claimPrompt: () -> Bool

    mutating func read() throws -> ClaudeCredentials {
        // Pick up credentials refreshed by Claude Code without spending a prompt.
        if let fresh = try? readCredentials(false) {
            cached = fresh
            return fresh
        }
        if let cached { return cached }
        guard !attemptedAuthorization else {
            throw UsageFailure("Claude access was not authorized; try again after your next macOS login")
        }
        attemptedAuthorization = true
        guard claimPrompt() else {
            throw UsageFailure("Claude access was not authorized; try again after your next macOS login")
        }
        let credentials = try readCredentials(true)
        cached = credentials
        return credentials
    }
}

enum CredentialAgentClient {
    static let label = "local.usage-notifier.credentials"

    static func read() throws -> ClaudeCredentials {
        if let credentials = try? ClaudeCredentials.read() { return credentials }
        try install()
        let connection = NSXPCConnection(machServiceName: label)
        connection.remoteObjectInterface = NSXPCInterface(with: CredentialAgentProtocol.self)
        connection.setCodeSigningRequirement("identifier \"local.usage-notifier.app\"")
        connection.resume()
        defer { connection.invalidate() }
        let reply = CredentialReply()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            reply.finish(.failure(UsageFailure("Claude credential helper is unavailable")))
        } as? CredentialAgentProtocol
        guard let proxy else { throw UsageFailure("Could not connect to Claude credential helper") }
        proxy.credentials { data, error in
            do {
                guard let data else { throw UsageFailure(error ?? "Claude credentials unavailable") }
                reply.finish(.success(try ClaudeCredentials.decode(data)))
            } catch { reply.finish(.failure(error)) }
        }
        guard reply.ready.wait(timeout: .now() + 120) == .success else {
            throw UsageFailure("Claude authorization timed out; no further prompts this login")
        }
        return try reply.result().get()
    }

    private static func install() throws {
        guard let executable = Bundle.main.executableURL else {
            throw UsageFailure("Could not locate the credential helper")
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plist = directory.appendingPathComponent(label + ".plist")
        let configuration: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--credential-agent"],
            "MachServices": [label: true],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0)
        if (try? Data(contentsOf: plist)) != data { try data.write(to: plist, options: .atomic) }
        // An already loaded agent stays alive across app rebuilds and keeps its cache.
        // Its job is scoped to gui/<uid>, so logout terminates it and clears tokens.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", "gui/\(getuid())", plist.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // bootstrap returns an error for an existing job. XPC connects to that job.
    }
}

private final class CredentialReply: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Result<ClaudeCredentials, Error>?

    func finish(_ result: Result<ClaudeCredentials, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil else { return }
        value = result
        ready.signal()
    }

    func result() -> Result<ClaudeCredentials, Error> {
        lock.lock()
        defer { lock.unlock() }
        return value ?? .failure(UsageFailure("Claude credentials unavailable"))
    }
}

final class CredentialAgent: NSObject, NSXPCListenerDelegate, CredentialAgentProtocol {
    private let queue = DispatchQueue(label: "local.usage-notifier.credential-read")
    private var session = CredentialSession(
        readCredentials: { try ClaudeCredentials.read(allowInteraction: $0) },
        claimPrompt: { LoginPromptPermit.claim() }
    )

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement("identifier \"local.usage-notifier.app\"")
        connection.exportedInterface = NSXPCInterface(with: CredentialAgentProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func credentials(reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do { reply(try JSONEncoder().encode(self.session.read()), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    static func run() {
        let agent = CredentialAgent()
        let listener = NSXPCListener(machServiceName: CredentialAgentClient.label)
        listener.delegate = agent
        listener.resume()
        withExtendedLifetime(agent) { RunLoop.current.run() }
    }
}

/// Persist only a nonsecret session marker, before prompting, so a crashed or
/// upgraded helper cannot prompt twice in the same login. Never persist tokens.
enum LoginPromptPermit {
    static func claim() -> Bool {
        var session: SecuritySessionId = 0
        guard SessionGetInfo(callerSecuritySession, &session, nil) == errSecSuccess else { return false }
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return false }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/UsageNotifier")
        return claim(session: "\(boot.tv_sec):\(session)", directory: directory)
    }

    static func claim(session: String, directory: URL) -> Bool {
        let marker = directory.appendingPathComponent("credential-prompt-session")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if (try? String(contentsOf: marker, encoding: .utf8)) == session { return false }
            try Data(session.utf8).write(to: marker, options: .atomic)
            return true
        } catch { return false }
    }
}
