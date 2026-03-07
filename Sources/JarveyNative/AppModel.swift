import Foundation

private enum VoiceConnectionError: Error {
  case timeout
}

@MainActor
final class AppModel: ObservableObject {
  @Published var health: HealthSnapshot = .offline
  @Published var settings: SettingsData = .empty
  @Published var apiKeyDraft = ""
  @Published var hotkeyDraft = ""
  @Published var commandDraft = ""
  @Published var memories: [MemoryRecord] = []
  @Published var events: [BackendEvent] = []
  @Published var permissions = NativePermissionSnapshot(
    microphone: "unknown",
    screen: "unknown",
    accessibilityTrusted: false,
    voiceRuntimeSupported: false
  )
  @Published var pendingApproval: ApprovalRequest?
  @Published var pendingRealtimeApproval: VoiceApprovalState?
  @Published var activeTaskId: String?
  @Published var phase = "idle"
  @Published var voiceState = VoiceRuntimeState(
    connected: false,
    muted: false,
    phase: "idle",
    currentAgent: "ConversationAgent",
    level: 0
  )
  @Published var transcript: [TranscriptEntry] = []
  @Published var errorMessage = ""
  @Published var voiceRuntimeErrorMessage = ""
  @Published var sidecarReady = false
  @Published var overlayVisible = false
  @Published var listeningModeActive = false

  private let client = SidecarClient()
  private let sidecar = SidecarProcessController()
  private let permissionCoordinator: PermissionCoordinator
  private var eventsTask: Task<Void, Never>?
  private var accessibilityRefreshTask: Task<Void, Never>?
  private var seenBackendEventIDs = Set<String>()
  private weak var voiceController: VoiceRuntimeControlling?
  private let nativeLogURL: URL = {
    let base = AppIdentity.logsDirectory()
    return base.appending(path: "native-overlay.log")
  }()

  init(permissionCoordinator: PermissionCoordinator = PermissionCoordinator()) {
    self.permissionCoordinator = permissionCoordinator
    permissions = permissionCoordinator.currentSnapshot()
  }

  func attachVoiceController(_ controller: VoiceRuntimeControlling) {
    voiceController = controller
  }

