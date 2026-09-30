import Foundation
import Testing
@testable import EnveHomelab

struct UnraidSystemDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesUPSDevice() throws {
        let device = try decode(UPSDevice.self, """
        {"id":"ups1","name":"Rack","model":"Back-UPS 1500","status":"On Battery",
         "battery":{"chargeLevel":64,"estimatedRuntime":1800,"health":"Good"},
         "power":{"inputVoltage":0,"outputVoltage":120.2,"loadPercentage":40,"nominalPower":900,"currentPower":360.0}}
        """)
        #expect(device.isOnBattery)
        #expect(device.health == .warning)
        #expect(device.power.currentPower == 360)
    }

    @Test func upsHealthRules() throws {
        let base = try decode(UPSDevice.self, """
        {"id":"u","name":"n","model":"m","status":"Online","battery":{"chargeLevel":100,"estimatedRuntime":3000,"health":"Good"},
         "power":{"inputVoltage":120,"outputVoltage":120,"loadPercentage":20}}
        """)
        #expect(base.health == .ok)
        var low = base
        low.status = "Low Battery"
        #expect(low.health == .critical)
        var replace = base
        replace.battery.health = "Replace"
        #expect(replace.health == .critical)
        var loaded = base
        loaded.power.loadPercentage = 85
        #expect(loaded.health == .warning)
    }

    @Test func mergesUPSUpdatesByID() throws {
        let a = try decode(UPSDevice.self, #"{"id":"a","name":"A","model":"m","status":"Online","battery":{"chargeLevel":100,"estimatedRuntime":1,"health":"Good"},"power":{"inputVoltage":1,"outputVoltage":1,"loadPercentage":1}}"#)
        var updated = a
        updated.status = "On Battery"
        var b = a
        b.id = "b"
        #expect(UPSDevice.merging(updated, into: [a]) == [updated])
        #expect(UPSDevice.merging(b, into: [a]).map(\.id) == ["a", "b"])
    }

    @Test func decodesPhysicalDiskAndMatchesArraySlot() throws {
        let disk = try decode(PhysicalDisk.self, """
        {"id":"d1","device":"/dev/sdb","type":"HDD","name":"WDC WUH721818","vendor":"WDC","size":18000207937536,
         "firmwareRevision":"PCGNW232","serialNum":"ABC","interfaceType":"SATA","smartStatus":"OK","temperature":null,
         "partitions":[{"name":"sdb1","fsType":"XFS","size":18000206888960}],"isSpinning":false}
        """)
        #expect(disk.smartStatus == .ok)
        #expect(disk.interfaceType == .sata)
        #expect(disk.temperature == nil)
        let slot = try decode(ArrayDisk.self, #"{"id":"x","idx":1,"device":"sdb","type":"DATA"}"#)
        let other = try decode(ArrayDisk.self, #"{"id":"y","idx":2,"device":"sdc","type":"DATA"}"#)
        #expect(disk.matches(slot))
        #expect(!disk.matches(other))
    }

    @Test func unknownSmartAndInterfaceValuesDegrade() throws {
        let disk = try decode(PhysicalDisk.self, """
        {"id":"d","device":"/dev/nvme0n1","type":"SSD","name":"n","vendor":"v","size":1,"firmwareRevision":"f","serialNum":"s",
         "interfaceType":"THUNDERBOLT","smartStatus":"FAILING","partitions":[],"isSpinning":true}
        """)
        #expect(disk.interfaceType == .unknown)
        #expect(disk.smartStatus == .unknown)
    }

    @Test func shareTotalsFallBackToUsedPlusFree() throws {
        let share = try decode(UnraidShare.self, #"{"id":"s","name":"media","free":"1000","used":3000,"size":0,"comment":"","include":["disk1"]}"#)
        #expect(share.totalKB == 4000)
        #expect(share.usedFraction == 0.75)
        #expect(share.comment == nil)
        #expect(share.includedDisks == ["disk1"])
    }

    @Test func containerUpdateAvailabilityDistinguishesMissingField() {
        #expect(ContainerUpdateAvailability(true) == .available)
        #expect(ContainerUpdateAvailability(false) == .upToDate)
        #expect(ContainerUpdateAvailability(nil) == .notReported)
    }

    @Test func memoryUsageDecodesBigIntStrings() throws {
        let memory = try decode(MemoryUsage.self, #"{"total":"68719476736","used":1024,"available":"2048","percentTotal":41.5,"swapTotal":0,"swapUsed":0}"#)
        #expect(memory.total == 68_719_476_736)
        #expect(memory.percent == 41.5)
    }
}

struct ArrayControlAssessmentTests {
    private func disk(_ name: String, status: ArrayDiskStatus, type: ArrayDiskType = .data) -> ArrayDisk {
        ArrayDisk(id: name, slot: 1, name: name, device: nil, sizeKB: nil, status: status, rotational: true, temperature: nil,
                  reads: nil, writes: nil, errors: nil, filesystemSizeKB: nil, filesystemFreeKB: nil, filesystemUsedKB: nil,
                  filesystemType: nil, type: type, usageWarningPercent: nil, usageCriticalPercent: nil, isSpinning: nil, transport: nil, comment: nil)
    }

    private func array(_ state: ArrayState, disks: [ArrayDisk] = [], parity: ParityCheck? = nil) -> ArrayStatus {
        ArrayStatus(state: state, capacity: ArrayCapacity(totalKB: 1, usedKB: 0, freeKB: 1), parityCheck: parity,
                    parities: [], disks: disks, caches: [], boot: nil)
    }

    @Test func stoppingListsWorkloadsAndParityImpact() {
        let running = ParityCheck(status: .running, running: true)
        let result = ArrayControlAssessment.assess(array(.started, parity: running), runningContainers: 5, runningVMs: 1)
        #expect(result.action == .stop)
        #expect(result.isAllowed)
        #expect(result.warnings.contains("5 running containers will be stopped."))
        #expect(result.warnings.contains { $0.hasPrefix("1 running VM will be shut down") })
        #expect(result.warnings.contains("The parity check in progress will be cancelled."))
    }

    @Test func unknownWorkloadCountsStillWarn() {
        let result = ArrayControlAssessment.assess(array(.started), runningContainers: nil, runningVMs: nil)
        #expect(result.warnings.contains("Running containers will be stopped."))
        #expect(result.warnings.contains("Running VMs will be shut down."))
    }

    @Test func startingIsBlockedWhenAssignmentsChanged() {
        let result = ArrayControlAssessment.assess(array(.stopped, disks: [disk("disk2", status: .wrong), disk("disk3", status: .missing)]), runningContainers: 0, runningVMs: 0)
        #expect(result.action == .start)
        #expect(!result.isAllowed)
        #expect(result.blockers.first?.contains("Disk2, Disk3") == true)
    }

    @Test func startingWithDisabledDiskWarnsAboutEmulation() {
        let result = ArrayControlAssessment.assess(array(.stopped, disks: [disk("disk1", status: .disabled), disk("disk4", status: .ok)]), runningContainers: 0, runningVMs: 0)
        #expect(result.isAllowed)
        #expect(result.warnings.contains("Disk1 will run emulated from parity."))
    }

    @Test(arguments: [ArrayState.newArray, .invalidExpansion, .tooManyMissingDisks, .unknown])
    func abnormalStatesOfferNoOperation(_ state: ArrayState) {
        let result = ArrayControlAssessment.assess(array(state), runningContainers: 0, runningVMs: 0)
        #expect(result.action == nil)
        #expect(!result.isAllowed)
    }
}
