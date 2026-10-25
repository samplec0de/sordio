import AppKit
import CoreBluetooth
import SordioCore

/// Связь с Flipper Zero, на котором запущено приложение Sordio Remote.
///
/// Mac здесь — центральное устройство: Flipper отдаёт нажатия кнопки
/// (indicate), а Mac пишет ему подтверждённое состояние микрофона. Протокол —
/// в `FlipperProtocol`; здесь только транспорт, поэтому автотестов у класса
/// нет, как и у `HotkeyMonitor`.
///
/// Все колбэки приходят в главном потоке.
final class FlipperLink: NSObject {
    enum Status: Equatable {
        case disabled
        case bluetoothOff
        case unauthorized
        case unsupported
        case searching
        case connecting
        case connected
        /// Сопряжение не состоялось (PIN не подтверждён или отклонён). Сами
        /// не повторяем: каждая попытка — новое системное окно с PIN.
        case pairingFailed
    }

    /// Сколько ждём перед повторным подключением после обрыва или ошибки.
    private static let retryDelay: TimeInterval = 3

    private static let serviceUUID = CBUUID(string: FlipperProtocol.serviceUUID)
    private static let eventsUUID = CBUUID(string: FlipperProtocol.eventsUUID)
    private static let stateUUID = CBUUID(string: FlipperProtocol.stateUUID)

    var onEvent: ((FlipperEvent) -> Void)?
    var onStatus: ((Status) -> Void)?
    /// Связь потеряна — нажатая кнопка уже никогда не будет отпущена.
    var onDisconnect: (() -> Void)?
    /// Flipper найден и подписан; его идентификатор стоит запомнить, чтобы
    /// в следующий раз подключаться без поиска.
    var onPeripheralKnown: ((UUID) -> Void)?

    private(set) var status: Status = .disabled {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var stateCharacteristic: CBCharacteristic?
    private var savedIdentifier: UUID?

    /// Что показываем на Flipper'е сейчас и что ему уже отправлено: повтор того
    /// же байта не нужен, а после переподключения — нужен, Flipper его забыл.
    private var wantedState: OverlayState?
    private var writtenState: OverlayState?

    init(savedIdentifier: UUID?) {
        self.savedIdentifier = savedIdentifier
        super.init()
    }

    // MARK: - управление

    /// Первый вызов создаёт `CBCentralManager`, а с ним — системный запрос
    /// на доступ к Bluetooth. Поэтому по умолчанию связь выключена и стартует
    /// только по явному выбору в меню.
    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func stop() {
        guard let central else { return }
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        let wasConnected = status == .connected
        resetConnection()
        self.central = nil
        status = .disabled
        if wasConnected { onDisconnect?() }
    }

    /// Забыть запомненный Flipper и искать заново — например, чтобы сменить
    /// устройство. Системное сопряжение при этом остаётся в настройках Bluetooth.
    func forget() {
        savedIdentifier = nil
        guard let central else { return }
        let wasConnected = status == .connected
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        resetConnection()
        if wasConnected { onDisconnect?() }
        if central.state == .poweredOn { begin() }
    }

    /// Показать состояние микрофона на Flipper'е. Безопасно звать на каждое
    /// изменение: отправляется только новое значение и только при живой связи.
    func show(_ state: OverlayState) {
        wantedState = state
        writePendingState()
    }

    static func openBluetoothSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - подключение

    private func resetConnection() {
        peripheral?.delegate = nil
        peripheral = nil
        stateCharacteristic = nil
        writtenState = nil
    }

    /// С запомненным Flipper'ом — отложенное подключение: система сама
    /// завершит его, когда устройство появится в эфире (то есть когда на нём
    /// запустят приложение), и никакого сканирования не нужно. Без него —
    /// поиск по имени.
    private func begin() {
        guard let central, central.state == .poweredOn else { return }
        status = .searching

        if let id = savedIdentifier,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    private func connect(_ target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        central?.connect(target)
    }

    /// Повторная попытка после обрыва. Выполняется, только если связь по-прежнему
    /// нужна и никто не успел начать новую.
    private func retryLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self, self.central != nil, self.status == .searching else { return }
            self.begin()
        }
    }

    private func writePendingState() {
        guard status == .connected, let peripheral, let stateCharacteristic,
              let wantedState, wantedState != writtenState else { return }
        writtenState = wantedState
        peripheral.writeValue(Data([FlipperProtocol.encode(wantedState)]),
                              for: stateCharacteristic, type: .withResponse)
    }

    private func linkLost() {
        let wasConnected = status == .connected
        resetConnection()
        status = .searching
        if wasConnected { onDisconnect?() }
        retryLater()
    }
}

// MARK: - CBCentralManagerDelegate

extension FlipperLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            begin()
        case .poweredOff:
            let wasConnected = status == .connected
            resetConnection()
            status = .bluetoothOff
            if wasConnected { onDisconnect?() }
        case .unauthorized:
            status = .unauthorized
        case .unsupported:
            status = .unsupported
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? found.name ?? ""
        guard name.hasPrefix("Flipper"), peripheral == nil else { return }
        central.stopScan()
        status = .connecting
        connect(found)
    }

    func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        status = .connecting
        connected.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral,
                        error: Error?) {
        guard failed === peripheral else { return }
        linkLost()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral gone: CBPeripheral,
                        error: Error?) {
        // Разрыв с устройством, которое мы уже сами отпустили (`forget`,
        // `stop`), — не повод подключаться заново.
        guard gone === peripheral else { return }
        // Отказ от сопряжения тоже заканчивается разрывом, но повторять его
        // нельзя — иначе окно с PIN будет всплывать снова и снова.
        if status == .pairingFailed {
            resetConnection()
            return
        }
        linkLost()
    }
}

// MARK: - CBPeripheralDelegate

extension FlipperLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            // Это Flipper без нужного сервиса — не наш случай, ждём другого.
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.eventsUUID, Self.stateUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.stateUUID:
                stateCharacteristic = characteristic
            case Self.eventsUUID:
                // Подписка — первое обращение к защищённой характеристике, и
                // именно здесь macOS предлагает сопряжение с PIN на экране Flipper'а.
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.eventsUUID else { return }
        guard error == nil, characteristic.isNotifying, stateCharacteristic != nil else {
            status = .pairingFailed
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        status = .connected
        savedIdentifier = peripheral.identifier
        onPeripheralKnown?(peripheral.identifier)
        // Flipper только что (пере)подключился и ничего не помнит.
        writtenState = nil
        writePendingState()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == Self.eventsUUID,
              let data = characteristic.value else { return }
        for event in FlipperProtocol.decode(data) { onEvent?(event) }
    }
}