  func bootstrap() async {
    do {
      try await sidecar.ensureRunning(using: client)
      sidecarReady = true
      await refresh()
      startEventStreamIfNeeded()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func refresh(includeHealth: Bool = true) async {
    var firstError: Error?

    do {
      let nextSettings = try await client.settings()
      settings = nextSettings
      apiKeyDraft = nextSettings.apiKey
      hotkeyDraft = nextSettings.hotkey
    } catch {
      firstError = firstError ?? error
    }

    do {
      memories = try await client.recentMemories(limit: 8)
    } catch {
      firstError = firstError ?? error
    }

    setPermissions(permissionCoordinator.refresh(force: true))

    if includeHealth {
      do {
        health = try await client.health()
      } catch {
        firstError = firstError ?? error
      }
    }

    if let firstError {
      errorMessage = firstError.localizedDescription
    } else {
      errorMessage = ""
    }
    syncPhase()
  }

  func refreshStatus() async {
    var nextError = errorMessage

    setPermissions(permissionCoordinator.refresh(force: true))

    do {
      health = try await client.health()
      sidecarReady = true
      if nextError == SidecarStartupError.failedToBecomeHealthy.localizedDescription {
        nextError = ""
      }
    } catch {
      nextError = error.localizedDescription
    }

    errorMessage = nextError
    syncPhase()
  }

  func overlayActivated() async {
    overlayVisible = true
    if !sidecarReady || hasBlockingSetupIssue {
      await refresh()
      return
    }
    syncPhase()
  }

  func overlayDeactivated() async {
    overlayVisible = false
    listeningModeActive = false
    await voiceController?.close()
    resetVoiceState()
    voiceRuntimeErrorMessage = ""
    pendingRealtimeApproval = nil
    syncPhase()
  }

  func saveApiKey() async {
    do {
      let nextSettings = try await client.updateSettings(
        SettingsPatch(apiKey: apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
      )
      settings = nextSettings
      apiKeyDraft = nextSettings.apiKey
      setPermissions(permissionCoordinator.refresh(force: true))
      errorMessage = ""

      Task {
        await refresh(includeHealth: false)
      }

      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func saveHotkey() async {
    let trimmed = hotkeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      let nextSettings = try await client.updateSettings(SettingsPatch(hotkey: trimmed))
      settings = nextSettings
      hotkeyDraft = nextSettings.hotkey
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func requestPermissions() async {
    setPermissions(await permissionCoordinator.requestMicrophone())
    setPermissions(await permissionCoordinator.requestScreenRecording())

    let accessibilitySnapshot = permissionCoordinator.requestAccessibility()
    setPermissions(accessibilitySnapshot)
    if accessibilitySnapshot.accessibilityTrusted {
      accessibilityRefreshTask?.cancel()
      accessibilityRefreshTask = nil
    } else {
      beginAccessibilityTrustPolling()
    }

    setPermissions(permissionCoordinator.refresh(force: true))
    syncPhase()
  }

  func requestMicrophonePermission() async {
    setPermissions(await permissionCoordinator.requestMicrophone())
    syncPhase()
  }

  func requestScreenPermission() async {
    setPermissions(await permissionCoordinator.requestScreenRecording())
    syncPhase()
  }

  func requestAccessibilityPermission() async {
    let snapshot = permissionCoordinator.requestAccessibility()
    setPermissions(snapshot)
    syncPhase()

    if snapshot.accessibilityTrusted {
      accessibilityRefreshTask?.cancel()
      accessibilityRefreshTask = nil
    } else {
      beginAccessibilityTrustPolling()
    }
  }

  func refreshPermissions(force: Bool = false) {
    setPermissions(permissionCoordinator.refresh(force: force))
    syncPhase()
  }

  func applicationDidBecomeActive() {
    refreshPermissions(force: true)
  }

  func connectVoice(startMuted: Bool = true) async {
    guard sidecarReady else {
      errorMessage = "The local sidecar is not ready yet."
      syncPhase()
      return
    }

    if hasBlockingSetupIssue {
      errorMessage = permissions.voiceRuntimeSupported
        ? "Finish setup before starting voice."
        : "Launch Jarvey from the bundled app so WebKit voice capture can access the microphone."
      syncPhase()
      return
    }

    guard voiceController != nil else {
      errorMessage = "The native voice runtime is still loading."
      syncPhase()
      return
    }

    errorMessage = ""
    voiceRuntimeErrorMessage = ""
    voiceState.phase = "connecting"
    syncPhase()

    let connectTask = Task { [weak self] in
      try await self?.voiceController?.connect(startMuted: startMuted)
    }

    let timeoutTask = Task {
      try await Task.sleep(nanoseconds: 20_000_000_000)
      connectTask.cancel()
    }

    do {
      try await connectTask.value
      timeoutTask.cancel()
      if voiceState.phase == "connecting" {
        // JS connect succeeded but voice state event hasn't arrived yet.
        voiceState.connected = true
        voiceState.phase = startMuted ? "idle" : "listening"
        voiceState.muted = startMuted
        errorMessage = ""
        syncPhase()
      }
    } catch is CancellationError {
      timeoutTask.cancel()
      if voiceState.phase == "connecting" {
        errorMessage = "Voice connection timed out. Check your API key and network."
        syncPhase()
      }
    } catch {
      timeoutTask.cancel()
      if voiceState.phase == "connecting" {
        errorMessage = error.localizedDescription
        syncPhase()
      }
    }
  }

  func disconnectVoice() async {
    listeningModeActive = false
    await voiceController?.close()
    resetVoiceState()
    voiceRuntimeErrorMessage = ""
    syncPhase()
  }

  // MARK: - Listening Mode

  func startListening() async {
    let wasSpeaking = voiceState.phase == "speaking" || phase == "speaking"
    listeningModeActive = true
    overlayVisible = true
    errorMessage = ""
    voiceRuntimeErrorMessage = ""
    voiceState.muted = false
    voiceState.phase = "listening"
    syncPhase()
    if voiceState.connected && wasSpeaking {
      await voiceController?.interrupt()
    }
    if !voiceState.connected {
      await connectVoice(startMuted: false)
      return
    }
    await setVoiceMuted(false)
  }

  func stopListening() async {
    listeningModeActive = false
    syncPhase()
    await setVoiceMuted(true)
  }

  func setVoiceMuted(_ muted: Bool) async {
    guard voiceState.connected else {
      syncPhase()
      return
    }
    do {
      try await voiceController?.setMuted(muted)
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func interruptVoice() async {
    await voiceController?.interrupt()
  }

  func approveRealtimeApproval() async {
    guard pendingRealtimeApproval != nil else {
      return
    }

    do {
      try await voiceController?.approveApproval(alwaysApprove: false)
      pendingRealtimeApproval = nil
      voiceState.phase = "thinking"
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func rejectRealtimeApproval() async {
    guard pendingRealtimeApproval != nil else {
      return
    }

    do {
      try await voiceController?.rejectApproval(
        message: "That memory action was rejected by the user.",
        alwaysReject: false
      )
      pendingRealtimeApproval = nil
      voiceState.phase = "thinking"
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func startTask() async {
    let request = commandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !request.isEmpty else {
      return
    }

    do {
      let started = try await client.startTask(userRequest: request)
      activeTaskId = started.taskId
      commandDraft = ""
      prependSyntheticEvent(
        type: "started",
        taskId: started.taskId,
        summary: "Task submitted to the operator."
      )
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func approvePending() async {
    guard let approval = pendingApproval else {
      return
    }

    do {
      try await client.approve(taskId: approval.taskId, approvalId: approval.id)
      pendingApproval = nil
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func rejectPending() async {
    guard let approval = pendingApproval else {
      return
    }

    do {
      try await client.reject(
        taskId: approval.taskId,
        approvalId: approval.id,
        message: "Rejected from the native overlay."
      )
      pendingApproval = nil
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func cancelActiveTask() async {
    guard let activeTaskId else {
      return
    }

    do {
      try await client.cancel(taskId: activeTaskId)
      self.activeTaskId = nil
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func statusLine(for event: BackendEvent) -> String {
    if let summary = event.summary, !summary.isEmpty {
      return summary
    }
    if let approval = event.approval {
      return approval.summary
    }
    if let result = event.result {
      return result.summary
    }
    if event.type == "screenshot" {
      return "Computer returned a fresh screenshot."
    }
    return event.type
  }

  var compactStatus: String {
    if let realtime = pendingRealtimeApproval {
      return realtime.title
    }

    if let approval = pendingApproval {
      return approval.summary
    }

    if let activeTaskId,
       let event = events.first(where: { $0.taskId == activeTaskId }) {
      return statusLine(for: event)
    }

    if let latest = events.first {
      return statusLine(for: latest)
    }

    if hasBlockingSetupIssue {
      return "Setup required before Jarvey can listen."
    }

    switch phase {
    case "connecting":
      return "Connecting to realtime voice."
    case "listening":
      return "Listening."
    case "thinking":
      return "Thinking."
    case "speaking":
      return "Speaking."
    case "acting":
      return "Working on your request."
    case "approvals":
      return "Waiting for approval."
    case "error":
      return displayErrorMessage.isEmpty ? "Something failed." : displayErrorMessage
    default:
      if voiceState.connected {
        return "Press Option+Space to listen."
      }
      return "Press Option+Space to listen."
    }
  }

  var hasBlockingSetupIssue: Bool {
    settings.apiKey.isEmpty ||
      !health.inputServerAvailable ||
      !permissions.voiceRuntimeSupported ||
      permissions.microphone != "granted" ||
      permissions.screen != "granted" ||
      !permissions.accessibilityTrusted
  }

  var shouldExpandOverlay: Bool {
    false
  }

  var overlayActionCallout: OverlayActionCallout? {
    guard pendingApproval == nil, pendingRealtimeApproval == nil else {
      return nil
    }

    guard let activeTaskId else {
      return nil
    }

    if let event = latestOverlayActionEvent(for: activeTaskId) {
      return makeActionCallout(for: event)
    }

    return OverlayActionCallout(label: "Operator", text: "Preparing the operator.")
  }

  var canAutoHideOverlay: Bool {
    overlayVisible &&
      !listeningModeActive &&
      phase == "idle" &&
      pendingApproval == nil &&
      pendingRealtimeApproval == nil &&
      activeTaskId == nil
  }

  var displayErrorMessage: String {
    if !errorMessage.isEmpty {
      return errorMessage
    }
    return voiceRuntimeErrorMessage
  }

  func handleVoiceEvent(_ event: VoiceBridgeEvent) {
    switch event {
    case .ready:
      break
    case .state(let state):
      voiceState = state
      if state.phase != "error" {
        voiceRuntimeErrorMessage = ""
      }
      if state.connected && !listeningModeActive && !state.muted {
        Task { await setVoiceMuted(true) }
      }
      syncPhase()
    case .transcript(let entries):
      transcript = entries
    case .realtimeApproval(let approval):
      pendingRealtimeApproval = approval
      syncPhase()
    case .error(let message):
      voiceRuntimeErrorMessage = message
      if !voiceState.connected && activeTaskId == nil && pendingApproval == nil && pendingRealtimeApproval == nil {
        voiceState.phase = "error"
      }
      syncPhase()
    case .memoryChanged:
      Task {
        await refresh()
      }
    case .taskState(let taskId):
      activeTaskId = taskId
      syncPhase()
    }
  }

  private func setPermissions(_ snapshot: NativePermissionSnapshot) {
    permissions = snapshot
    if snapshot.accessibilityTrusted {
      accessibilityRefreshTask?.cancel()
      accessibilityRefreshTask = nil
    }
  }

  private func beginAccessibilityTrustPolling() {
    accessibilityRefreshTask?.cancel()
    accessibilityRefreshTask = Task { [weak self] in
      guard let self else {
        return
      }

      for _ in 0..<20 {
        try? await Task.sleep(for: .milliseconds(750))
        if Task.isCancelled {
          return
        }

        self.refreshPermissions(force: true)
        if self.permissions.accessibilityTrusted {
          return
        }
      }
    }
  }

  private func startEventStreamIfNeeded() {
    guard eventsTask == nil else {
      return
    }

    eventsTask = Task { [weak self] in
      guard let self else {
        return
      }

      while !Task.isCancelled {
        do {
          let recentEvents = try await client.recentBackendEvents(limit: 48)
          applyRecentBackendEvents(recentEvents)
          try? await Task.sleep(for: .milliseconds(350))
        } catch {
          if Task.isCancelled {
            return
          }
          logNativeOverlay("Recent backend event poll failed: \(error.localizedDescription)")
          try? await Task.sleep(for: .seconds(1))
        }
      }
    }
  }

  private func handle(event: BackendEvent) {
    events.insert(event, at: 0)
    if events.count > 24 {
      events.removeLast(events.count - 24)
    }

    switch event.type {
    case "started":
      activeTaskId = event.taskId
    case "delegated", "tool_started", "screenshot":
      if activeTaskId == nil {
        activeTaskId = event.taskId
      }
    case "approval_requested":
      pendingApproval = event.approval
    case "approved", "rejected":
      if pendingApproval?.id == event.approvalId {
        pendingApproval = nil
      }
    case "completed":
      activeTaskId = nil
      pendingApproval = nil
      Task {
        await refresh(includeHealth: false)
      }
    case "failed":
      activeTaskId = nil
      errorMessage = event.summary ?? "The task failed."
    case "cancelled":
      activeTaskId = nil
    default:
      break
    }
    if let callout = overlayActionCallout {
      logNativeOverlay("Overlay callout -> [\(callout.label)] \(callout.text)")
    } else {
      logNativeOverlay("Overlay callout cleared.")
    }
    syncPhase()
  }

  private func prependSyntheticEvent(type: String, taskId: String, summary: String) {
    let event = BackendEvent(
      taskId: taskId,
      type: type,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      summary: summary,
      detail: nil,
      approvalId: nil,
      approval: nil,
      result: nil,
      imageBase64: nil
    )
    events.insert(event, at: 0)
  }

  private func resetVoiceState() {
    voiceState = VoiceRuntimeState(
      connected: false,
      muted: true,
      phase: "idle",
      currentAgent: voiceState.currentAgent,
      level: 0
    )
  }

  private func makeActionCallout(for event: BackendEvent) -> OverlayActionCallout {
    switch event.type {
    case "started":
      return OverlayActionCallout(
        label: "Operator",
        text: event.summary ?? "Preparing the operator."
      )
    case "delegated":
      return OverlayActionCallout(
        label: "Agent",
        text: event.summary ?? "Handing the task to a specialist."
      )
    case "screenshot":
      return OverlayActionCallout(
        label: "Action",
        text: "Checking the screen."
      )
    case "failed":
      return OverlayActionCallout(
        label: "Error",
        text: event.summary ?? "The operator hit an error."
      )
    case "tool_started":
      if let summary = event.summary, summary.localizedCaseInsensitiveContains("shell") {
        return OverlayActionCallout(label: "Workbench", text: summary)
      }
      if let summary = event.summary, summary.localizedCaseInsensitiveContains("editing files") {
        return OverlayActionCallout(label: "Workbench", text: summary)
      }
      return OverlayActionCallout(
        label: "Action",
        text: event.summary ?? "Taking action."
      )
    default:
      return OverlayActionCallout(label: "Action", text: "Preparing the operator.")
    }
  }

  private func latestOverlayActionEvent(for taskId: String) -> BackendEvent? {
    if let concreteAction = events.first(where: { event in
      event.taskId == taskId && isConcreteOverlayActionEvent(event)
    }) {
      return concreteAction
    }

    return events.first(where: { event in
      event.taskId == taskId && shouldSurfaceInOverlayActionCallout(event)
    })
  }

  private func shouldSurfaceInOverlayActionCallout(_ event: BackendEvent) -> Bool {
    switch event.type {
    case "started", "delegated", "tool_started", "screenshot", "failed":
      return true
    default:
      return false
    }
  }

  private func isConcreteOverlayActionEvent(_ event: BackendEvent) -> Bool {
    switch event.type {
    case "screenshot":
      return true
    case "tool_started":
      guard let summary = event.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
            !summary.isEmpty else {
        return false
      }
      return !summary.hasPrefix("Calling ")
    default:
      return false
    }
  }

  private func applyRecentBackendEvents(_ recentEvents: [BackendEvent]) {
    let newEvents = recentEvents
      .reversed()
      .filter { event in
        !seenBackendEventIDs.contains(event.id)
      }

    guard !newEvents.isEmpty else {
      return
    }

    for event in newEvents {
      seenBackendEventIDs.insert(event.id)
      logNativeOverlay("Polled backend event \(event.type) for \(event.taskId): \(event.summary ?? "-")")
      handle(event: event)
    }
  }

  private func logNativeOverlay(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let data = Data(line.utf8)
    if FileManager.default.fileExists(atPath: nativeLogURL.path) {
      if let handle = try? FileHandle(forWritingTo: nativeLogURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        return
      }
    }
    try? data.write(to: nativeLogURL, options: .atomic)
  }

  private func syncPhase() {
    if pendingRealtimeApproval != nil || pendingApproval != nil {
      phase = "approvals"
      return
    }

    if !errorMessage.isEmpty {
      phase = "error"
      return
    }

    if !voiceRuntimeErrorMessage.isEmpty && (!voiceState.connected || voiceState.phase == "error") {
      phase = "error"
      return
    }

    if listeningModeActive && !voiceState.connected {
      phase = "listening"
      return
    }

    if voiceState.phase == "connecting" {
      phase = listeningModeActive ? "listening" : "connecting"
      return
    }

    guard voiceState.connected else {
      if activeTaskId != nil {
        phase = "acting"
        return
      }
      phase = "idle"
      return
    }

    switch voiceState.phase {
    case "connecting":
      phase = listeningModeActive ? "listening" : "connecting"
    case "thinking":
      phase = "thinking"
    case "speaking":
      phase = "speaking"
    case "acting":
      phase = "acting"
    case "error":
      phase = "error"
    case "listening":
      phase = !voiceState.muted ? "listening" : "idle"
    default:
      phase = activeTaskId != nil ? "acting" : "idle"
    }
  }
}
