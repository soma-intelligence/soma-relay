import AVFoundation
import CallKit
import CryptoKit
import Foundation
import Observation
@preconcurrency import WebRTC

/// One call as the call screen draws it.
struct CallSession: Equatable {
    enum State: Equatable { case ringingOut, ringingIn, connecting, active, ended(String) }
    let id: String
    let peer: String
    var video: Bool
    var state: State
    var startedAt: Date?
    var muted = false
    var speaker = false
    var cameraOff = false
    var frameEncrypted = false
    var rttMs: Int?
}

/// 1:1 audio and video calls (docs/research/calls.md): WebRTC from the LiveKit libwebrtc build,
/// signalling as encrypted `call` AppMessages through whatever transport is up, ICE servers from
/// the node, media frames encrypted with keys derived from `callKey(fp, callId)` through
/// RTCFrameCryptor (AES-GCM, new key every 5 minutes) on top of DTLS-SRTP. CallKit shows the
/// system UI for incoming calls while the app runs.
@Observable
final class CallManager: NSObject {
    private(set) var current: CallSession?
    var presented = false
    private(set) var remoteVideo: RTCVideoTrack?
    private(set) var localVideo: RTCVideoTrack?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let factory: RTCPeerConnectionFactory
    @ObservationIgnored private var pc: RTCPeerConnection?
    @ObservationIgnored private var pendingOffer: String?
    @ObservationIgnored private var pendingCandidates: [RTCIceCandidate] = []
    @ObservationIgnored private var keyProvider: RTCFrameCryptorKeyProvider?
    @ObservationIgnored private var cryptors: [RTCFrameCryptor] = []
    @ObservationIgnored private var capturer: RTCCameraVideoCapturer?
    @ObservationIgnored private var rotation: Task<Void, Never>?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private let provider: CXProvider
    @ObservationIgnored private let callController = CXCallController()
    @ObservationIgnored private var callUUID: UUID?

    static let ratchetSalt = Data("soma-relay call v1".utf8)
    static let rotateEvery: Duration = .seconds(300)

    init(model: AppModel) {
        self.model = model
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
    }

    var isBusy: Bool {
        guard let current else { return false }
        if case .ended = current.state { return false }
        return true
    }

    /// Safety words of the call: the contact's words (same on both sides).
    func words() -> [String] {
        guard let current, let model else { return [] }
        return model.safetyWords(with: current.peer)
    }

    // MARK: Outgoing

