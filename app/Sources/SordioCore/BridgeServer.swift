import Foundation
import Network

/// Локальный WebSocket-сервер для связи с расширением браузера.
///
/// Фрейминг обеспечивает `NWProtocolWebSocket`; подлинность клиента —
/// спаривание и секрет (§8 спецификации).
public final class BridgeServer {
    public enum StartError: Error {
        case noFreePort
    }

    /// Сколько ждём `hello`, прежде чем разорвать соединение.
    public static let helloTimeout: TimeInterval = 3

    /// Сколько ждём готовности слушателя на каждом кандидате-порту.
    ///
    /// `start()` вызывается из `applicationDidFinishLaunching`, то есть с
    /// главного потока: каждая лишняя секунда здесь — это подвисший старт.
    /// 250 мс с запасом хватает петлевому слушателю, чтобы дойти до `.ready`
    /// или упасть с «Address already in use».
    public static let listenerReadyTimeout: TimeInterval = 0.25

    /// Сколько молчим после отказа пользователя, прежде чем снова показывать
    /// кому-либо диалог спаривания.
    public static let approvalCooldown: TimeInterval = 60

    public var onMessage: ((InboundMessage) -> Void)?
    public var onConnect: (() -> Void)?
    public var onDisconnect: (() -> Void)?
    /// Спаривание состоялось: приложение должно сохранить и секрет, и
    /// идентификатор — дальше требуется совпадение обоих.
    public var onPaired: ((_ secret: String, _ extensionId: String) -> Void)?
    /// Спросить пользователя, пускать ли клиента.
    public var pairingRequest: ((String, ApprovalReason, @escaping (Bool) -> Void) -> Void)?

    public private(set) var port: UInt16?
    public var isConnected: Bool { queue.sync { client != nil } }

    private let portRange: ClosedRange<UInt16>
    private let approvalCooldown: TimeInterval
    private var pairing: PairingStore
    private let queue = DispatchQueue(label: "ru.sordio.bridge")

    /// Соединение, которое ещё не спарилось. Таких может быть сколько угодно
    /// (сокет к 127.0.0.1 открывает любая локальная страница), и ни одно из
    /// них не имеет права трогать уже спаренного клиента.
    private final class Contender {
        let connection: NWConnection
        /// Диалог подтверждения показан и ждёт решения пользователя.
        var pendingApproval = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private var listener: NWListener?
    /// Спаренный клиент — ровно один и только после корректного `hello`.
    private var client: NWConnection?
    private var contenders: [ObjectIdentifier: Contender] = [:]
    /// До этого момента диалоги спаривания не показываем вовсе.
    private var silentUntil: TimeInterval = 0

    public init(portRange: ClosedRange<UInt16>,
                pairing: PairingStore,
                approvalCooldown: TimeInterval = BridgeServer.approvalCooldown) {
        self.portRange = portRange
        self.pairing = pairing
        self.approvalCooldown = approvalCooldown
    }

    public func updatePairing(_ pairing: PairingStore) {
        queue.sync { self.pairing = pairing }
    }

    public func start() throws {
        for candidate in portRange {
            guard let nwPort = NWEndpoint.Port(rawValue: candidate) else { continue }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Слушаем только петлевой интерфейс — снаружи порт недоступен.
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)

            let websocket = NWProtocolWebSocket.Options()
            websocket.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

            guard let listener = try? NWListener(using: parameters) else { continue }

            // `NWListener(using:)` не проверяет занятость порта — конструктор
            // успешен и для порта, который уже слушает кто-то другой. Коллизия
            // ("Address already in use") обнаруживается только асинхронно, через
            // stateUpdateHandler. Поэтому ждём, пока слушатель либо дойдёт до
            // .ready, либо провалится, и только тогда решаем, наш это порт или нет.
            let readiness = DispatchSemaphore(value: 0)
            let isReady = Atomic(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    isReady.value = true
                    readiness.signal()
                case .failed, .cancelled:
                    readiness.signal()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)

            _ = readiness.wait(timeout: .now() + Self.listenerReadyTimeout)

            if isReady.value {
                self.listener = listener
                self.port = candidate
                return
            }
            listener.cancel()
        }
        throw StartError.noFreePort
    }

    public func stop() {
        queue.sync {
            client?.cancel()
            client = nil
            for contender in contenders.values { contender.connection.cancel() }
            contenders.removeAll()
            listener?.cancel()
            listener = nil
        }
    }

    public func send(_ message: OutboundMessage) {
        queue.async { [weak self] in
            guard let self, let client = self.client else { return }
            self.rawSend(MessageCodec.encode(message), on: client)
        }
    }

    // MARK: - соединение

