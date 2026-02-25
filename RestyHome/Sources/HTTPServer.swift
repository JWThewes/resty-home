import Foundation
import Network
import HomeKit

/// Minimal HTTP/1.1 server using NWListener (zero external dependencies).
/// Listens on a configurable localhost port and exposes HomeKit data as a REST API.
///
/// GET endpoints serve from the `HomeKitCache` (instant, pre-serialized).
/// POST endpoints (set characteristic, execute scene) call HomeKit live.
///
/// Endpoints:
///   GET  /health                                  - Health check
///   GET  /homes                                   - List all homes
///   GET  /homes/{homeId}/accessories               - List accessories (cached)
///   GET  /homes/{homeId}/accessories/{id}          - Single accessory detail (live)
///   POST /homes/{homeId}/accessories/{id}/set      - Set characteristic value
///   GET  /homes/{homeId}/rooms                     - List rooms (cached)
///   GET  /homes/{homeId}/scenes                    - List scenes (cached)
///   POST /homes/{homeId}/scenes/{id}/execute       - Execute a scene
final class HTTPServer {

    // MARK: - Properties

    private let cache: HomeKitCache
    private let port: UInt16
    private var listener: NWListener?

    // MARK: - Init

    init(cache: HomeKitCache, port: UInt16) {
        self.cache = cache
        self.port = port
    }

    // MARK: - Lifecycle

