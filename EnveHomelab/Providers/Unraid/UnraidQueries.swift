/// Operations written against the published schema in github.com/unraid/api (api/generated-schema.graphql).
/// `compat` variants drop fields added in later API releases.
enum UnraidQueries {
    static let identity = """
    query Identity { vars { name version } }
    """

    static let system = """
    query System {
      info {
        os { hostname uptime kernel }
        cpu { brand cores threads }
        versions { core { unraid api } }
      }
    }
    """

    static let systemCompat = """
    query System {
      info {
        os { hostname uptime kernel }
        cpu { brand cores threads }
      }
    }
    """

    static let metrics = """
    query Metrics {
      metrics {
        cpu { percentTotal }
        memory { total used available percentTotal swapTotal swapUsed }
      }
    }
    """

    private static let diskFields = """
    fragment DiskFields on ArrayDisk {
      id idx name device size status rotational temp numReads numWrites numErrors
      fsSize fsFree fsUsed fsType type warning critical isSpinning transport comment
    }
    """

    private static let diskFieldsCompat = """
    fragment DiskFields on ArrayDisk {
      id idx name device size status rotational temp numReads numWrites numErrors
      fsSize fsFree fsUsed fsType type warning critical comment
    }
    """

    static let array = """
    query ArrayStatus {
      array {
        state
        capacity { kilobytes { free used total } }
        parityCheckStatus { status date duration speed errors progress correcting paused running }
        parities { ...DiskFields }
        disks { ...DiskFields }
        caches { ...DiskFields }
        boot { ...DiskFields }
      }
    }
    """ + diskFields

    static let arraySubscription = """
    subscription ArrayUpdates {
      arraySubscription {
        state
        capacity { kilobytes { free used total } }
        parityCheckStatus { status date duration speed errors progress correcting paused running }
        parities { ...DiskFields }
        disks { ...DiskFields }
        caches { ...DiskFields }
        boot { ...DiskFields }
      }
    }
    """ + diskFields

    static let arrayCompat = """
    query ArrayStatus {
      array {
        state
        capacity { kilobytes { free used total } }
        parities { ...DiskFields }
        disks { ...DiskFields }
        caches { ...DiskFields }
        boot { ...DiskFields }
      }
    }
    """ + diskFieldsCompat

    static let parityHistory = """
    query ParityHistory { parityHistory { status date duration speed errors } }
    """

    static func parity(_ action: ParityAction) -> String {
        switch action {
        case .startCheck: "mutation ParityStart { parityCheck { start(correct: false) } }"
        case .pause: "mutation ParityPause { parityCheck { pause } }"
        case .resume: "mutation ParityResume { parityCheck { resume } }"
        case .cancel: "mutation ParityCancel { parityCheck { cancel } }"
        }
    }

    static let containers = """
    query Containers {
      docker {
        containers {
          id names image state status created autoStart
          ports { ip privatePort publicPort type }
          hostConfig { networkMode }
          mounts webUiUrl iconUrl isUpdateAvailable sizeRootFs
        }
      }
    }
    """

    static let containersCompat = """
    query Containers {
      docker {
        containers {
          id names image state status created autoStart
          ports { ip privatePort publicPort type }
          hostConfig { networkMode }
          mounts
        }
      }
    }
    """

    static let containerLogs = """
    query ContainerLogs($id: PrefixedID!, $tail: Int, $since: DateTime) {
      docker { logs(id: $id, tail: $tail, since: $since) { lines { timestamp message } cursor } }
    }
    """

    static func container(_ action: ContainerAction) -> String {
        "mutation Container($id: PrefixedID!) { docker { \(action.rawValue)(id: $id) { id state status } } }"
    }

    static let virtualMachines = """
    query VirtualMachines { vms { domains { id name state } } }
    """

    static func vm(_ action: VMAction) -> String {
        "mutation VM($id: PrefixedID!) { vm { \(action.rawValue)(id: $id) } }"
    }

    static let notificationOverview = """
    query NotificationOverview {
      notifications {
        overview {
          unread { info warning alert total }
          archive { info warning alert total }
        }
      }
    }
    """

    static let notifications = """
    query Notifications($filter: NotificationFilter!) {
      notifications {
        list(filter: $filter) { id title subject description importance link timestamp formattedTimestamp }
      }
    }
    """

    static let archiveNotification = """
    mutation ArchiveNotification($id: PrefixedID!) { archiveNotification(id: $id) { id } }
    """

    static let archiveAll = """
    mutation ArchiveAll { archiveAll { unread { total } } }
    """

    static let cpuSubscription = """
    subscription CPU { systemMetricsCpu { percentTotal } }
    """

    static let memorySubscription = """
    subscription Memory { systemMetricsMemory { total used available percentTotal swapTotal swapUsed } }
    """

    static let setArrayState = """
    mutation SetArrayState($input: ArrayStateInput!) { array { setState(input: $input) { state } } }
    """

    static let physicalDisks = """
    query PhysicalDisks {
      disks {
        id device type name vendor size firmwareRevision serialNum interfaceType smartStatus temperature isSpinning
        partitions { name fsType size }
      }
    }
    """

    static let shares = """
    query Shares { shares { id name comment free used size cache include exclude allocator splitLevel luksStatus } }
    """

    private static let upsFields = """
    id name model status
    battery { chargeLevel estimatedRuntime health }
    power { inputVoltage outputVoltage loadPercentage nominalPower currentPower }
    """

    static let upsDevices = "query UPS { upsDevices { \(upsFields) } }"

    static let upsSubscription = "subscription UPS { upsUpdates { \(upsFields) } }"

    static let refreshDockerDigests = """
    mutation RefreshDigests { refreshDockerDigests }
    """

    static let updateContainer = """
    mutation UpdateContainer($id: PrefixedID!) { docker { updateContainer(id: $id) { id state status } } }
    """

    static let containerDetails = """
    query ContainerDetails($id: PrefixedID!) {
      docker {
        container(id: $id) {
          id templatePath projectUrl registryUrl supportUrl isOrphaned isUpdateAvailable isRebuildReady
          lanIpPorts sizeRootFs sizeRw sizeLog autoStart autoStartOrder autoStartWait
        }
      }
    }
    """

    static let portConflicts = """
    query PortConflicts {
      docker {
        portConflicts {
          containerPorts { privatePort type containers { id name } }
          lanPorts { lanIpPort publicPort type containers { id name } }
        }
      }
    }
    """

    static let temperatures = """
    query Temperatures {
      metrics {
        temperature {
          summary { average warningCount criticalCount }
          sensors {
            id name type location warning critical
            current { value unit status timestamp }
            min { value unit }
            max { value unit }
            history { value unit timestamp }
          }
        }
      }
    }
    """

    static let logFiles = """
    query LogFiles { logFiles { name path size modifiedAt } }
    """

    static let logFile = """
    query LogFile($path: String!, $lines: Int) { logFile(path: $path, lines: $lines) { path content totalLines startLine } }
    """
}
