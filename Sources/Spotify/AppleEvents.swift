import AppKit

let spotifyBundleID = "com.spotify.client"

func fourCC(_ s: StaticString) -> FourCharCode {
    s.withUTF8Buffer { $0.reduce(0) { $0 << 8 | FourCharCode($1) } }
}

func runningSpotify() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: spotifyBundleID).first { !$0.isTerminated }
}

func spotifyIsRunning() -> Bool { runningSpotify() != nil }

/// Envia Apple Events crus ao Spotify (sem NSAppleScript: o componente AppleScript custa ~14 MB de RAM).
/// Uma fila serial; o alvo é o PID do processo, então nunca abre o Spotify se ele estiver fechado.
final class AppleEvents {
    private let queue = DispatchQueue(label: "LightNotch.Spotify.AppleEvents", qos: .userInitiated)
    private var loggedDenied = false   // confinado à `queue`
    private var firstSendDone = false  // confinado à `queue`
    private let pendingLock = NSLock()
    private var pendingCommands = 0    // protegido por `pendingLock`

    /// Comando sem resposta útil (playpause, next, previous). `completion` (main) recebe se o envio deu certo.
    /// Se já há um comando pendente, descarta o novo (evita acumular cliques com o Spotify travado)
    /// e devolve false, sem chamar `completion`.
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

    /// Lê várias propriedades em sequência num único bloco da fila e entrega as strings na main.
    /// O Spotify não suporta `properties` (pALL), então é um `get` por propriedade (~1 ms cada).
    /// Para no primeiro erro (ex. nada carregado) e entrega nil; os itens a partir de `optionalFrom`
    /// (ex. a URL da capa, ausente em faixa local/anúncio) são opcionais: em erro viram "".
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
                    // Enumerações (player state) viram o próprio código de 4 letras; números, texto com ponto.
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

    /// Define uma propriedade (ex. posição do player). Mesma política de descarte de `command`.
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

    /// Só na `queue`. Mira o PID: se o Spotify fechou, falha em vez de abri-lo.
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
        // Timeout longo só até o 1º envio concluir (sucesso ou erro): ele pode esperar o usuário
        // responder o pedido de Automação. Depois, 3 s, para um Spotify travado não bloquear a fila.
        let timeout: TimeInterval = firstSendDone ? 3 : 60
        defer { firstSendDone = true }
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: timeout)
            return reply.paramDescriptor(forKeyword: keyDirectObject)
        } catch {
            // -1743: Automação negada. Não insiste; avisa só uma vez.
            if (error as NSError).code == -1743, !loggedDenied {
                loggedDenied = true
                NSLog("LightNotch: Automação do Spotify negada. Autorize em Ajustes > Privacidade e Segurança > Automação.")
            }
            throw error
        }
    }

    /// Especificador `property <code> of <container>` (container .null() = a aplicação).
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
    /// Em milissegundos.
    static let duration = property("pDur", of: track)
    /// state, id, name, artist, album, artwork url
    static let snapshot = [playerState, trackID, property("pnam", of: track),
                           property("pArt", of: track), property("pAlb", of: track), artworkURL]
}

extension String {
    init(fourCC code: FourCharCode) {
        self = String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }
}