    func start(with fp: String, video: Bool) {
        guard !isBusy, let model else { return }
        let id = UUIDv7.make()
        current = CallSession(id: id, peer: fp, video: video, state: .ringingOut)
        presented = true
        Haptics.tap()
        let uuid = UUID()
        callUUID = uuid
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: model.name(of: fp)))
        action.isVideo = video
        callController.request(CXTransaction(action: action)) { _ in }
        Task {
            await makePeerConnection(video: video)
            guard let pc, current?.id == id else { return }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let offer = try? await pc.offer(for: constraints) else { return fail("Impossible de préparer l'appel.") }
            let sdp = RTCSessionDescription(type: .offer, sdp: Self.mungeOpus(offer.sdp))
            try? await pc.setLocalDescription(sdp)
            signal(.offer, sdp: sdp.sdp)
            armTimeout(seconds: 45, reason: "Pas de réponse")
        }
    }

    // MARK: Incoming signalling

    func handle(_ signal: AppMessage.CallSignal, from fp: String) {
        switch signal.action {
        case .offer:
            if isBusy, current?.id != signal.callId {
                reply(.busy, callId: signal.callId, to: fp, video: signal.video)
                return
            }
            pendingOffer = signal.sdp
            current = CallSession(id: signal.callId, peer: fp, video: signal.video, state: .ringingIn)
            presented = true
            reportIncoming(from: fp, video: signal.video)
            armTimeout(seconds: 45, reason: "Appel manqué")
        case .answer:
            guard current?.id == signal.callId, let sdp = signal.sdp, let pc else { return }
            Task {
                try? await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
                attachReceiverCryptors()
                flushCandidates()
                setState(.connecting)
            }
        case .ice:
            guard current?.id == signal.callId, let text = signal.candidate, let candidate = Self.candidate(from: text) else { return }
            if let pc, pc.remoteDescription != nil {
                pc.add(candidate) { _ in }
            } else {
                pendingCandidates.append(candidate)
            }
        case .end, .decline, .busy:
            guard current?.id == signal.callId else { return }
            let reason = signal.action == .busy ? "Occupé" : signal.action == .decline ? "Refusé" : "Appel terminé"
            finish(reason, notifyPeer: false)
        }
    }

    func accept() {
        guard let current, current.state == .ringingIn, let offer = pendingOffer else { return }
        timeout?.cancel()
        setState(.connecting)
        if let callUUID { callController.request(CXTransaction(action: CXAnswerCallAction(call: callUUID))) { _ in } }
        Task {
            await makePeerConnection(video: current.video)
            guard let pc else { return }
            try? await pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer))
            attachReceiverCryptors()
            flushCandidates()
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let answer = try? await pc.answer(for: constraints) else { return fail("Impossible de répondre.") }
            let sdp = RTCSessionDescription(type: .answer, sdp: Self.mungeOpus(answer.sdp))
            try? await pc.setLocalDescription(sdp)
            signal(.answer, sdp: sdp.sdp)
        }
    }

    func decline() {
        guard let current else { return }
        reply(.decline, callId: current.id, to: current.peer, video: current.video)
        finish("Refusé", notifyPeer: false)
    }

    func hangUp() { finish("Appel terminé", notifyPeer: true) }

    func endAll() {
        if isBusy { finish("Appel terminé", notifyPeer: true) }
    }

    // MARK: Controls

    func toggleMute() {
        guard var c = current else { return }
        c.muted.toggle()
        current = c
        pc?.senders.compactMap { $0.track as? RTCAudioTrack }.forEach { $0.isEnabled = !c.muted }
        if let callUUID { callController.request(CXTransaction(action: CXSetMutedCallAction(call: callUUID, muted: c.muted))) { _ in } }
        Haptics.select()
    }

    func toggleSpeaker() {
        guard var c = current else { return }
        c.speaker.toggle()
        current = c
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.overrideOutputAudioPort(c.speaker ? .speaker : .none)
        session.unlockForConfiguration()
        Haptics.select()
    }

    func toggleCamera() {
        guard var c = current, c.video else { return }
        c.cameraOff.toggle()
        current = c
        localVideo?.isEnabled = !c.cameraOff
        Haptics.select()
    }

    // MARK: Peer connection

    private func makePeerConnection(video: Bool) async {
        guard let model, let current else { return }
        let config = RTCConfiguration()
        let servers = model.nodeEnabled ? await model.node.iceServers() : [NodeClient.IceServer(urls: ["stun:stun.l.google.com:19302"])]
        config.iceServers = servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.cryptoOptions = RTCCryptoOptions(
            srtpEnableGcmCryptoSuites: true, srtpPreferGcmCryptoSuites: true, srtpEnableAes128Sha1_32CryptoCipher: false,
            srtpEnableAes128Sha1_80CryptoCipher: true, srtpEnableEncryptedRtpHeaderExtensions: true, sframeRequireFrameEncryption: false)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else { return }
        self.pc = pc
        configureAudioSession()

        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "a0")
        let audioSender = pc.add(audioTrack, streamIds: ["s0"])
        if let audioSender {
            let params = audioSender.parameters
            for e in params.encodings {
                e.networkPriority = .high
                e.bitratePriority = 4
                e.maxBitrateBps = 32_000
            }
            audioSender.parameters = params
        }
        if video {
            let source = factory.videoSource()
            let track = factory.videoTrack(with: source, trackId: "v0")
            localVideo = track
            if let sender = pc.add(track, streamIds: ["s0"]) {
                let params = sender.parameters
                params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainFramerate.rawValue)
                for e in params.encodings {
                    e.maxBitrateBps = 1_600_000
                    e.minBitrateBps = 80_000
                    e.maxFramerate = 30
                }
                sender.parameters = params
            }
            startCamera(source)
        }
        pc.setBweMinBitrateBps(80_000, currentBitrateBps: 600_000, maxBitrateBps: 1_600_000)
        applyCodecPreferences(pc)
        setUpFrameEncryption(pc, peer: current.peer, callId: current.id)
    }

    /// Video: H.264 (High 640c1f, then Constrained Baseline 42e01f) first, VP8 and VP9 kept for
    /// browsers; repair codecs (rtx, red, ulpfec) after. Audio: Opus first.
    private func applyCodecPreferences(_ pc: RTCPeerConnection) {
        for transceiver in pc.transceivers {
            let kind = transceiver.mediaType == .video ? kRTCMediaStreamTrackKindVideo : kRTCMediaStreamTrackKindAudio
            let codecs = factory.rtpSenderCapabilities(forKind: kind).codecs
            func rank(_ c: RTCRtpCodecCapability) -> Int {
                let name = c.name.lowercased()
                if transceiver.mediaType == .audio { return name == "opus" ? 0 : name == "red" ? 1 : 5 }
                let profile = c.parameters["profile-level-id"]?.lowercased() ?? ""
                switch name {
                case "h264": return profile.hasPrefix("640c") ? 0 : profile.hasPrefix("42e0") ? 1 : 2
                case "vp8": return 3
                case "vp9": return 4
                case "av1": return 5
                case "rtx", "red", "ulpfec", "flexfec-03": return 8
                default: return 9
                }
            }
            let sorted = codecs.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
            try? transceiver.setCodecPreferences(sorted, error: ())
        }
    }

    // MARK: Frame encryption (LiveKit RTCFrameCryptor)

    /// Keys: k_dir = HKDF-SHA256(callKey, salt = call_id, info = "soma-relay call v1 send" || sender fp).
    /// Each side encrypts with its own k and decrypts the peer's; the provider ratchets with
    /// HKDF + `ratchetSalt` every 5 minutes (receivers follow within the ratchet window).
    private func setUpFrameEncryption(_ pc: RTCPeerConnection, peer: String, callId: String) {
        guard let model, let core = model.core, let callKey = try? core.callKey(fp: peer, callId: callId) else { return }
        let me = core.fingerprintHex()
        let provider = RTCFrameCryptorKeyProvider(
            ratchetSalt: Self.ratchetSalt, ratchetWindowSize: 16, sharedKeyMode: false, uncryptedMagicBytes: nil,
            failureTolerance: -1, keyRingSize: 16, discardFrameWhenCryptorNotReady: true, keyDerivationAlgorithm: .HKDF)
        provider.setKey(Self.directional(callKey, callId: callId, sender: me), with: 0, forParticipant: me)
        provider.setKey(Self.directional(callKey, callId: callId, sender: peer), with: 0, forParticipant: peer)
        keyProvider = provider
        for sender in pc.senders {
            if let cryptor = RTCFrameCryptor(factory: factory, rtpSender: sender, participantId: me, algorithm: .aesGcm, keyProvider: provider) {
                cryptor.enabled = true
                cryptors.append(cryptor)
            }
        }
        var c = current
        c?.frameEncrypted = !cryptors.isEmpty
        current = c
        rotation?.cancel()
        rotation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.rotateEvery)
                guard !Task.isCancelled, let self, let provider = self.keyProvider else { return }
                _ = provider.ratchetKey(me, with: 0)
            }
        }
    }

    private func attachReceiverCryptors() {
        guard let pc, let provider = keyProvider, let peer = current?.peer else { return }
        let existing = Set(cryptors.map { ObjectIdentifier($0) })
        for transceiver in pc.transceivers {
            if let cryptor = RTCFrameCryptor(factory: factory, rtpReceiver: transceiver.receiver, participantId: peer, algorithm: .aesGcm, keyProvider: provider),
                !existing.contains(ObjectIdentifier(cryptor))
            {
                cryptor.enabled = true
                cryptors.append(cryptor)
            }
            if transceiver.mediaType == .video, let track = transceiver.receiver.track as? RTCVideoTrack {
                remoteVideo = track
            }
        }
    }

    static func directional(_ callKey: Data, callId: String, sender: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: callKey), salt: Data(callId.utf8),
            info: Data(("soma-relay call v1 send" + sender).utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: Media

    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setCategory(.playAndRecord, with: [.allowBluetoothHFP, .duckOthers])
        try? session.setMode(.voiceChat)
        try? session.setPreferredIOBufferDuration(0.01)
        try? session.setPreferredSampleRate(48_000)
        session.unlockForConfiguration()
    }

    private func startCamera(_ source: RTCVideoSource) {
        let capturer = RTCCameraVideoCapturer(delegate: source)
        self.capturer = capturer
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front }) ?? RTCCameraVideoCapturer.captureDevices().first
        else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats.min { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription), db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return abs(Int(da.width) - 1280) + abs(Int(da.height) - 720) < abs(Int(db.width) - 1280) + abs(Int(db.height) - 720)
        }
        guard let format else { return }
        capturer.startCapture(with: device, format: format, fps: 30)
    }

    // MARK: Helpers

    private func signal(_ action: AppMessage.CallSignal.Action, sdp: String? = nil, candidate: String? = nil) {
        guard let current else { return }
        var message = AppMessage.make(.call)
        message.call = .init(callId: current.id, action: action, sdp: sdp, candidate: candidate, video: current.video)
        model?.sendControl(message, to: current.peer)
    }

    private func reply(_ action: AppMessage.CallSignal.Action, callId: String, to fp: String, video: Bool) {
        var message = AppMessage.make(.call)
        message.call = .init(callId: callId, action: action, sdp: nil, candidate: nil, video: video)
        model?.sendControl(message, to: fp)
    }

    private func flushCandidates() {
        guard let pc else { return }
        for c in pendingCandidates { pc.add(c) { _ in } }
        pendingCandidates = []
    }

    private func setState(_ state: CallSession.State) {
        guard var c = current else { return }
        c.state = state
        if state == .active, c.startedAt == nil {
            c.startedAt = Date()
            timeout?.cancel()
            Haptics.success()
        }
        current = c
    }

    private func armTimeout(seconds: Double, reason: String) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, let c = self.current, c.state != .active else { return }
            self.finish(reason, notifyPeer: true)
        }
    }

    private func fail(_ reason: String) { finish(reason, notifyPeer: true) }

    private func finish(_ reason: String, notifyPeer: Bool) {
        if notifyPeer, current != nil { signal(.end) }
        timeout?.cancel()
        rotation?.cancel()
        capturer?.stopCapture()
        capturer = nil
        cryptors.forEach { $0.enabled = false }
        cryptors = []
        keyProvider = nil
        pc?.close()
        pc = nil
        pendingOffer = nil
        pendingCandidates = []
        remoteVideo = nil
        localVideo = nil
        if let callUUID {
            provider.reportCall(with: callUUID, endedAt: Date(), reason: .remoteEnded)
            self.callUUID = nil
        }
        setState(.ended(reason))
        Haptics.warning()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, case .ended = self.current?.state else { return }
            self.presented = false
            self.current = nil
        }
    }

    private func reportIncoming(from fp: String, video: Bool) {
        let uuid = UUID()
        callUUID = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: model?.name(of: fp) ?? "Soma Relay")
        update.localizedCallerName = model?.name(of: fp)
        update.hasVideo = video
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in }
    }

    static func mungeOpus(_ sdp: String) -> String {
        let fmtp = "minptime=10;maxptime=40;useinbandfec=1;usedtx=1;stereo=0;sprop-stereo=0;maxaveragebitrate=32000;maxplaybackrate=48000;cbr=0"
        var lines = sdp.components(separatedBy: "\r\n")
        guard let rtpmap = lines.first(where: { $0.lowercased().hasPrefix("a=rtpmap:") && $0.lowercased().contains("opus/48000") }),
            let pt = rtpmap.dropFirst("a=rtpmap:".count).split(separator: " ").first
        else { return sdp }
        if let i = lines.firstIndex(where: { $0.hasPrefix("a=fmtp:\(pt) ") }) {
            lines[i] = "a=fmtp:\(pt) \(fmtp)"
        } else if let i = lines.firstIndex(of: rtpmap) {
            lines.insert("a=fmtp:\(pt) \(fmtp)", at: i + 1)
        }
        return lines.joined(separator: "\r\n")
    }

    static func candidate(from text: String) -> RTCIceCandidate? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let sdp = obj["candidate"] as? String else { return nil }
        return RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32((obj["sdpMLineIndex"] as? Int) ?? 0), sdpMid: obj["sdpMid"] as? String)
    }

    static func text(of candidate: RTCIceCandidate) -> String {
        var obj: [String: Any] = ["candidate": candidate.sdp, "sdpMLineIndex": Int(candidate.sdpMLineIndex)]
        if let mid = candidate.sdpMid { obj["sdpMid"] = mid }
        return (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // Main-actor handlers for the delegate callbacks.

    fileprivate func generated(_ candidate: RTCIceCandidate) {
        signal(.ice, candidate: Self.text(of: candidate))
    }

    fileprivate func connectionChanged(_ state: RTCPeerConnectionState) {
        switch state {
        case .connected:
            setState(.active)
            attachReceiverCryptors()
        case .failed:
            finish("Connexion perdue", notifyPeer: true)
        default:
            break
        }
    }

    fileprivate func audioActivated(_ session: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(session)
        rtc.isAudioEnabled = true
    }

    fileprivate func audioDeactivated(_ session: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidDeactivate(session)
        rtc.isAudioEnabled = false
    }

    /// Demo screenshots: a call already running.
    func showDemo(peer: String) {
        current = CallSession(id: "demo", peer: peer, video: false, state: .active, startedAt: Date().addingTimeInterval(-197), frameEncrypted: true, rttMs: 48)
        presented = true
    }
}

extension CallManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in self.generated(candidate) }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in self.connectionChanged(newState) }
    }
}

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.endAll() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in self.accept() }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            if self.current?.state == .ringingIn { self.decline() } else { self.hangUp() }
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        nonisolated(unsafe) let session = audioSession
        Task { @MainActor in self.audioActivated(session) }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        nonisolated(unsafe) let session = audioSession
        Task { @MainActor in self.audioDeactivated(session) }
    }
}
