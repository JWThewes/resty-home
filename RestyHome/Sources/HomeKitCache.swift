import Foundation
import HomeKit

/// Pre-serialized cache of HomeKit data.
/// Rebuilt automatically when HomeKit reports changes via delegate callbacks.
/// All GET endpoints serve from this cache for instant responses.
final class HomeKitCache: NSObject, HMHomeManagerDelegate, HMHomeDelegate, HMAccessoryDelegate {

    // MARK: - Properties

    private let homeManager: HMHomeManager
    private let lock = NSLock()

    /// Pre-built JSON-ready dictionaries, keyed by home UUID.
    private var homesJSON: [[String: Any]] = []
    private var accessoriesCache: [String: [[String: Any]]] = [:]
    private var roomsCache: [String: [[String: Any]]] = [:]
    private var scenesCache: [String: [[String: Any]]] = [:]

    private(set) var lastUpdated: Date = .distantPast

    // MARK: - Init

    init(homeManager: HMHomeManager) {
        self.homeManager = homeManager
        super.init()
        homeManager.delegate = self
    }

    // MARK: - Public Accessors (thread-safe reads)

    func getHomes() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return homesJSON
    }

    func getAccessories(homeId: String) -> [[String: Any]]? {
        lock.lock()
        defer { lock.unlock() }
        return accessoriesCache[homeId]
    }

    func getRooms(homeId: String) -> [[String: Any]]? {
        lock.lock()
        defer { lock.unlock() }
        return roomsCache[homeId]
    }

    func getScenes(homeId: String) -> [[String: Any]]? {
        lock.lock()
        defer { lock.unlock() }
        return scenesCache[homeId]
    }

    func getHomeName(homeId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return homeManager.homes.first { $0.uniqueIdentifier.uuidString == homeId }?.name
    }

    func getHome(homeId: String) -> HMHome? {
        lock.lock()
        defer { lock.unlock() }
        return homeManager.homes.first { $0.uniqueIdentifier.uuidString == homeId }
    }

    func getAccessory(homeId: String, accessoryId: String) -> HMAccessory? {
        lock.lock()
        defer { lock.unlock() }
        return homeManager.homes
            .first { $0.uniqueIdentifier.uuidString == homeId }?
            .accessories
            .first { $0.uniqueIdentifier.uuidString == accessoryId }
    }

    func getActionSet(homeId: String, sceneId: String) -> HMActionSet? {
        lock.lock()
        defer { lock.unlock() }
        return homeManager.homes
            .first { $0.uniqueIdentifier.uuidString == homeId }?
            .actionSets
            .first { $0.uniqueIdentifier.uuidString == sceneId }
    }

    var totalAccessoryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accessoriesCache.values.reduce(0) { $0 + $1.count }
    }

    var homeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return homesJSON.count
    }

    // MARK: - Cache Rebuild

    func rebuild() {
        lock.lock()
        defer { lock.unlock() }

        let start = CFAbsoluteTimeGetCurrent()

        homesJSON = homeManager.homes.map { home in
            [
                "id": home.uniqueIdentifier.uuidString,
                "name": home.name,
                "is_primary": home.isPrimary,
                "room_count": home.rooms.count,
                "accessory_count": home.accessories.count,
                "scene_count": home.actionSets.count,
            ] as [String: Any]
        }

        for home in homeManager.homes {
            let homeId = home.uniqueIdentifier.uuidString

            // Subscribe to delegate callbacks for real-time updates
            home.delegate = self
            for accessory in home.accessories {
                accessory.delegate = self
            }

            // Accessories
            accessoriesCache[homeId] = home.accessories.map { accessory in
                var status: [String: Any] = [:]
                for service in accessory.services {
                    let serviceType = service.serviceType.lowercased()
                    if serviceType == HMServiceTypeAccessoryInformation.lowercased() {
                        continue
                    }
                    for char in service.characteristics {
                        if let alias = HTTPServer.characteristicAlias(char.characteristicType),
                           let val = char.value,
                           let safe = sanitizeValue(val) {
                            let key = alias.lowercased().replacingOccurrences(of: " ", with: "_")
                            status[key] = safe
                        }
                    }
                }
                return [
                    "id": accessory.uniqueIdentifier.uuidString,
                    "name": accessory.name,
                    "room": accessory.room?.name ?? localized("default_room"),
                    "reachable": accessory.isReachable,
                    "category": HTTPServer.categoryNameFor(accessory.category),
                    "status": status,
                ] as [String: Any]
            }

            // Rooms
            roomsCache[homeId] = home.rooms.map { room in
                [
                    "id": room.uniqueIdentifier.uuidString,
                    "name": room.name,
                    "accessory_count": room.accessories.count,
                ] as [String: Any]
            }

            // Scenes
            scenesCache[homeId] = home.actionSets.map { actionSet in
                [
                    "id": actionSet.uniqueIdentifier.uuidString,
                    "name": actionSet.name,
                    "action_count": actionSet.actions.count,
                ] as [String: Any]
            }
        }

        lastUpdated = Date()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let totalAccessories = accessoriesCache.values.reduce(0) { $0 + $1.count }
        print("[HomeKitCache] Rebuilt in \(String(format: "%.1f", elapsed))ms — "
              + "\(homeManager.homes.count) home(s), \(totalAccessories) accessory(ies)")

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .homeKitCacheDidRebuild, object: self)
        }
    }

    // MARK: - HMHomeManagerDelegate

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        rebuild()
    }

    // MARK: - HMHomeDelegate

    func homeDidUpdateName(_ home: HMHome) { rebuild() }

    func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        accessory.delegate = self
        rebuild()
    }

    func home(_ home: HMHome, didRemove accessory: HMAccessory) { rebuild() }
    func home(_ home: HMHome, didAdd room: HMRoom) { rebuild() }
    func home(_ home: HMHome, didRemove room: HMRoom) { rebuild() }
    func home(_ home: HMHome, didAdd actionSet: HMActionSet) { rebuild() }
    func home(_ home: HMHome, didRemove actionSet: HMActionSet) { rebuild() }

    // MARK: - HMAccessoryDelegate

    func accessoryDidUpdateReachability(_ accessory: HMAccessory) { rebuild() }
    func accessoryDidUpdateServices(_ accessory: HMAccessory) { rebuild() }

    func accessory(
        _ accessory: HMAccessory,
        service: HMService,
        didUpdateValueFor characteristic: HMCharacteristic
    ) {
        rebuild()
    }
}