    private func accept(_ connection: NWConnection) {
        // Новое соединение НЕ вытесняет спаренного клиента: пока оно не
        // прислало корректный hello, это просто чья-то локальная страница.
        // Иначе цикл `new WebSocket(...)` на любой вкладке непрерывно рвал бы
        // мост: плашка мигает «нет связи», хоткей не работает.
        let contender = Contender(connection)
        contenders[ObjectIdentifier(connection)] = contender

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                self.queue.async { self.drop(connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)

        // Клиент, не представившийся вовремя, нам не интересен. Но если hello
        // уже пришёл и решение висит перед пользователем (модальный диалог),
        // таймаут отключать соединение не должен — торопить человека нечем,
        // а разрыв здесь означал бы бесконечный цикл всплывающих диалогов.
        queue.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self] in
            guard let self,
                  let still = self.contenders[ObjectIdentifier(connection)],
                  still === contender, !contender.pendingApproval else { return }
            self.drop(connection)
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                _ = error
                self.queue.async { self.drop(connection) }
                return
            }

            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata

            if metadata?.opcode == .close {
                self.queue.async { self.drop(connection) }
                return
            }

            if let data, !data.isEmpty, metadata?.opcode == .text {
                self.queue.async { self.handle(data, on: connection) }
            }
            self.receive(on: connection)
        }
    }

    private func handle(_ data: Data, on connection: NWConnection) {
        guard let message = try? MessageCodec.decode(data) else { return }

        if connection === client {
            // Повторный hello от уже спаренного клиента ничего не меняет:
            // перевыпускать секрет спамом сообщений нельзя.
            if case .hello = message { return }
            DispatchQueue.main.async { self.onMessage?(message) }
            return
        }

        // До успешного спаривания клиент не имеет права ничего сообщать,
        // кроме hello.
        guard let contender = contenders[ObjectIdentifier(connection)],
              case .hello(let extensionId, let secret) = message else { return }
        // Диалог уже висит — повторный hello игнорируем, чтобы не плодить
        // модальные окна.
        guard !contender.pendingApproval else { return }
        authorize(extensionId: extensionId, secret: secret, on: contender)
    }

    private func authorize(extensionId: String, secret: String?, on contender: Contender) {
        let connection = contender.connection

        switch pairing.evaluate(extensionId: extensionId, secret: secret) {
        case .reject:
            drop(connection)

        case .accept:
            promote(contender)
            rawSend(MessageCodec.encode(.welcome), on: connection)
            DispatchQueue.main.async { self.onConnect?() }

        case .needsApproval(let id, let reason):
            // После отказа пользователя выдерживаем паузу. Иначе отклонённая
            // страница подключается снова, получает новый модальный диалог —
            // и машину можно заблокировать потоком модальных окон.
            // Пауза общая, а не по идентификатору: до спаривания клиент ничем
            // не подтверждён, и `extensionId` в каждой попытке может быть новым.
            guard Date.timeIntervalSinceReferenceDate >= silentUntil else {
                drop(connection)
                return
            }
            guard let pairingRequest else {
                drop(connection)
                return
            }
            // Диалог показываем строго по одному: претендентов может быть
            // сколько угодно, а второй модальный NSAlert поверх первого —
            // тот же поток модальных окон, только с другого конца.
            // Отказ здесь молчаливый и паузу не запускает: пользователь
            // ничего не отклонял.
            guard !contenders.values.contains(where: { $0.pendingApproval }) else {
                drop(connection)
                return
            }
            contender.pendingApproval = true
            DispatchQueue.main.async {
                pairingRequest(id, reason) { [weak self] approved in
                    guard let self else { return }
                    self.queue.async {
                        // Устаревший колбэк от уже закрытого соединения не
                        // должен трогать состояние актуальных клиентов.
                        guard self.contenders[ObjectIdentifier(connection)] === contender else { return }
                        contender.pendingApproval = false
                        guard approved else {
                            self.silentUntil = Date.timeIntervalSinceReferenceDate + self.approvalCooldown
                            self.drop(connection)
                            return
                        }
                        let issued = PairingStore.makeSecret()
                        self.pairing.secret = issued
                        self.pairing.extensionId = id
                        self.promote(contender)
                        self.rawSend(MessageCodec.encode(.paired(secret: issued)), on: connection)
                        DispatchQueue.main.async {
                            self.onPaired?(issued, id)
                            self.onConnect?()
                        }
                    }
                }
            }
        }
    }

    /// Претендент прислал корректный hello — только теперь он вытесняет
    /// предыдущего спаренного клиента.
    private func promote(_ contender: Contender) {
        let connection = contender.connection
        contenders.removeValue(forKey: ObjectIdentifier(connection))

        if let previous = client, previous !== connection {
            client = nil
            previous.cancel()
            DispatchQueue.main.async { self.onDisconnect?() }
        }
        client = connection
    }

    private func rawSend(_ data: Data, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    private func drop(_ connection: NWConnection) {
        contenders.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
        guard connection === client else { return }
        client = nil
        DispatchQueue.main.async { self.onDisconnect?() }
    }
}

/// Минимальная обёртка для значения, которое пишет очередь слушателя, а читает
/// вызывающий поток. Нужна только внутри `start()`.
private final class Atomic<Value> {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
