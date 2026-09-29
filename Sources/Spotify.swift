import AppKit

struct NowPlaying: Equatable {
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
}

// MARK: - Apple Events

private let spotifyBundleID = "com.spotify.client"

private func fourCC(_ s: StaticString) -> FourCharCode {
    s.withUTF8Buffer { $0.reduce(0) { $0 << 8 | FourCharCode($1) } }
}

private func runningSpotify() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: spotifyBundleID).first { !$0.isTerminated }
}

private func spotifyIsRunning() -> Bool { runningSpotify() != nil }

/// Envia Apple Events crus ao Spotify (sem NSAppleScript: o componente AppleScript custa ~14 MB de RAM).
/// Uma fila serial; o alvo é o PID do processo, então nunca abre o Spotify se ele estiver fechado.
private final class AppleEvents {
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
                    // Enumerações (player state) viram o próprio código de 4 letras.
                    values.append(reply.descriptorType == typeEnumerated
                                  ? String(fourCC: reply.enumCodeValue) : reply.stringValue ?? "")
                }
                return values
            }
            DispatchQueue.main.async { completion(values) }
        }
    }

    /// Só na `queue`. Mira o PID: se o Spotify fechou, falha em vez de abri-lo.
    private func send(_ eventClass: StaticString, _ eventID: StaticString,
                      object: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor? {
        guard let app = runningSpotify() else { throw CocoaError(.featureUnsupported) }
        let event = NSAppleEventDescriptor(
            eventClass: fourCC(eventClass), eventID: fourCC(eventID),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: app.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let object { event.setParam(object, forKeyword: keyDirectObject) }
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
    /// state, id, name, artist, album, artwork url
    static let snapshot = [playerState, trackID, property("pnam", of: track),
                           property("pArt", of: track), property("pAlb", of: track), artworkURL]
}

private extension String {
    init(fourCC code: FourCharCode) {
        self = String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }
}

// MARK: - Spotify

final class Spotify: NSObject {
    /// nil quando o Spotify não está rodando ou está "Stopped".
    private(set) var nowPlaying: NowPlaying?
    /// Miniatura da capa (máx 128 px no maior lado); nil até carregar / quando nada toca.
    /// Na troca de faixa a capa anterior continua aqui até a nova chegar (as views animam a troca),
    /// e só vira nil se a nova não vier em `staleArtworkDelay`.
    private(set) var artwork: CGImage?
    /// Chamado SEMPRE na main thread depois que nowPlaying ou artwork mudam.
    var onChange: (() -> Void)?
    /// true se a última troca de faixa voltou para a faixa anterior (botão "anterior" ou histórico).
    /// As views usam para inverter o sentido da animação.
    private(set) var lastChangeWentBack = false

    private let events = AppleEvents()
    private var artworkTask: URLSessionDataTask?
    /// Incrementado em `clear()` e a cada notificação aplicada; invalida snapshots lentos.
    private var epoch = 0
    private var launchWork: DispatchWorkItem?
    /// Última capa baixada, para não rebaixar quando a faixa muda dentro do mesmo álbum.
    private var cachedArtwork: (url: String, image: CGImage)?
    /// Limpa a capa da faixa anterior se a nova não chegar a tempo (faixa local, anúncio, rede lenta).
    private var staleArtworkWork: DispatchWorkItem?
    private static let staleArtworkDelay: TimeInterval = 1.5
    /// Faixas recentes (a última é a atual), para reconhecer "voltar" feito fora do app (teclado, Spotify).
    private var history: [String] = []
    /// Momento do último "anterior" pedido por este app; uma troca logo depois conta como voltar.
    private var previousRequestedAt: CFAbsoluteTime = 0

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playbackChanged(_:)),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        if spotifyIsRunning() { loadSnapshot() }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        launchWork?.cancel()
        artworkTask?.cancel()
        session.invalidateAndCancel()
    }

    // MARK: Controles

    func playPause() {
        // Toggle otimista; a notificação real corrige depois, e uma falha no envio o reverte.
        let toggled = nowPlaying.map { (id: $0.trackID, isPlaying: !$0.isPlaying) }
        let accepted = events.command("spfy", "PlPs") { [weak self] ok in
            guard !ok, let self, let toggled, var current = self.nowPlaying,
                  current.trackID == toggled.id, current.isPlaying == toggled.isPlaying else { return }
            current.isPlaying.toggle()
            self.nowPlaying = current
            self.onChange?()
        }
        // O completion é assíncrono (main), então roda depois do toggle abaixo.
        guard accepted, let toggled else { return }
        nowPlaying?.isPlaying = toggled.isPlaying
        onChange?()
    }

    func nextTrack() {
        previousRequestedAt = 0
        events.command("spfy", "Next")
    }

    func previousTrack() {
        previousRequestedAt = CFAbsoluteTimeGetCurrent()
        events.command("spfy", "Prev")
    }

    /// Registra a nova faixa no histórico e decide se a troca foi para trás.
    private func recordTrackChange(to trackID: String) {
        let requested = CFAbsoluteTimeGetCurrent() - previousRequestedAt < 2
        previousRequestedAt = 0
        if history.count >= 2, history[history.count - 2] == trackID {
            history.removeLast()
            lastChangeWentBack = true
        } else {
            history.append(trackID)
            if history.count > 50 { history.removeFirst() }
            lastChangeWentBack = requested
        }
    }

    // MARK: Eventos

    @objc private func playbackChanged(_ note: Notification) {
        guard let info = note.userInfo, spotifyIsRunning() else { return clear() }
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" { return clear() }

        let new = NowPlaying(
            trackID: info["Track ID"] as? String ?? "",
            title: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            isPlaying: state == "Playing")
        epoch &+= 1
        update(new)
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == spotifyBundleID {
            launchWork?.cancel()
            launchWork = nil
            clear()
        }
    }

    @objc private func appLaunched(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == spotifyBundleID else { return }
        // O app ainda está subindo: espera um pouco antes de consultar.
        launchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.loadSnapshot() }
        launchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Estado

    private func update(_ new: NowPlaying) {
        guard new != nowPlaying else { return }
        let trackChanged = new.trackID != nowPlaying?.trackID
        nowPlaying = new
        if trackChanged {
            recordTrackChange(to: new.trackID)
            artworkTask?.cancel()
            artworkTask = nil
            scheduleStaleArtworkClear(for: new.trackID)
        }
        onChange?()
        if trackChanged { fetchArtworkURL(for: new.trackID) }
    }

    private func clear() {
        epoch &+= 1
        artworkTask?.cancel()
        artworkTask = nil
        cachedArtwork = nil
        staleArtworkWork?.cancel()
        staleArtworkWork = nil
        guard nowPlaying != nil || artwork != nil else { return }
        nowPlaying = nil
        artwork = nil
        onChange?()
    }

    private func scheduleStaleArtworkClear(for trackID: String) {
        staleArtworkWork?.cancel()
        guard artwork != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.nowPlaying?.trackID == trackID, self.artwork != nil else { return }
            self.staleArtworkWork = nil
            self.artwork = nil
            self.onChange?()
        }
        staleArtworkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Spotify.staleArtworkDelay, execute: work)
    }

    /// Capa da faixa atual chegou: cancela a limpeza pendente e publica.
    private func setArtwork(_ image: CGImage) {
        staleArtworkWork?.cancel()
        staleArtworkWork = nil
        artwork = image
        onChange?()
    }

    // MARK: Consulta inicial

    private func loadSnapshot() {
        let startEpoch = epoch
        // O último item (URL da capa) é opcional: faixa local/anúncio não o tem.
        events.get(AppleEvents.snapshot, optionalFrom: AppleEvents.snapshot.count - 1) { [weak self] v in
            // Se uma notificação ou clear() veio antes da resposta, ela é mais recente: descarta.
            // kPSP = playing, kPSp = paused, kPSS = stopped.
            guard let self, self.epoch == startEpoch, self.nowPlaying == nil,
                  let v, v[0] == "kPSP" || v[0] == "kPSp" else { return }
            let np = NowPlaying(trackID: v[1], title: v[2], artist: v[3], album: v[4], isPlaying: v[0] == "kPSP")
            self.nowPlaying = np
            self.onChange?()
            self.loadArtwork(from: v[5], trackID: np.trackID)
        }
    }

    // MARK: Capa

    private func fetchArtworkURL(for trackID: String, retry: Bool = true) {
        events.get([AppleEvents.trackID, AppleEvents.artworkURL]) { [weak self] v in
            // Descarta a resposta se a faixa já mudou de novo.
            guard let self, let v, self.nowPlaying?.trackID == trackID else { return }
            guard v[0] == trackID else {
                // O Spotify ainda não atualizou `current track`: tenta de novo uma vez.
                guard retry else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.nowPlaying?.trackID == trackID else { return }
                    self.fetchArtworkURL(for: trackID, retry: false)
                }
                return
            }
            self.loadArtwork(from: v[1], trackID: trackID)
        }
    }

    private func loadArtwork(from urlString: String, trackID: String) {
        if let cached = cachedArtwork, cached.url == urlString {
            setArtwork(cached.image)
            return
        }
        // O CDN do Spotify serve 640 px por padrão ("…b273…"); a variante 300 px ("…1e02…") basta para 128 px.
        let small = urlString.replacingOccurrences(of: "ab67616d0000b273", with: "ab67616d00001e02")
        guard let url = Spotify.httpsURL(small) else { return }
        // Se a variante reduzida falhar, tenta uma vez a URL original.
        let fallback = small == urlString ? nil : Spotify.httpsURL(urlString)
        download(url, fallback: fallback, cacheKey: urlString, trackID: trackID)
    }

    private static func httpsURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    private func download(_ url: URL, fallback: URL?, cacheKey: String, trackID: String) {
        artworkTask?.cancel()
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            if (error as? URLError)?.code == .cancelled { return }
            let image: CGImage? = autoreleasepool {
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return Spotify.thumbnail(from: data)
            }
            DispatchQueue.main.async {
                guard let self, self.nowPlaying?.trackID == trackID else { return }   // obsoleto
                guard let image else {
                    if let fallback {
                        self.download(fallback, fallback: nil, cacheKey: cacheKey, trackID: trackID)
                    } else {
                        self.artworkTask = nil
                    }
                    return
                }
                self.artworkTask = nil
                self.cachedArtwork = (cacheKey, image)
                self.setArtwork(image)
            }
        }
        artworkTask = task
        task.resume()
    }

    private static func thumbnail(from data: Data) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