    func start() {
        do {
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    print("[HTTPServer] Listening on localhost:\(self.port)")
                case .failed(let error):
                    print("[HTTPServer] Failed to start: \(error)")
                default:
                    break
                }
            }
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener?.start(queue: .main)
        } catch {
            print("[HTTPServer] Error creating listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        print("[HTTPServer] Stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveFullRequest(connection: connection, accumulated: Data())
    }

    private func receiveFullRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }

            if let raw = String(data: buffer, encoding: .utf8),
               let headerEnd = raw.range(of: "\r\n\r\n") {

                let headerPart = String(raw[..<headerEnd.lowerBound])
                let contentLength = self.parseContentLength(headerPart)
                let bodyReceived = raw[headerEnd.upperBound...].utf8.count

                if bodyReceived < contentLength && !isComplete {
                    self.receiveFullRequest(connection: connection, accumulated: buffer)
                    return
                }

                self.route(raw: raw, connection: connection)
            } else if isComplete || buffer.count > 1_048_576 {
                connection.cancel()
            } else {
                self.receiveFullRequest(connection: connection, accumulated: buffer)
            }
        }
    }

    private func parseContentLength(_ headers: String) -> Int {
        for line in headers.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces) ?? "0"
                return Int(value) ?? 0
            }
        }
        return 0
    }

    // MARK: - Routing

    private func route(raw: String, connection: NWConnection) {
        let lines = raw.split(separator: "\r\n", maxSplits: 1)
        guard let requestLine = lines.first else {
            sendJSON(connection: connection, status: 400, body: [
                "error": localized("error.empty_request"),
            ])
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendJSON(connection: connection, status: 400, body: [
                "error": localized("error.malformed_request"),
            ])
            return
        }

        let method = String(parts[0])
        let rawTarget = String(parts[1])
        let path = Self.extractPath(from: rawTarget)
        let segments = path.split(separator: "/").map(String.init)

        // Extract JSON body for POST requests
        var jsonBody: [String: Any]?
        if method == "POST", let bodyRange = raw.range(of: "\r\n\r\n") {
            let bodyString = String(raw[bodyRange.upperBound...])
            if let bodyData = bodyString.data(using: .utf8) {
                jsonBody = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            }
        }

        // GET /health
        if method == "GET" && path == "/health" {
            sendJSON(connection: connection, status: 200, body: [
                "status": "ok",
                "homes": cache.homeCount,
                "total_accessories": cache.totalAccessoryCount,
                "cache_age_seconds": Int(Date().timeIntervalSince(cache.lastUpdated)),
            ])
            return
        }

        // GET /homes (cached)
        if method == "GET" && segments == ["homes"] {
            sendJSON(connection: connection, status: 200, body: [
                "homes": cache.getHomes(),
            ])
            return
        }

        // Routes under /homes/{homeId}/...
        if segments.count >= 2 && segments[0] == "homes" {
            let homeId = segments[1]

            guard cache.getHomeName(homeId: homeId) != nil else {
                sendJSON(connection: connection, status: 404, body: [
                    "error": String(localized: "error.home_not_found \(homeId)"),
                ])
                return
            }

            if routeHomeSubresource(method: method, segments: segments, homeId: homeId, jsonBody: jsonBody, connection: connection) {
                return
            }
        }

        sendJSON(connection: connection, status: 404, body: [
            "error": String(localized: "error.not_found \(method) \(path)"),
        ])
    }

    /// Routes requests under `/homes/{homeId}/...`. Returns `true` if handled.
    private func routeHomeSubresource(
        method: String,
        segments: [String],
        homeId: String,
        jsonBody: [String: Any]?,
        connection: NWConnection
    ) -> Bool {

        // GET /homes/{homeId}/rooms (cached)
        if method == "GET" && segments.count == 3 && segments[2] == "rooms" {
            sendJSON(connection: connection, status: 200, body: [
                "home": cache.getHomeName(homeId: homeId) ?? homeId,
                "rooms": cache.getRooms(homeId: homeId) ?? [],
            ])
            return true
        }

        // GET /homes/{homeId}/accessories (cached)
        if method == "GET" && segments.count == 3 && segments[2] == "accessories" {
            sendJSON(connection: connection, status: 200, body: [
                "home": cache.getHomeName(homeId: homeId) ?? homeId,
                "accessories": cache.getAccessories(homeId: homeId) ?? [],
            ])
            return true
        }

        // GET /homes/{homeId}/accessories/{accessoryId} (live detail)
        if method == "GET" && segments.count == 4 && segments[2] == "accessories" {
            let accessoryId = segments[3]
            guard let accessory = cache.getAccessory(homeId: homeId, accessoryId: accessoryId) else {
                sendJSON(connection: connection, status: 404, body: [
                    "error": String(localized: "error.accessory_not_found \(accessoryId)"),
                ])
                return true
            }
            sendJSON(connection: connection, status: 200, body: Self.accessoryDetail(accessory))
            return true
        }

        // POST /homes/{homeId}/accessories/{accessoryId}/set (live)
        if method == "POST" && segments.count == 5 && segments[2] == "accessories" && segments[4] == "set" {
            let accessoryId = segments[3]
            guard let accessory = cache.getAccessory(homeId: homeId, accessoryId: accessoryId) else {
                sendJSON(connection: connection, status: 404, body: [
                    "error": String(localized: "error.accessory_not_found \(accessoryId)"),
                ])
                return true
            }
            guard let body = jsonBody else {
                sendJSON(connection: connection, status: 400, body: [
                    "error": localized("error.body_required"),
                ])
                return true
            }
            handleSetCharacteristic(connection: connection, accessory: accessory, body: body)
            return true
        }

        // GET /homes/{homeId}/scenes (cached)
        if method == "GET" && segments.count == 3 && segments[2] == "scenes" {
            sendJSON(connection: connection, status: 200, body: [
                "home": cache.getHomeName(homeId: homeId) ?? homeId,
                "scenes": cache.getScenes(homeId: homeId) ?? [],
            ])
            return true
        }

        // POST /homes/{homeId}/scenes/{sceneId}/execute (live)
        if method == "POST" && segments.count == 5 && segments[2] == "scenes" && segments[4] == "execute" {
            let sceneId = segments[3]
            guard let home = cache.getHome(homeId: homeId),
                  let actionSet = cache.getActionSet(homeId: homeId, sceneId: sceneId) else {
                sendJSON(connection: connection, status: 404, body: [
                    "error": String(localized: "error.scene_not_found \(sceneId)"),
                ])
                return true
            }
            handleExecuteScene(connection: connection, home: home, actionSet: actionSet)
            return true
        }

        return false
    }

    // MARK: - Handlers (live HomeKit calls)

    private func handleSetCharacteristic(connection: NWConnection, accessory: HMAccessory, body: [String: Any]) {
        guard let characteristicType = body["characteristic"] as? String else {
            sendJSON(connection: connection, status: 400, body: [
                "error": localized("error.missing_characteristic"),
            ])
            return
        }

        guard let value = body["value"] else {
            sendJSON(connection: connection, status: 400, body: [
                "error": localized("error.missing_value"),
            ])
            return
        }

        let query = characteristicType.lowercased()
        var targetCharacteristic: HMCharacteristic?
        for service in accessory.services {
            for char in service.characteristics {
                if char.localizedDescription.lowercased() == query
                    || char.characteristicType.lowercased() == query
                    || Self.characteristicAlias(char.characteristicType)?.lowercased() == query {
                    targetCharacteristic = char
                    break
                }
            }
            if targetCharacteristic != nil { break }
        }

        guard let characteristic = targetCharacteristic else {
            let available = accessory.services.flatMap(\.characteristics).map {
                let name = Self.characteristicAlias($0.characteristicType) ?? $0.localizedDescription
                return "\(name) (\($0.characteristicType))"
            }
            sendJSON(connection: connection, status: 404, body: [
                "error": String(localized: "error.characteristic_not_found \(characteristicType)"),
                "available_characteristics": available,
            ])
            return
        }

        guard characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
            sendJSON(connection: connection, status: 400, body: [
                "error": String(localized: "error.characteristic_not_writable \(characteristicType)"),
            ])
            return
        }

        characteristic.writeValue(value) { [weak self] error in
            if let error {
                self?.sendJSON(connection: connection, status: 500, body: [
                    "error": String(localized: "error.set_value_failed \(error.localizedDescription)"),
                ])
            } else {
                self?.sendJSON(connection: connection, status: 200, body: [
                    "success": true,
                    "accessory": accessory.name,
                    "characteristic": Self.characteristicAlias(characteristic.characteristicType)
                        ?? characteristic.localizedDescription,
                    "value": value,
                ])
            }
        }
    }

    private func handleExecuteScene(connection: NWConnection, home: HMHome, actionSet: HMActionSet) {
        home.executeActionSet(actionSet) { [weak self] error in
            if let error {
                self?.sendJSON(connection: connection, status: 500, body: [
                    "error": String(localized: "error.execute_scene_failed \(error.localizedDescription)"),
                ])
            } else {
                self?.sendJSON(connection: connection, status: 200, body: [
                    "success": true,
                    "scene": actionSet.name,
                ])
            }
        }
    }

    // MARK: - Accessory Detail (live, for individual lookups)

    private static func accessoryDetail(_ accessory: HMAccessory) -> [String: Any] {
        let services: [[String: Any]] = accessory.services.map { service in
            let chars: [[String: Any]] = service.characteristics.map { char in
                var charDict: [String: Any] = [
                    "description": characteristicAlias(char.characteristicType)
                        ?? char.localizedDescription,
                    "type": char.characteristicType,
                    "writable": char.properties.contains(HMCharacteristicPropertyWritable),
                    "readable": char.properties.contains(HMCharacteristicPropertyReadable),
                ]
                if let val = char.value, let safe = sanitizeValue(val) {
                    charDict["value"] = safe
                }
                if let meta = char.metadata {
                    if let min = meta.minimumValue, let safe = sanitizeValue(min) {
                        charDict["min"] = safe
                    }
                    if let max = meta.maximumValue, let safe = sanitizeValue(max) {
                        charDict["max"] = safe
                    }
                    if let units = meta.units {
                        charDict["units"] = units
                    }
                }
                return charDict
            }

            return [
                "name": service.name,
                "type": service.serviceType,
                "characteristics": chars,
            ]
        }

        return [
            "id": accessory.uniqueIdentifier.uuidString,
            "name": accessory.name,
            "room": accessory.room?.name ?? localized("default_room"),
            "manufacturer": accessory.manufacturer ?? localized("unknown"),
            "model": accessory.model ?? localized("unknown"),
            "reachable": accessory.isReachable,
            "category": categoryNameFor(accessory.category),
            "services": services,
        ]
    }

    // MARK: - URL Parsing

    /// Extracts the path component from a request target, handling absolute-form URIs
    /// that HTTP proxies may send (e.g., `http://localhost:18089/homes`).
    private static func extractPath(from rawTarget: String) -> String {
        guard rawTarget.hasPrefix("http://") || rawTarget.hasPrefix("https://") else {
            return rawTarget
        }
        let afterScheme = rawTarget.drop(while: { $0 != ":" }).dropFirst(3)
        if let slashIdx = afterScheme.firstIndex(of: "/") {
            return String(afterScheme[slashIdx...])
        }
        return "/"
    }

    // MARK: - Static Helpers

    static func categoryNameFor(_ category: HMAccessoryCategory) -> String {
        switch category.categoryType {
        case HMAccessoryCategoryTypeLightbulb:         return "lightbulb"
        case HMAccessoryCategoryTypeFan:               return "fan"
        case HMAccessoryCategoryTypeOutlet:            return "outlet"
        case HMAccessoryCategoryTypeSwitch:            return "switch"
        case HMAccessoryCategoryTypeThermostat:        return "thermostat"
        case HMAccessoryCategoryTypeSensor:            return "sensor"
        case HMAccessoryCategoryTypeDoor:              return "door"
        case HMAccessoryCategoryTypeDoorLock:          return "door_lock"
        case HMAccessoryCategoryTypeGarageDoorOpener:  return "garage_door"
        case HMAccessoryCategoryTypeWindow:            return "window"
        case HMAccessoryCategoryTypeWindowCovering:    return "window_covering"
        case HMAccessoryCategoryTypeIPCamera:          return "camera"
        case HMAccessoryCategoryTypeVideoDoorbell:     return "doorbell"
        case HMAccessoryCategoryTypeAirPurifier:       return "air_purifier"
        case HMAccessoryCategoryTypeSprinkler:         return "sprinkler"
        default:                                       return "other"
        }
    }

    static let characteristicAliases: [String: String] = {
        var map: [String: String] = [
            "00000019-0000-1000-8000-0026BB765291": "Lock Current State",
            "00000020-0000-1000-8000-0026BB765291": "Lock Target State",
            "0000006A-0000-1000-8000-0026BB765291": "Contact Sensor State",
            "000000CE-0000-1000-8000-0026BB765291": "Color Temperature",
        ]
        map[HMCharacteristicTypePowerState]              = "Power State"
        map[HMCharacteristicTypeBrightness]              = "Brightness"
        map[HMCharacteristicTypeHue]                     = "Hue"
        map[HMCharacteristicTypeSaturation]              = "Saturation"
        map[HMCharacteristicTypeCurrentTemperature]      = "Current Temperature"
        map[HMCharacteristicTypeTargetTemperature]       = "Target Temperature"
        map[HMCharacteristicTypeCurrentRelativeHumidity] = "Current Relative Humidity"
        map[HMCharacteristicTypeTargetRelativeHumidity]  = "Target Relative Humidity"
        map[HMCharacteristicTypeCurrentHeatingCooling]   = "Current Heating Cooling"
        map[HMCharacteristicTypeTargetHeatingCooling]    = "Target Heating Cooling"
        map[HMCharacteristicTypeMotionDetected]          = "Motion Detected"
        map[HMCharacteristicTypeBatteryLevel]            = "Battery Level"
        map[HMCharacteristicTypeStatusLowBattery]        = "Status Low Battery"
        map[HMCharacteristicTypeCurrentDoorState]        = "Current Door State"
        map[HMCharacteristicTypeTargetDoorState]         = "Target Door State"
        map[HMCharacteristicTypeObstructionDetected]     = "Obstruction Detected"
        map[HMCharacteristicTypeCurrentLightLevel]       = "Current Light Level"
        map[HMCharacteristicTypeActive]                  = "Active"
        map[HMCharacteristicTypeInUse]                   = "In Use"
        return map
    }()

    static func characteristicAlias(_ hapType: String) -> String? {
        characteristicAliases[hapType]
    }

    // MARK: - HTTP Response

    private func sendJSON(connection: NWConnection, status: Int, body: Any) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default:  statusText = "Unknown"
        }

        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: body,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            connection.cancel()
            return
        }

        let header = "HTTP/1.1 \(status) \(statusText)\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(jsonData.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            + "Access-Control-Allow-Headers: Content-Type\r\n"
            + "Connection: close\r\n"
            + "\r\n"

        var responseData = Data(header.utf8)
        responseData.append(jsonData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
