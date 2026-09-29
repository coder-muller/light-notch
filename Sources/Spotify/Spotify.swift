import AppKit

struct NowPlaying: Equatable {
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
}

/// Posição na faixa, ancorada num instante: a posição atual é calculada, sem consultar o Spotify.
struct PlaybackTiming: Equatable {
    var duration: Double          // segundos
    var position: Double          // segundos, no instante `stamp`
    var stamp: CFTimeInterval     // CACurrentMediaTime()
    var isPlaying: Bool

    func position(at time: CFTimeInterval) -> Double {
        min(duration, max(0, position + (isPlaying ? time - stamp : 0)))
    }

    /// Mesma posição atual, com outro estado de reprodução (re-ancorada agora).
    func with(isPlaying playing: Bool) -> PlaybackTiming {
        let now = CACurrentMediaTime()
        return PlaybackTiming(duration: duration, position: position(at: now), stamp: now, isPlaying: playing)
    }
}

final class Spotify: NSObject {
    /// nil quando o Spotify não está rodando ou está "Stopped".
    private(set) var nowPlaying: NowPlaying?
    /// Miniatura da capa (máx 128 px no maior lado); nil até carregar / quando nada toca.
    /// Na troca de faixa a capa anterior continua aqui até a nova chegar (as views animam a troca),
    /// e só vira nil se a nova não vier em `staleArtworkDelay`.
    private(set) var artwork: CGImage?
    /// Chamado SEMPRE na main thread depois que nowPlaying ou artwork mudam.
    var onChange: (() -> Void)?
    /// Duração e posição da faixa atual; nil quando desconhecidas ou nada toca.
    private(set) var timing: PlaybackTiming?
    /// Aleatório e repetir; nil enquanto desconhecidos. O aviso do Spotify não os traz: são lidos
    /// ao abrir o player e depois de cada alteração.
    private(set) var shuffling: Bool?
    private(set) var repeating: Bool?
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
        timing = timing?.with(isPlaying: toggled.isPlaying)
        onChange?()
    }

    /// Onde o Spotify está instalado; nil se não estiver.
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: spotifyBundleID) }

    /// Traz o Spotify para frente, abrindo-o se estiver fechado.
    static func open() {
        guard let url = appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func nextTrack() {
        previousRequestedAt = 0
        events.command("spfy", "Next")
    }

    func previousTrack() {
        previousRequestedAt = CFAbsoluteTimeGetCurrent()
        events.command("spfy", "Prev")
    }

    /// Pula para `seconds` na faixa atual. Atualiza a posição na hora (otimista).
    func seek(to seconds: Double) {
        guard var current = timing else { return }
        current.position = min(max(0, seconds), current.duration)
        current.stamp = CACurrentMediaTime()
        timing = current
        events.set(AppleEvents.playerPosition, to: NSAppleEventDescriptor(double: current.position))
        onChange?()
    }

    func setShuffling(_ on: Bool) {
        shuffling = on
        events.set(AppleEvents.shuffling, to: NSAppleEventDescriptor(boolean: on))
        onChange?()
        confirmModes()
    }

    func setRepeating(_ on: Bool) {
        repeating = on
        events.set(AppleEvents.repeating, to: NSAppleEventDescriptor(boolean: on))
        onChange?()
        confirmModes()
    }

    /// Lê aleatório/repetir. O Spotify pode recusar (ex. contexto que não permite): a leitura corrige.
    func refreshModes() {
        guard nowPlaying != nil else { return }
        events.get([AppleEvents.shuffling, AppleEvents.repeating]) { [weak self] v in
            guard let self, let v, self.nowPlaying != nil else { return }
            let shuffle = v[0] == "1", repeatOn = v[1] == "1"
            guard shuffle != self.shuffling || repeatOn != self.repeating else { return }
            self.shuffling = shuffle
            self.repeating = repeatOn
            self.onChange?()
        }
    }

    private var confirmWork: DispatchWorkItem?

    private func confirmModes() {
        confirmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshModes() }
        confirmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Relê posição e duração do Spotify (ex. ao abrir o player: um seek feito no Spotify não gera aviso).
    func refreshTiming() {
        guard let trackID = nowPlaying?.trackID else { return }
        let asked = CACurrentMediaTime()
        events.get([AppleEvents.playerPosition, AppleEvents.duration]) { [weak self] v in
            guard let self, let v, let np = self.nowPlaying, np.trackID == trackID,
                  let position = Double(v[0]), let ms = Double(v[1]), ms > 0 else { return }
            let new = PlaybackTiming(duration: ms / 1000, position: position, stamp: asked, isPlaying: np.isPlaying)
            // Ignora diferenças mínimas (latência do Apple Event) para não mexer na barra à toa.
            if let old = self.timing, abs(old.position(at: asked) - position) < 0.5, old.duration == new.duration { return }
            self.timing = new
            self.onChange?()
        }
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
        // Duração em ms e posição em segundos, quando o aviso traz.
        var newTiming: PlaybackTiming?
        if let ms = (info["Duration"] as? NSNumber)?.doubleValue, ms > 0 {
            let position = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0
            newTiming = PlaybackTiming(duration: ms / 1000, position: position,
                                       stamp: CACurrentMediaTime(), isPlaying: new.isPlaying)
        }
        epoch &+= 1
        update(new, timing: newTiming)
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

    private func update(_ new: NowPlaying, timing newTiming: PlaybackTiming?) {
        let trackChanged = new.trackID != nowPlaying?.trackID
        let timingChanged = newTiming.map { t in
            timing.map { $0.duration != t.duration || $0.isPlaying != t.isPlaying
                || abs($0.position(at: t.stamp) - t.position) >= 0.5 } ?? true
        } ?? false
        guard new != nowPlaying || timingChanged else { return }
        nowPlaying = new
        if let newTiming, timingChanged || trackChanged {
            timing = newTiming
        } else if trackChanged {
            timing = nil
        } else if let current = timing, current.isPlaying != new.isPlaying {
            timing = current.with(isPlaying: new.isPlaying)
        }
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
        timing = nil
        shuffling = nil
        repeating = nil
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
            self.refreshTiming()
            self.refreshModes()
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
