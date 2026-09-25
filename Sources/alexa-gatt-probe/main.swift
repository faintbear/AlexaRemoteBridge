import CoreBluetooth
import Foundation

final class GATTProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var seen = Set<UUID>()

    func run() {
        central = CBCentralManager(delegate: self, queue: nil)
        print("gatt_probe_started mode=read_only target=AR")
        RunLoop.current.run()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            print("bluetooth_state=\(central.state.rawValue)")
            fflush(stdout)
            return
        }
        for service in ["1812", "180A", "180F", "1800"] {
            for item in central.retrieveConnectedPeripherals(withServices: [CBUUID(string: service)]) {
                consider(item, source: "connected")
            }
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        print("scanning=true")
        fflush(stdout)
    }

    func centralManager(_ central: CBCentralManager, didDiscover item: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        consider(item, source: "scan")
    }

    private func consider(_ item: CBPeripheral, source: String) {
        guard item.name == "AR", !seen.contains(item.identifier) else { return }
        seen.insert(item.identifier)
        peripheral = item
        item.delegate = self
        print("remote_found source=\(source) name=AR")
        central.stopScan()
        central.connect(item)
        fflush(stdout)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("remote_connected")
        peripheral.discoverServices(nil)
        fflush(stdout)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("connect_failed error=\(error?.localizedDescription ?? "unknown")")
        fflush(stdout)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { print("services_failed error=\(error.localizedDescription)") }
        for service in peripheral.services ?? [] {
            print("service=\(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
        fflush(stdout)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { print("characteristics_failed service=\(service.uuid.uuidString) error=\(error.localizedDescription)") }
        for item in service.characteristics ?? [] {
            print("characteristic service=\(service.uuid.uuidString) uuid=\(item.uuid.uuidString) properties=0x\(String(item.properties.rawValue, radix: 16))")
            if service.uuid == CBUUID(string: "5DE20000-5E8D-11E6-8B77-86F30CA893D3") {
                if item.uuid == CBUUID(string: "5DD24A18-5E8D-11E6-8B77-86F30CA893D3") ||
                    item.uuid == CBUUID(string: "5DE24A19-5E8D-11E6-8B77-86F30CA893D3") {
                    peripheral.setNotifyValue(true, for: item)
                }
                if item.properties.contains(.read) {
                    peripheral.readValue(for: item)
                }
            }
        }
        fflush(stdout)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        print("notification uuid=\(characteristic.uuid.uuidString) enabled=\(characteristic.isNotifying) error=\(error?.localizedDescription ?? "none")")
        fflush(stdout)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let prefix = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
        print("value uuid=\(characteristic.uuid.uuidString) length=\(data.count) prefix=\(prefix) error=\(error?.localizedDescription ?? "none")")
        fflush(stdout)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("remote_disconnected error=\(error?.localizedDescription ?? "none")")
        fflush(stdout)
    }
}

GATTProbe().run()
