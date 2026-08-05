import XCTest
@testable import SordioCore

final class BridgeServerTests: XCTestCase {

    private var server: BridgeServer!

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    /// Настоящий идентификатор расширения Chrome: 32 строчные буквы a…p.
    private let extensionId = "abcdefghijklmnopabcdefghijklmnop"

    private func makeServer(extensionId storedId: String? = nil,
                            secret: String? = nil,
                            approve: Bool = true) throws -> BridgeServer {
        let server = BridgeServer(portRange: 8900...8920,
                                  pairing: PairingStore(extensionId: storedId, secret: secret))
        server.pairingRequest = { _, _, decide in decide(approve) }
        try server.start()
        return server
    }

    private func connect(to server: BridgeServer) -> URLSessionWebSocketTask {
        let url = URL(string: "ws://127.0.0.1:\(server.port!)/")!
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
        task.resume()
        return task
    }

    private func hello(id: String? = nil, secret: String? = nil) -> String {
        var fields = [#""v":1"#, #""type":"hello""#,
                      #""extensionId":"\#(id ?? extensionId)""#]
        if let secret { fields.append(#""secret":"\#(secret)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    func testStartsOnAPortInRange() throws {
        server = try makeServer()
        XCTAssertTrue((8900...8920).contains(try XCTUnwrap(server.port)))
    }

    func testApprovedClientGetsSecretAndIsConnected() throws {
        server = try makeServer()
        let connected = expectation(description: "клиент подключён")
        var issued: (secret: String, id: String)?
        server.onPaired = { issued = ($0, $1) }
        server.onConnect = { connected.fulfill() }

        let task = connect(to: server)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let welcomed = expectation(description: "секрет выдан")
        task.send(.string(hello())) { XCTAssertNil($0) }
        task.receive { result in
            if case .success(.string(let text)) = result, text.contains("paired") {
                welcomed.fulfill()
            }
        }

        wait(for: [connected, welcomed], timeout: 5)
        XCTAssertNotNil(issued?.secret)
        XCTAssertEqual(issued?.id, extensionId,
                       "приложение должно запомнить идентификатор рядом с секретом")
        XCTAssertTrue(server.isConnected)
    }

    func testKnownPairConnectsWithoutAskingUser() throws {
        server = try makeServer(extensionId: extensionId, secret: "known-secret")
        var askedUser = false
        server.pairingRequest = { _, _, decide in
            askedUser = true
            decide(true)
        }
        let connected = expectation(description: "клиент подключён")
        server.onConnect = { connected.fulfill() }

        let task = connect(to: server)
        defer { task.cancel(with: .goingAway, reason: nil) }
        task.send(.string(hello(secret: "known-secret"))) { XCTAssertNil($0) }

        wait(for: [connected], timeout: 5)
        XCTAssertFalse(askedUser, "спаренного клиента переспрашивать не нужно")
    }

    func testStrangerWithStolenSecretStillAsksUser() throws {
        // Идентификатор запомнен: даже подошедший секрет от другого клиента
        // не пускает молча — README обещает именно это.
        server = try makeServer(extensionId: extensionId, secret: "known-secret")
        let asked = expectation(description: "спросили пользователя")
        var seenReason: ApprovalReason?
        server.pairingRequest = { _, reason, decide in
            seenReason = reason
            asked.fulfill()
            decide(false)
        }

        let task = connect(to: server)
        defer { task.cancel(with: .goingAway, reason: nil) }
        let stranger = "ponmlkjihgfedcbaponmlkjihgfedcba"
        task.send(.string(hello(id: stranger, secret: "known-secret"))) { _ in }

        wait(for: [asked], timeout: 5)
        XCTAssertEqual(seenReason, .differentExtension(paired: extensionId),
                       "диалог обязан отличаться текстом: это не первое спаривание")
    }

    func testMalformedExtensionIdNeverReachesTheDialog() throws {
        server = try makeServer()
        var asked = false
        server.pairingRequest = { _, _, decide in
            asked = true
            decide(true)
        }

        let task = connect(to: server)
        defer { task.cancel(with: .goingAway, reason: nil) }
        task.send(.string(hello(id: "Это системное окно, нажмите Разрешить"))) { _ in }

        let settled = expectation(description: "пауза")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        XCTAssertFalse(asked, "произвольную строку от клиента нельзя показывать в диалоге")
        XCTAssertFalse(server.isConnected)
    }

    func testRefusedClientIsDisconnected() throws {
        server = try makeServer(approve: false)
        let failed = expectation(description: "отказ разрывает соединение")

        let task = connect(to: server)
        task.send(.string(hello())) { _ in }
        task.receive { result in
            if case .failure = result { failed.fulfill() }
        }

        wait(for: [failed], timeout: 5)
        XCTAssertFalse(server.isConnected)
    }

    func testMessagesBeforeHelloAreIgnored() throws {
        server = try makeServer()
        var received: [InboundMessage] = []
        server.onMessage = { received.append($0) }

        let task = connect(to: server)
        defer { task.cancel(with: .goingAway, reason: nil) }
        task.send(.string(#"{"v":1,"type":"state","context":"in-call","muted":true}"#)) { _ in }

        let settled = expectation(description: "пауза")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        XCTAssertTrue(received.isEmpty, "до спаривания клиент не имеет права ничего сообщать")
    }

    func testDeliversStateAfterHello() throws {
        server = try makeServer()
        let connected = expectation(description: "клиент подключён")
        server.onConnect = { connected.fulfill() }

        let task = connect(to: server)
        defer { task.cancel(with: .goingAway, reason: nil) }
        task.send(.string(hello())) { _ in }
        wait(for: [connected], timeout: 5)

        let delivered = expectation(description: "состояние доставлено")
        var got: InboundMessage?
        server.onMessage = { message in
            got = message
            delivered.fulfill()
        }
        task.send(.string(#"{"v":1,"type":"state","context":"in-call","muted":true}"#)) { _ in }

        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(got, .state(context: .inCall, muted: true))
    }

    func testSendsCommandToClient() throws {
        server = try makeServer()
        let connected = expectation(description: "клиент подключён")
        server.onConnect = { connected.fulfill() }

        let task = connect(to: server)
        defer { task.cancel(with: .goingAway, reason: nil) }
        task.send(.string(hello())) { _ in }
        wait(for: [connected], timeout: 5)

        let got = expectation(description: "команда получена")
        var payload: String?
        func receiveUntilCommand() {
            task.receive { result in
                if case .success(.string(let text)) = result {
                    if text.contains("setMuted") {
                        payload = text
                        got.fulfill()
                        return
                    }
                    receiveUntilCommand()
                }
            }
        }
        receiveUntilCommand()

        server.send(.setMuted(id: "c1", muted: false))
        wait(for: [got], timeout: 5)
        XCTAssertTrue(try XCTUnwrap(payload).contains(#""muted":false"#))
    }

    func testDisconnectIsReported() throws {
        server = try makeServer()
        let connected = expectation(description: "клиент подключён")
        let disconnected = expectation(description: "отключение замечено")
        server.onConnect = { connected.fulfill() }
        server.onDisconnect = { disconnected.fulfill() }

        let task = connect(to: server)
        task.send(.string(hello())) { _ in }
        wait(for: [connected], timeout: 5)

        task.cancel(with: .goingAway, reason: nil)
        wait(for: [disconnected], timeout: 5)
    }

    func testSilentClientIsDroppedByTimeout() throws {
        server = try makeServer()
        let failed = expectation(description: "молчун отключён")

        let task = connect(to: server)
        task.receive { result in
            if case .failure = result { failed.fulfill() }
        }

        wait(for: [failed], timeout: 10)
    }

    // MARK: - находки ревью

    func testFallsBackToNextPortWhenPortIsTaken() throws {
        // `NWListener(using:)` не проверяет занятость порта при конструировании —
        // коллизия обнаруживается только асинхронно. Второй сервер должен
        // дождаться провала на занятом порту и перейти к следующему кандидату.
        let first = BridgeServer(portRange: 8930...8930, pairing: PairingStore(secret: nil))
        try first.start()
        defer { first.stop() }
        XCTAssertEqual(first.port, 8930)

        let second = BridgeServer(portRange: 8930...8931, pairing: PairingStore(secret: nil))
        try second.start()
        defer { second.stop() }
        XCTAssertEqual(second.port, 8931, "занятый первый порт нужно пропустить и перейти к следующему")
    }

    func testThrowsWhenNoPortIsFree() throws {
        let first = BridgeServer(portRange: 8932...8932, pairing: PairingStore(secret: nil))
        try first.start()
        defer { first.stop() }

        let second = BridgeServer(portRange: 8932...8932, pairing: PairingStore(secret: nil))
        XCTAssertThrowsError(try second.start()) { error in
            guard case BridgeServer.StartError.noFreePort = error else {
                return XCTFail("ожидали StartError.noFreePort, получили \(error)")
            }
        }
    }

    func testUnauthenticatedNewcomerDoesNotDisplacePairedClient() throws {
        // Локальная страница в цикле `new WebSocket(...)` не должна рвать мост:
        // пока претендент не прислал корректный hello, спаренный клиент — тот же.
        server = try makeServer(extensionId: extensionId, secret: "known-secret")
        let connectedA = expectation(description: "A подключён")
        server.onConnect = { connectedA.fulfill() }

        let taskA = connect(to: server)
        taskA.send(.string(hello(secret: "known-secret"))) { _ in }
        wait(for: [connectedA], timeout: 5)
        XCTAssertTrue(server.isConnected)

        var disconnects = 0
        server.onDisconnect = { disconnects += 1 }

        // Пять молчаливых претендентов подряд — ровно то, что делает цикл
        // переподключений на посторонней странице.
        var noise: [URLSessionWebSocketTask] = []
        for _ in 0..<5 { noise.append(connect(to: server)) }
        defer {
            taskA.cancel(with: .goingAway, reason: nil)
            for task in noise { task.cancel(with: .goingAway, reason: nil) }
        }

        let settled = expectation(description: "пауза дольше helloTimeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + BridgeServer.helloTimeout + 1) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: BridgeServer.helloTimeout + 4)

        XCTAssertEqual(disconnects, 0, "мост не должен рваться из-за чужих подключений")
        XCTAssertTrue(server.isConnected, "спаренный клиент остаётся подключённым")

        // И связь с A по-прежнему живая.
        let delivered = expectation(description: "состояние от A доставлено")
        server.onMessage = { _ in delivered.fulfill() }
        taskA.send(.string(#"{"v":1,"type":"state","context":"in-call","muted":true}"#)) { _ in }
        wait(for: [delivered], timeout: 5)
    }

    func testAuthenticatedNewcomerDisplacesPreviousClient() throws {
        // А вот спарившийся претендент вытесняет предыдущего — и об этом
        // приложение обязано узнать: иначе `isConnected` разойдётся с реальностью.
        server = try makeServer(extensionId: extensionId, secret: "known-secret")
        let connectedA = expectation(description: "A подключён")
        server.onConnect = { connectedA.fulfill() }

        let taskA = connect(to: server)
        taskA.send(.string(hello(secret: "known-secret"))) { _ in }
        wait(for: [connectedA], timeout: 5)

        let disconnectedA = expectation(description: "A вытеснен спарившимся B")
        let connectedB = expectation(description: "B подключён")
        server.onDisconnect = { disconnectedA.fulfill() }
        server.onConnect = { connectedB.fulfill() }

        let taskB = connect(to: server)
        defer {
            taskA.cancel(with: .goingAway, reason: nil)
            taskB.cancel(with: .goingAway, reason: nil)
        }
        taskB.send(.string(hello(secret: "known-secret"))) { _ in }

        wait(for: [disconnectedA, connectedB], timeout: 5)
        XCTAssertTrue(server.isConnected)
    }

    func testRefusalSilencesFurtherDialogsForACooldown() throws {
        // После «Отклонить» соединение рвётся, и та же страница подключается
        // снова. Без паузы это бесконечный поток модальных окон.
        server = BridgeServer(portRange: 8941...8942,
                              pairing: PairingStore(secret: nil))
        var askCount = 0
        let asked = expectation(description: "спросили первый раз")
        server.pairingRequest = { _, _, decide in
            askCount += 1
            if askCount == 1 { asked.fulfill() }
            decide(false)
        }
        try server.start()

        let first = connect(to: server)
        first.send(.string(hello())) { _ in }
        wait(for: [asked], timeout: 5)

        var retries: [URLSessionWebSocketTask] = []
        defer {
            first.cancel(with: .goingAway, reason: nil)
            for task in retries { task.cancel(with: .goingAway, reason: nil) }
        }

        for _ in 0..<5 {
            let task = connect(to: server)
            task.send(.string(hello())) { _ in }
            retries.append(task)
        }

        let settled = expectation(description: "пауза, чтобы дать шанс лишним диалогам")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 4)

        XCTAssertEqual(askCount, 1, "после отказа новые диалоги показывать нельзя")
    }

    func testDialogReturnsAfterCooldownExpires() throws {
        // Пауза временная, а не запрет навсегда: спариться после ошибочного
        // отказа человек должен иметь возможность.
        server = BridgeServer(portRange: 8943...8944,
                              pairing: PairingStore(secret: nil),
                              approvalCooldown: 0.5)
        var askCount = 0
        let refused = expectation(description: "первый отказ")
        let askedAgain = expectation(description: "диалог вернулся после паузы")
        server.pairingRequest = { _, _, decide in
            askCount += 1
            if askCount == 1 { refused.fulfill() }
            if askCount == 2 { askedAgain.fulfill() }
            decide(false)
        }
        try server.start()

        let first = connect(to: server)
        defer { first.cancel(with: .goingAway, reason: nil) }
        first.send(.string(hello())) { _ in }
        wait(for: [refused], timeout: 5)

        let waited = expectation(description: "пауза истекла")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { waited.fulfill() }
        wait(for: [waited], timeout: 3)

        let second = connect(to: server)
        defer { second.cancel(with: .goingAway, reason: nil) }
        second.send(.string(hello())) { _ in }
        wait(for: [askedAgain], timeout: 5)
    }

    func testRepeatedHelloWhileApprovalPendingAsksOnce() throws {
        server = BridgeServer(portRange: 8933...8934, pairing: PairingStore(secret: nil))
        var askCount = 0
        var pendingDecide: ((Bool) -> Void)?
        let asked = expectation(description: "спросили один раз")
        server.pairingRequest = { _, _, decide in
            askCount += 1
            pendingDecide = decide
            asked.fulfill()
        }
        try server.start()

        let task = connect(to: server)
        defer { task.cancel(with: .goingAway, reason: nil) }

        // Спамим hello, пока решение пользователя ещё не принято.
        for _ in 0..<5 {
            task.send(.string(hello())) { _ in }
        }

        wait(for: [asked], timeout: 5)

        let settled = expectation(description: "пауза, чтобы дать шанс лишним диалогам")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        XCTAssertEqual(askCount, 1, "спамом hello нельзя плодить диалоги подтверждения")

        var pairedCount = 0
        server.onPaired = { _, _ in pairedCount += 1 }
        pendingDecide?(true)

        let paired = expectation(description: "пауза после решения пользователя")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { paired.fulfill() }
        wait(for: [paired], timeout: 3)
        XCTAssertEqual(pairedCount, 1, "решение пользователя должно выдать секрет ровно один раз")
    }

    func testHelloAfterAuthenticationDoesNotReauthenticate() throws {
        server = try makeServer()
        var connectCount = 0
        var pairedCount = 0
        let connected = expectation(description: "клиент подключён")
        server.onConnect = {
            connectCount += 1
            connected.fulfill()
        }
        server.onPaired = { _, _ in pairedCount += 1 }

        let task = connect(to: server)
        defer { task.cancel(with: .goingAway, reason: nil) }
        task.send(.string(hello())) { _ in }
        wait(for: [connected], timeout: 5)

        for _ in 0..<3 {
            task.send(.string(hello())) { _ in }
        }

        let settled = expectation(description: "пауза")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        XCTAssertEqual(connectCount, 1, "повторный hello не должен переподключать уже аутентифицированного клиента")
        XCTAssertEqual(pairedCount, 1, "повторный hello не должен перевыпускать секрет")
    }

    func testOnlyOneApprovalDialogIsOutstandingAtATime() throws {
        // Претендентов может быть сколько угодно: сокет к 127.0.0.1 открывает
        // любая локальная страница. Пока решение по первому не принято, второй
        // диалог не открывается — иначе это тот же поток модальных окон.
        server = BridgeServer(portRange: 8935...8936, pairing: PairingStore(secret: nil))
        var askCount = 0
        var pendingDecide: ((Bool) -> Void)?
        let firstAsked = expectation(description: "A запросил подтверждение")
        server.pairingRequest = { _, _, decide in
            askCount += 1
            if askCount == 1 {
                pendingDecide = decide
                firstAsked.fulfill()
            } else {
                decide(false)
            }
        }
        try server.start()

        // A подключается, шлёт hello и повисает в ожидании решения пользователя.
        let taskA = connect(to: server)
        taskA.send(.string(hello())) { _ in }
        wait(for: [firstAsked], timeout: 5)

        // Пока диалог A висит, ещё пятеро пытаются спариться.
        var others: [URLSessionWebSocketTask] = []
        for _ in 0..<5 {
            let task = connect(to: server)
            task.send(.string(hello())) { _ in }
            others.append(task)
        }
        defer {
            taskA.cancel(with: .goingAway, reason: nil)
            for task in others { task.cancel(with: .goingAway, reason: nil) }
        }

        let settled = expectation(description: "пауза")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        XCTAssertEqual(askCount, 1, "второй диалог поверх первого показывать нельзя")

        // Молчаливый отказ претендентам — не решение пользователя, и паузу
        // запускать не должен: спариться после этого по-прежнему можно.
        let paired = expectation(description: "решение по A принято")
        server.onPaired = { _, _ in paired.fulfill() }
        pendingDecide?(true)
        wait(for: [paired], timeout: 5)
    }

    func testPairingDialogSurvivesLongerThanHelloTimeout() throws {
        // Диалог подтверждения — модальный NSAlert, который человек должен
        // прочитать и осознанно подтвердить; 3 секунды helloTimeout на это не
        // рассчитаны. Пока решение висит, таймаут не должен рвать соединение.
        server = BridgeServer(portRange: 8939...8940, pairing: PairingStore(secret: nil))
        var pendingDecide: ((Bool) -> Void)?
        let asked = expectation(description: "диалог показан")
        server.pairingRequest = { _, _, decide in
            pendingDecide = decide
            asked.fulfill()
        }
        try server.start()

        let connected = expectation(description: "клиент подключён после долгого решения")
        server.onConnect = { connected.fulfill() }

        let task = connect(to: server)
        defer { task.cancel(with: .goingAway, reason: nil) }
        task.send(.string(hello())) { _ in }
        wait(for: [asked], timeout: 5)

        // Ждём заметно дольше helloTimeout (3 с), прежде чем ответить решением
        // пользователя — таймаут не должен успеть разорвать соединение.
        let waitedPastTimeout = expectation(description: "пауза дольше helloTimeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + BridgeServer.helloTimeout + 2) {
            waitedPastTimeout.fulfill()
        }
        wait(for: [waitedPastTimeout], timeout: BridgeServer.helloTimeout + 5)

        pendingDecide?(true)
        wait(for: [connected], timeout: 5)
        XCTAssertTrue(server.isConnected, "спаривание после долгого решения должно завершиться успешно")
    }
}
