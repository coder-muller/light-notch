import AppKit

let spotifyBundleID = "com.spotify.client"

func fourCC(_ s: StaticString) -> FourCharCode {
    s.withUTF8Buffer { $0.reduce(0) { $0 << 8 | FourCharCode($1) } }
}

func runningSpotify() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: spotifyBundleID).first { !$0.isTerminated }
}

func spotifyIsRunning() -> Bool { runningSpotify() != nil }

final class AppleEvents {
    private let queue = DispatchQueue(label: "LightNotch.Spotify.AppleEvents", qos: .userInitiated)
    private var loggedDenied = false
    private var firstSendDone = false
    private let pendingLock = NSLock()
    private var pendingCommands = 0

    @discardableResult
    func command(_ eventClass: StaticString, _ eventID: StaticString,
                 completion: ((Bool) -> Void)? = nil) -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard pendingCommands < 1 else { return false }
        pendingCommands += 1
        queue.async { [self] in
            let ok: Bool = autoreleasepool {
                do { _ = try send(eventClass, eventID); return true } catch { return false }
            }
            pendingLock.lock()
            pendingCommands -= 1
            pendingLock.unlock()
            if let completion { DispatchQueue.main.async { completion(ok) } }
        }
        return true
    }

    func get(_ specifiers: [NSAppleEventDescriptor], optionalFrom: Int? = nil,
             completion: @escaping ([String]?) -> Void) {
        let optionalFrom = optionalFrom ?? specifiers.count
        queue.async { [self] in
            let values: [String]? = autoreleasepool {
                var values: [String] = []
                for (i, spec) in specifiers.enumerated() {
                    guard let reply = try? send("core", "getd", object: spec) else {
                        if i >= optionalFrom { values.append(""); continue }
                        return nil
                    }
                    switch reply.descriptorType {
                    case typeEnumerated: values.append(String(fourCC: reply.enumCodeValue))
                    case typeBoolean, typeTrue, typeFalse: values.append(reply.booleanValue ? "1" : "0")
                    case typeIEEE64BitFloatingPoint, typeIEEE32BitFloatingPoint, typeSInt32, typeSInt64:
                        values.append(String(reply.doubleValue))
                    default: values.append(reply.stringValue ?? "")
                    }
                }
                return values
            }
            DispatchQueue.main.async { completion(values) }
        }
    }

    func set(_ specifier: NSAppleEventDescriptor, to value: NSAppleEventDescriptor) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard pendingCommands < 1 else { return }
        pendingCommands += 1
        queue.async { [self] in
            autoreleasepool { _ = try? send("core", "setd", object: specifier, data: value) }
            pendingLock.lock()
            pendingCommands -= 1
            pendingLock.unlock()
        }
    }

    private func send(_ eventClass: StaticString, _ eventID: StaticString,
                      object: NSAppleEventDescriptor? = nil,
                      data: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor? {
        guard let app = runningSpotify() else { throw CocoaError(.featureUnsupported) }
        let event = NSAppleEventDescriptor(
            eventClass: fourCC(eventClass), eventID: fourCC(eventID),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: app.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let object { event.setParam(object, forKeyword: keyDirectObject) }
        if let data { event.setParam(data, forKeyword: fourCC("data")) }
        let timeout: TimeInterval = firstSendDone ? 3 : 60
        defer { firstSendDone = true }
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: timeout)
            return reply.paramDescriptor(forKeyword: keyDirectObject)
        } catch {
            if (error as NSError).code == -1743, !loggedDenied {
                loggedDenied = true
                NSLog("LightNotch: Automation access to Spotify was denied. Allow it in System Settings > Privacy & Security > Automation.")
            }
            throw error
        }
    }

    static func property(_ code: StaticString, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: fourCC("obj "))!
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC("prop")), forKeyword: fourCC("want"))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC("prop")), forKeyword: fourCC("form"))
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC(code)), forKeyword: fourCC("seld"))
        spec.setDescriptor(container, forKeyword: fourCC("from"))
        return spec
    }

    private static let track = property("pTrk")
    static let playerState = property("pPlS")
    static let trackID = property("ID  ", of: track)
    static let artworkURL = property("aUrl", of: track)
    static let playerPosition = property("pPos")
    static let shuffling = property("pShu")
    static let repeating = property("pRep")
    static let duration = property("pDur", of: track)
    static let snapshot = [playerState, trackID, property("pnam", of: track),
                           property("pArt", of: track), property("pAlb", of: track), artworkURL]
}

extension String {
    init(fourCC code: FourCharCode) {
        self = String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }
}
