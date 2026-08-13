import AppKit
import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var model: AppModel
  @State private var searchText = ""
  @State private var derivedDataSearchText = ""
  @State private var searchIsExpanded = false
  @State private var managementSheet: SimulatorManagementSheet?
  @State private var slimmingMode: SlimmingMode = .memory

  private var filteredDevices: [SimulatorDevice] {
    guard !searchText.isEmpty else { return model.devices }
    return model.devices.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
        || $0.udid.localizedCaseInsensitiveContains(searchText)
        || $0.osVersion.localizedCaseInsensitiveContains(searchText)
    }
  }

  private var filteredUDIDs: Set<String> {
    Set(filteredDevices.map(\.udid))
  }

  private var filteredDerivedDataEntries: [DerivedDataEntry] {
    let query = derivedDataSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return model.derivedDataEntries }
    return model.derivedDataEntries.filter {
      $0.metadataSearchText.localizedCaseInsensitiveContains(query)
    }
  }

  private var filteredDerivedDataIDs: Set<String> {
    Set(filteredDerivedDataEntries.map(\.id))
  }

  private var activeSearchText: Binding<String> {
    slimmingMode == .derivedData ? $derivedDataSearchText : $searchText
  }

  private var singleSelectedDevice: SimulatorDevice? {
    let selected = model.selectedDevices
    return selected.count == 1 ? selected[0] : nil
  }

  private var selectedCleanableDiskCategories: [DiskCleanupCategory] {
    model.diskCleanupCategories.filter {
      $0.canClean && model.selectedDiskCleanupCategoryIDs.contains($0.id)
    }
  }

  private var automaticAnalysisID: String {
    switch slimmingMode {
    case .memory:
      return "memory"
    case .disk:
      return "disk:" + model.selectedUDIDs.sorted().joined(separator: ",")
    case .derivedData:
      return "derived-data"
    }
  }

  var body: some View {
    NavigationSplitView {
      ProfileSidebar(mode: $slimmingMode)
        .navigationSplitViewColumnWidth(min: 340, ideal: 390, max: 460)
    } detail: {
      VStack(spacing: 0) {
        header
        Divider()
        selectionBar
        Divider()
        detailTable
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .layoutPriority(1)
        Divider()
        ActivityPanel(mode: slimmingMode)
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .toolbar {
      if slimmingMode == .derivedData {
        ToolbarItem(placement: .automatic) {
          Button(role: .destructive) {
            managementSheet = .derivedDataCleanup(model.selectedDerivedDataEntries)
          } label: {
            ToolbarActionLabel("Delete Data", systemImage: "trash")
          }
          .disabled(!model.canCleanDerivedDataSelection || model.isBusy)
          .help("Permanently delete the selected generated directories")
        }

        ToolbarItem(placement: .automatic) {
          Button {
            openDerivedDataRootInFinder()
          } label: {
            ToolbarActionLabel("Show in Finder", systemImage: "folder")
          }
          .disabled(model.derivedDataScan == nil)
          .help("Show Xcode Derived Data in Finder")
        }
      } else {
        if slimmingMode == .memory {
          ToolbarItem(placement: .automatic) {
            Button {
              managementSheet = .slimmingRecommendation(model.selectedDevices)
            } label: {
              ToolbarActionLabel("Slim", systemImage: "minus.circle")
            }
            .disabled(model.selectionCount == 0 || model.isBusy)
            .help("Apply the selected service profile")
          }

          ToolbarItem(placement: .automatic) {
            Button {
              Task { await model.restoreSelection() }
            } label: {
              ToolbarActionLabel("Unslim", systemImage: "plus.circle")
            }
            .disabled(model.selectionCount == 0 || model.isBusy)
            .help("Restore all SimSlim-managed services")
          }
        } else {
          ToolbarItem(placement: .automatic) {
            Button(role: .destructive) {
              managementSheet = .diskCleanup(
                model.selectedDevices,
                selectedCleanableDiskCategories
              )
            } label: {
              ToolbarActionLabel("Clean Disk", systemImage: "externaldrive.badge.xmark")
            }
            .disabled(!model.canCleanDiskSelection || model.isBusy)
            .help("Permanently clean the selected disk categories")
          }
        }

        if #available(macOS 26.0, *) {
          ToolbarSpacer(.flexible)
        }

        ToolbarItemGroup(placement: .automatic) {
          Button {
            guard let device = singleSelectedDevice else { return }
            managementSheet = .clone(device)
          } label: {
            ToolbarActionLabel("Clone", systemImage: "plus.square.on.square")
          }
          .disabled(singleSelectedDevice == nil || model.isBusy)
          .help("Clone for backup or general-purpose use")

          Button(role: .destructive) {
            managementSheet = .erase(model.selectedDevices)
          } label: {
            ToolbarActionLabel("Erase", systemImage: "eraser")
          }
          .disabled(model.selectionCount == 0 || model.isBusy)
          .help("Erase Simulator")

          Button(role: .destructive) {
            managementSheet = .delete(model.selectedDevices)
          } label: {
            ToolbarActionLabel("Delete", systemImage: "trash")
          }
          .disabled(model.selectionCount == 0 || model.isBusy)
          .help("Delete Simulator")
        }

        if #available(macOS 26.0, *) {
          ToolbarSpacer(.flexible)
        }

        ToolbarItemGroup(placement: .automatic) {
          Button {
            guard let device = singleSelectedDevice else { return }
            Task { await model.bootSimulator(device) }
          } label: {
            ToolbarActionLabel("Boot", systemImage: "play.fill")
          }
          .disabled(
            singleSelectedDevice == nil || singleSelectedDevice?.isBooted == true || model.isBusy
          )
          .help("Boot Simulator")

          Button {
            guard let device = singleSelectedDevice else { return }
            Task { await model.shutdownSimulator(device) }
          } label: {
            ToolbarActionLabel("Kill", systemImage: "stop.fill")
          }
          .disabled(
            singleSelectedDevice == nil || singleSelectedDevice?.isBooted == false || model.isBusy
          )
          .help("Shut Down Simulator")

          Button {
            guard let device = singleSelectedDevice else { return }
            managementSheet = .rename(device)
          } label: {
            ToolbarActionLabel("Rename", systemImage: "pencil")
          }
          .disabled(singleSelectedDevice == nil || model.isBusy)
          .help("Rename Simulator")
        }

        if #available(macOS 26.0, *) {
          ToolbarSpacer(.flexible)
        }
      }

      ToolbarItemGroup(placement: .automatic) {
        Button {
          Task {
            if slimmingMode == .derivedData {
              await model.scanDerivedData()
            } else {
              await model.refresh()
            }
          }
        } label: {
          ToolbarActionLabel("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(model.isBusy)
        .help(
          slimmingMode == .derivedData
            ? "Re-scan Xcode Derived Data" : "Refresh simulator status")

        Menu {
          if slimmingMode == .derivedData {
            Button("Select Visible") { model.selectDerivedData(filteredDerivedDataIDs) }
              .disabled(filteredDerivedDataEntries.isEmpty)
            Button("Select 1 GB or Larger") {
              model.selectDerivedData(
                Set(model.derivedDataEntries.filter { $0.bytes >= 1_000_000_000 }.map(\.id))
              )
            }
            .disabled(!model.derivedDataEntries.contains { $0.bytes >= 1_000_000_000 })
            Divider()
            Button("Clear Selection") { model.selectDerivedData([]) }
              .disabled(model.selectedDerivedDataIDs.isEmpty)
          } else {
            Button("Select Visible") { model.select(filteredUDIDs) }
              .disabled(filteredDevices.isEmpty)
            Button("Clear Selection") { model.clearSelection() }
              .disabled(model.selectionCount == 0)
          }
        } label: {
          ToolbarActionLabel("Selection", systemImage: "checklist")
        }
        .disabled(model.isBusy)
      }

      if #available(macOS 26.0, *) {
        ToolbarSpacer(.flexible)
      }

      ToolbarItem(placement: .automatic) {
        CollapsibleToolbarSearch(
          text: activeSearchText,
          prompt: slimmingMode == .derivedData ? "Find Derived Data" : "Find a simulator",
          isExpanded: $searchIsExpanded
        )
      }
    }
    .sheet(item: $managementSheet) { sheet in
      managementSheetContent(for: sheet)
    }
    .alert(item: $model.presentedError) { error in
      Alert(
        title: Text("SimSlim couldn’t finish"),
        message: Text(error.message),
        dismissButton: .default(Text("OK"))
      )
    }
    .task(id: automaticAnalysisID) {
      switch slimmingMode {
      case .memory:
        break
      case .disk:
        guard model.selectionCount > 0 else { return }
        await model.analyzeDiskSelectionIfNeeded()
      case .derivedData:
        await model.scanDerivedDataIfNeeded()
      }
    }
  }

  @ViewBuilder
  private var header: some View {
    if slimmingMode == .derivedData {
      derivedDataHeader
    } else {
      simulatorHeader
    }
  }

  private var simulatorHeader: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Installed Simulators")
          .font(.system(size: 27, weight: .bold, design: .rounded))
        Text(lastUpdatedText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()

      MetricPill(value: "\(model.devices.count)", label: "Installed", color: .blue)
      MetricPill(value: "\(model.bootedCount)", label: "Booted", color: .orange)
      MetricPill(value: "\(model.selectionCount)", label: "Selected", color: .purple)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 15)
  }

  private var derivedDataHeader: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Xcode Derived Data")
          .font(.system(size: 27, weight: .bold, design: .rounded))
        Text(derivedDataLastScannedText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()

      MetricPill(
        value: model.derivedDataScan?.totalSizeText ?? "—",
        label: "Generated",
        color: .orange
      )
      MetricPill(value: "\(model.derivedDataEntries.count)", label: "Folders", color: .blue)
      MetricPill(
        value: model.selectedDerivedDataSizeText(),
        label: "Selected",
        color: .purple
      )
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 15)
  }

  @ViewBuilder
  private var selectionBar: some View {
    if slimmingMode == .derivedData {
      derivedDataSelectionBar
    } else {
      simulatorSelectionBar
    }
  }

  private var simulatorSelectionBar: some View {
    VStack(spacing: 10) {
      HStack(spacing: 12) {
        Button {
          if !filteredDevices.isEmpty && filteredUDIDs.isSubset(of: model.selectedUDIDs) {
            model.select(model.selectedUDIDs.subtracting(filteredUDIDs))
          } else {
            model.select(model.selectedUDIDs.union(filteredUDIDs))
          }
        } label: {
          Image(systemName: selectionAllImage)
            .font(.title3)
            .foregroundStyle(filteredDevices.isEmpty ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(filteredDevices.isEmpty || model.isBusy)
        .help("Select or deselect all visible simulators")

        if model.selectionCount == 0 {
          Text(
            slimmingMode == .memory
              ? "Select simulators to change their service profile"
              : "Select simulators to review reclaimable disk data"
          )
          .foregroundStyle(.secondary)
        } else {
          Text("\(model.selectionCount) selected")
            .fontWeight(.semibold)
          if slimmingMode == .memory {
            Text("· profile will disable \(model.disabledDaemonCount) services")
              .foregroundStyle(.secondary)
          } else if model.isAnalyzingDisk {
            Text("· analyzing disk usage…")
              .foregroundStyle(.secondary)
          } else if model.diskAnalysisCoversSelection {
            Text("· \(model.selectedDiskCleanupSizeText()) selected for cleanup")
              .foregroundStyle(.orange)
          } else {
            Text("· disk analysis pending")
              .foregroundStyle(.secondary)
          }
        }

        Spacer()
      }
      .controlSize(.regular)

      if let progress = model.batchProgress {
        VStack(spacing: 5) {
          ProgressView(value: progress.fraction)
            .progressViewStyle(.linear)
          HStack {
            Text("\(progress.action) \(progress.currentName)…")
            Spacer()
            Text("\(progress.completed) of \(progress.total)")
              .monospacedDigit()
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 11)
    .background(.bar)
    .animation(.easeInOut(duration: 0.2), value: model.batchProgress)
  }

  private var derivedDataSelectionBar: some View {
    HStack(spacing: 12) {
      Button {
        if !filteredDerivedDataEntries.isEmpty
          && filteredDerivedDataIDs.isSubset(of: model.selectedDerivedDataIDs)
        {
          model.selectDerivedData(
            model.selectedDerivedDataIDs.subtracting(filteredDerivedDataIDs)
          )
        } else {
          model.selectDerivedData(
            model.selectedDerivedDataIDs.union(filteredDerivedDataIDs)
          )
        }
      } label: {
        Image(systemName: derivedDataSelectionAllImage)
          .font(.title3)
          .foregroundStyle(
            filteredDerivedDataEntries.isEmpty ? Color.secondary : Color.accentColor)
      }
      .buttonStyle(.plain)
      .disabled(filteredDerivedDataEntries.isEmpty || model.isBusy)
      .help("Select or deselect all visible Derived Data directories")

      if model.isScanningDerivedData {
        ProgressView()
          .controlSize(.small)
        Text("Scanning folder sizes…")
          .foregroundStyle(.secondary)
      } else if model.isCleaningDerivedData {
        ProgressView()
          .controlSize(.small)
        Text("Deleting selected generated data…")
          .foregroundStyle(.secondary)
      } else if model.selectedDerivedDataIDs.isEmpty {
        Text("Select folders to reclaim their disk space")
          .foregroundStyle(.secondary)
      } else {
        Text("\(model.selectedDerivedDataIDs.count) selected")
          .fontWeight(.semibold)
        Text("· \(model.selectedDerivedDataSizeText()) will be reclaimed")
          .foregroundStyle(.orange)
      }

      Spacer()
    }
    .controlSize(.regular)
    .padding(.horizontal, 18)
    .padding(.vertical, 11)
    .background(.bar)
  }

  @ViewBuilder
  private var detailTable: some View {
    if slimmingMode == .derivedData {
      derivedDataTable
    } else {
      simulatorTable
    }
  }

  private var derivedDataTable: some View {
    VStack(spacing: 0) {
      derivedDataTableHeader
      Divider()

      GeometryReader { geometry in
        Group {
          if model.isScanningDerivedData && model.derivedDataScan == nil {
            VStack(spacing: 12) {
              ProgressView()
              Text("Scanning Xcode Derived Data…")
                .foregroundStyle(.secondary)
              Text("Large build and module caches can take a moment to measure.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
          } else if model.derivedDataScan == nil {
            VStack(spacing: 12) {
              Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
              Text("Derived Data hasn’t been scanned")
                .font(.title3.weight(.semibold))
              Button("Scan Now") {
                Task { await model.scanDerivedData() }
              }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
          } else if filteredDerivedDataEntries.isEmpty {
            ContentUnavailableView(
              derivedDataSearchText.isEmpty ? "No Derived Data" : "No Matches",
              systemImage: derivedDataSearchText.isEmpty ? "checkmark.circle" : "magnifyingglass",
              description: Text(
                derivedDataSearchText.isEmpty
                  ? "Xcode has no generated project or cache directories to clean."
                  : "Try a different project, directory, or cache name.")
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
          } else {
            ScrollView {
              LazyVStack(spacing: 0) {
                ForEach(filteredDerivedDataEntries) { entry in
                  DerivedDataRow(entry: entry)
                  Divider().padding(.leading, 48)
                }
              }
              .frame(width: geometry.size.width, alignment: .top)
            }
          }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private var derivedDataTableHeader: some View {
    HStack(spacing: 12) {
      Color.clear.frame(width: 24, height: 1)
      Text("PROJECT / SOURCE")
        .frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
      Text("APP / BUILD METADATA").frame(width: 340, alignment: .leading)
      Text("DISK SIZE").frame(width: 105, alignment: .trailing)
      Color.clear.frame(width: 28, height: 1)
    }
    .font(.system(size: 10, weight: .semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 18)
    .padding(.vertical, 8)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
  }

  private var simulatorTable: some View {
    VStack(spacing: 0) {
      tableHeader
      Divider()

      GeometryReader { geometry in
        Group {
          if model.isRefreshing && model.devices.isEmpty {
            VStack(spacing: 12) {
              ProgressView()
              Text("Loading simulators…")
                .foregroundStyle(.secondary)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
          } else if filteredDevices.isEmpty {
            ContentUnavailableView(
              searchText.isEmpty ? "No iOS Simulators" : "No Matches",
              systemImage: "iphone.slash",
              description: Text(
                searchText.isEmpty
                  ? "Install an iOS Simulator runtime in Xcode."
                  : "Try a different name, UDID, or iOS version.")
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
          } else {
            ScrollView {
              LazyVStack(spacing: 0) {
                ForEach(filteredDevices) { device in
                  SimulatorRow(
                    device: device,
                    diskCleanupCategories: selectedCleanableDiskCategories,
                    managementSheet: $managementSheet
                  )
                  Divider().padding(.leading, 48)
                }
              }
              .frame(width: geometry.size.width, alignment: .top)
            }
          }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private var tableHeader: some View {
    HStack(spacing: 12) {
      Color.clear.frame(width: 24, height: 1)
      Text("SIMULATOR")
        .frame(minWidth: 255, maxWidth: .infinity, alignment: .leading)
      Text("RUNTIME").frame(width: 74, alignment: .leading)
      Text("BOOT").frame(width: 86, alignment: .leading)
      Text("SERVICES").frame(width: 150, alignment: .leading)
      Text("DISK SIZE").frame(width: 105, alignment: .leading)
      Text("RAM USAGE").frame(width: 82, alignment: .leading)
      Color.clear.frame(width: 28, height: 1)
    }
    .font(.system(size: 10, weight: .semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 18)
    .padding(.vertical, 8)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
  }

  private var selectionAllImage: String {
    if !filteredDevices.isEmpty && filteredUDIDs.isSubset(of: model.selectedUDIDs) {
      return "checkmark.square.fill"
    }
    if !filteredUDIDs.intersection(model.selectedUDIDs).isEmpty {
      return "minus.square.fill"
    }
    return "square"
  }

  private var derivedDataSelectionAllImage: String {
    if !filteredDerivedDataEntries.isEmpty
      && filteredDerivedDataIDs.isSubset(of: model.selectedDerivedDataIDs)
    {
      return "checkmark.square.fill"
    }
    if !filteredDerivedDataIDs.intersection(model.selectedDerivedDataIDs).isEmpty {
      return "minus.square.fill"
    }
    return "square"
  }

  private var lastUpdatedText: String {
    guard let date = model.lastUpdated else { return "Loading simulator status…" }
    return "Updated \(date.formatted(date: .omitted, time: .shortened))"
  }

  private var derivedDataLastScannedText: String {
    guard let date = model.derivedDataLastScanned else {
      return model.isScanningDerivedData ? "Scanning folder sizes…" : "Waiting to scan…"
    }
    return "Scanned \(date.formatted(date: .omitted, time: .shortened))"
  }

  @ViewBuilder
  private func managementSheetContent(for sheet: SimulatorManagementSheet) -> some View {
    switch sheet {
    case .clone(let device):
      SimulatorNameSheet(
        title: "Clone Simulator",
        actionTitle: "Clone Simulator",
        systemImage: "plus.square.on.square",
        explanation:
          "The clone keeps the source simulator’s apps, data, and settings. It does not keep the service profile: a clone starts stock and has to be slimmed again. Use it as a point-in-time backup before slimming or as an independent simulator for general development and testing. A booted source is briefly shut down and then returned to its original boot state.",
        initialName: "\(device.name) Copy",
        device: device
      ) { name in
        Task { await model.cloneSimulator(device, named: name) }
      }

    case .slimmingRecommendation(let devices):
      SlimmingRecommendationSheet(devices: devices) { device in
        presentAfterSheetDismissal(.clone(device))
      } onContinue: {
        Task { await model.applyProfile(to: devices) }
      }

    case .rename(let device):
      SimulatorNameSheet(
        title: "Rename Simulator",
        actionTitle: "Rename Simulator",
        systemImage: "pencil",
        explanation:
          "Renaming changes only the simulator’s display name. Its apps, data, runtime, and service profile stay the same.",
        initialName: device.name,
        device: device
      ) { name in
        Task { await model.renameSimulator(device, to: name) }
      }

    case .erase(let devices):
      SimulatorDestructiveSheet(action: .erase, devices: devices) {
        Task { await model.eraseSimulators(devices) }
      }

    case .delete(let devices):
      SimulatorDestructiveSheet(action: .delete, devices: devices) {
        Task { await model.deleteSimulators(devices) }
      }

    case .diskCleanup(let devices, let categories):
      DiskCleanupConfirmationSheet(devices: devices, categories: categories) { device in
        presentAfterSheetDismissal(.clone(device))
      } onConfirm: { categoryIDs in
        Task { await model.cleanDisk(devices, categoryIDs: categoryIDs) }
      }

    case .derivedDataCleanup(let entries):
      DerivedDataCleanupConfirmationSheet(entries: entries) {
        Task { await model.cleanDerivedData(entries) }
      }
    }
  }

  private func presentAfterSheetDismissal(_ sheet: SimulatorManagementSheet) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      managementSheet = sheet
    }
  }

  private func openDerivedDataRootInFinder() {
    guard let rootPath = model.derivedDataScan?.rootPath else { return }
    let url = URL(fileURLWithPath: rootPath, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      model.presentedError = PresentedError(
        message: "The Xcode Derived Data directory does not exist at \(url.path)."
      )
      return
    }
    guard NSWorkspace.shared.open(url) else {
      model.presentedError = PresentedError(message: "Finder could not open \(url.path).")
      return
    }
  }
}

private struct ToolbarActionLabel: View {
  let title: String
  let systemImage: String

  init(_ title: String, systemImage: String) {
    self.title = title
    self.systemImage = systemImage
  }

  var body: some View {
    Label(title, systemImage: systemImage)
      .accessibilityLabel(title)
  }
}

private struct CollapsibleToolbarSearch: View {
  @Binding var text: String
  let prompt: String
  @Binding var isExpanded: Bool

  @ViewBuilder
  var body: some View {
    if isExpanded {
      if #available(macOS 26.0, *) {
        searchContent
          .padding(.horizontal, 10)
          .frame(width: 300, height: 32)
      } else {
        searchContent
          .padding(.horizontal, 10)
          .frame(width: 280, height: 30)
          .background(.regularMaterial, in: Capsule())
      }
    } else {
      Button {
        withAnimation(.easeInOut(duration: 0.16)) {
          isExpanded = true
        }
      } label: {
        ToolbarActionLabel(
          "Search",
          systemImage: text.isEmpty ? "magnifyingglass" : "magnifyingglass.circle.fill"
        )
      }
      .help(text.isEmpty ? prompt : "\(prompt) — filter active")
      .accessibilityLabel(text.isEmpty ? prompt : "\(prompt), filter active")
    }
  }

  private var searchContent: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      AutofocusingToolbarTextField(
        text: $text,
        prompt: prompt,
        onSubmit: {
          if text.isEmpty {
            collapse()
          }
        },
        onCancel: collapse
      )
      .frame(maxWidth: .infinity)

      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear search")
      }

      Button {
        collapse()
      } label: {
        Image(systemName: "chevron.right")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Collapse search")
      .accessibilityLabel("Collapse search")
    }
    .onExitCommand(perform: collapse)
  }

  private func collapse() {
    withAnimation(.easeInOut(duration: 0.16)) {
      isExpanded = false
    }
  }
}

private struct AutofocusingToolbarTextField: NSViewRepresentable {
  @Binding var text: String
  let prompt: String
  let onSubmit: () -> Void
  let onCancel: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> AutofocusingTextField {
    let textField = AutofocusingTextField()
    textField.delegate = context.coordinator
    textField.stringValue = text
    textField.placeholderString = prompt
    textField.isBezeled = false
    textField.drawsBackground = false
    textField.focusRingType = .none
    textField.usesSingleLineMode = true
    textField.lineBreakMode = .byTruncatingTail
    textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    textField.setAccessibilityLabel(prompt)
    return textField
  }

  func updateNSView(_ textField: AutofocusingTextField, context: Context) {
    context.coordinator.parent = self
    if textField.stringValue != text {
      textField.stringValue = text
    }
    textField.placeholderString = prompt
    textField.setAccessibilityLabel(prompt)
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: AutofocusingToolbarTextField

    init(parent: AutofocusingToolbarTextField) {
      self.parent = parent
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let textField = notification.object as? NSTextField else { return }
      if parent.text != textField.stringValue {
        parent.text = textField.stringValue
      }
    }

    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        parent.onSubmit()
        return true
      }
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        parent.onCancel()
        return true
      }
      return false
    }
  }
}

private final class AutofocusingTextField: NSTextField {
  private var hasRequestedFocus = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, !hasRequestedFocus else { return }
    hasRequestedFocus = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.window?.makeFirstResponder(self)
    }
  }
}

private struct MetricPill: View {
  let value: String
  let label: String
  let color: Color

  var body: some View {
    HStack(spacing: 7) {
      Text(value)
        .font(.system(.title3, design: .rounded, weight: .bold))
        .foregroundStyle(color)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(color.opacity(0.1), in: Capsule())
  }
}

private struct ProfileSidebar: View {
  @EnvironmentObject private var model: AppModel
  @Binding var mode: SlimmingMode
  @State private var serviceSearchText = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(width: 46, height: 46)
        VStack(alignment: .leading, spacing: 2) {
          Text("SimSlim")
            .font(.title2.bold())
          Text(modeSubtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(18)

      Picker("Slimming mode", selection: $mode) {
        ForEach(SlimmingMode.allCases) { option in
          Text(option.rawValue).tag(option)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 16)
      .padding(.bottom, 14)

      Divider()

      ScrollView {
        Group {
          switch mode {
          case .memory:
            memoryContent
          case .disk:
            diskContent
          case .derivedData:
            derivedDataContent
          }
        }
        .padding(16)
      }
    }
    .background(.regularMaterial)
  }

  private var modeSubtitle: String {
    switch mode {
    case .memory: return "Service slimming · reversible"
    case .disk: return "Simulator disk cleanup"
    case .derivedData: return "Xcode build storage"
    }
  }

  private var sortedMemoryCategories: [SlimCategory] {
    model.categories.sorted {
      if $0.approxMemoryMB == $1.approxMemoryMB {
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      return $0.approxMemoryMB > $1.approxMemoryMB
    }
  }

  private var filteredMemoryCategories: [SlimCategory] {
    let query = serviceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return sortedMemoryCategories }
    return sortedMemoryCategories.filter { category in
      category.name.localizedCaseInsensitiveContains(query)
        || category.description.localizedCaseInsensitiveContains(query)
        || category.downside.localizedCaseInsensitiveContains(query)
        || category.labels.contains {
          $0.localizedCaseInsensitiveContains(query)
        }
        || category.labels.contains {
          category.serviceDescription(for: $0).localizedCaseInsensitiveContains(query)
        }
        || category.alwaysEnabledServices.contains {
          $0.label.localizedCaseInsensitiveContains(query)
            || $0.reason.localizedCaseInsensitiveContains(query)
        }
    }
  }

  private var sortedDiskCategories: [DiskCleanupCategory] {
    model.diskCleanupCategories.filter(\.canClean).sorted {
      let left = model.diskCleanupBytes(for: $0.id) ?? 0
      let right = model.diskCleanupBytes(for: $1.id) ?? 0
      if left == right {
        if $0.canClean != $1.canClean { return $0.canClean }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      return left > right
    }
  }

  private var memoryContent: some View {
    VStack(alignment: .leading, spacing: 15) {
      stateLegend

      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text("Services to keep")
            .font(.headline)
          Spacer()
          Button("Full Slim") { model.resetProfile() }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(
              (model.keptCategoryIDs.isEmpty && model.keptServiceLabels.isEmpty) || model.isBusy)
        }
        Text(
          "Sorted by estimated idle memory use. Enable categories your tests need; estimates vary and are not additive."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      SidebarServiceSearch(text: $serviceSearchText)

      VStack(alignment: .leading, spacing: 8) {
        ForEach(filteredMemoryCategories) { category in
          CategoryToggle(
            category: category,
            serviceQuery: serviceSearchText
          )
        }

        if !serviceSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && filteredMemoryCategories.isEmpty
        {
          Text("No services match \u{201c}\(serviceSearchText)\u{201d}")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 72)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Toggle("Preserve current boot state", isOn: $model.preserveBootState)
        .font(.subheadline.weight(.medium))
        .disabled(model.isBusy)
      Text(
        "A simulator that starts shutdown will return to shutdown after its service profile is changed."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 7) {
        Label("\(model.disabledDaemonCount) services will be disabled", systemImage: "circle")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.green)
        Text("Core workflow and deadlock-prone daemons are never disabled.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
  }

  private var diskContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text("Cleanup")
            .font(.headline)
          Spacer()
          Text(model.selectedDiskCleanupSizeText())
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(model.diskAnalysisCoversSelection ? Color.orange : Color.secondary)
        }
        Text("Updates automatically when your selection changes. Analysis is read-only.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Button {
          Task { await model.analyzeDiskSelection() }
        } label: {
          Label("Re-analyze Selected", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(model.selectionCount == 0 || model.isBusy)
        .help("Refresh disk usage for the selected simulators")
      }

      VStack(alignment: .leading, spacing: 8) {
        ForEach(sortedDiskCategories) { category in
          DiskCleanupCategoryToggle(category: category)
        }
      }

      if model.diskAnalysisCoversSelection {
        VStack(alignment: .leading, spacing: 8) {
          Text("Storage breakdown")
            .font(.headline)
          Text("Read-only sizes. These files are never selected for cleanup.")
            .font(.caption)
            .foregroundStyle(.secondary)

          ForEach(model.diskStorageRows) { storage in
            DiskStorageRow(
              storage: storage,
              sizeText: model.diskStorageSizeText(for: storage.id)
            )
          }
        }
      }

      Toggle("Reopen previously booted simulators", isOn: $model.preserveBootState)
        .font(.subheadline.weight(.medium))
        .disabled(model.isBusy)

      VStack(alignment: .leading, spacing: 7) {
        Text(
          "Required Siri assets aren’t offered for deletion — iOS restores them automatically on launch."
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.blue)
        Text("Built-in apps and core OS resources are never modified.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var derivedDataContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text("Generated by Xcode")
            .font(.headline)
          Spacer()
          Text(model.derivedDataScan?.totalSizeText ?? "Pending")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(model.derivedDataScan == nil ? Color.secondary : Color.orange)
        }
        Text(
          "Project build products, indexes, module caches, and package working data. The largest folders are shown first."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Button {
          Task { await model.scanDerivedData() }
        } label: {
          Label("Re-scan Derived Data", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(model.isBusy)
      }

      VStack(alignment: .leading, spacing: 8) {
        Label("Select individual folders", systemImage: "checklist")
          .font(.subheadline.weight(.semibold))
        Text(
          "Use the main table to keep active projects and remove stale copies or oversized shared caches."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if let largest = model.derivedDataEntries.first {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("Largest")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(largest.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            }
            Spacer()
            Text(largest.sizeText)
              .font(.caption.monospacedDigit().weight(.semibold))
              .foregroundStyle(.orange)
          }
          .padding(10)
          .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9)
          )
        }
      }

      VStack(alignment: .leading, spacing: 7) {
        Label("Regenerated automatically", systemImage: "arrow.triangle.2.circlepath")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.blue)
        Text(
          "Deleting Derived Data does not delete source code. Xcode rebuilds what it needs, so the next build and index may take longer."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 5) {
        Label("Cleanup boundary", systemImage: "checkmark.shield")
          .font(.subheadline.weight(.semibold))
        Text(
          "Only selected direct children of DerivedData can be deleted. Archives, DeviceSupport, simulators, and project source folders are never scanned or touched."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var stateLegend: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Service state")
        .font(.headline)
      HStack(spacing: 13) {
        LegendItem(icon: "circle.fill", label: "Stock")
        LegendItem(icon: "circle.lefthalf.filled", label: "Partial")
        LegendItem(icon: "circle", label: "Slim")
      }
      .foregroundStyle(.secondary)
    }
  }
}

private struct SidebarServiceSearch: View {
  @Binding var text: String

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Find a service", text: $text)
        .textFieldStyle(.plain)
        .accessibilityLabel("Find a service")

      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear service search")
      }
    }
    .padding(.horizontal, 9)
    .frame(height: 29)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
    }
  }
}

private struct DiskCleanupCategoryToggle: View {
  @EnvironmentObject private var model: AppModel
  let category: DiskCleanupCategory

  private var isSelected: Binding<Bool> {
    Binding(
      get: { model.selectedDiskCleanupCategoryIDs.contains(category.id) },
      set: { model.setDiskCleanupCategory(category, selected: $0) }
    )
  }

  private var accentColor: Color {
    category.id == "linguistic-data" ? .blue : .orange
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        VStack(alignment: .leading, spacing: 4) {
          Text(category.name)
            .font(.subheadline.weight(.medium))
          if category.risk != "Lower risk" {
            Text(category.risk.uppercased())
              .font(.system(size: 8, weight: .bold))
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
              .foregroundStyle(accentColor)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(accentColor.opacity(0.1), in: Capsule())
          }
        }

        Label(model.diskCleanupSizeText(for: category.id), systemImage: "internaldrive")
          .font(.caption.weight(.semibold))
          .foregroundStyle(accentColor)

        (Text("Impact: ").fontWeight(.semibold) + Text(category.downside))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        (Text("Afterward: ").fontWeight(.semibold) + Text(category.recovery))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if !category.canClean {
          Text("Unable to delete — iOS restores automatically on launch.")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if category.canClean {
        Toggle("Remove \(category.name)", isOn: isSelected)
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(model.isBusy)
          .padding(.top, 1)
      } else {
        Image(systemName: "lock.fill")
          .foregroundStyle(.secondary)
          .frame(width: 38, height: 24)
          .accessibilityLabel("Deletion unavailable")
          .padding(.top, 1)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    .help(category.recovery)
  }
}

private struct DiskStorageRow: View {
  let storage: SimulatorDiskStorageMeasurement
  let sizeText: String

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: storage.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 17)

      VStack(alignment: .leading, spacing: 2) {
        Text(storage.name)
          .font(.subheadline.weight(.medium))
        Text(storage.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      Text(sizeText)
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(.secondary)
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
  }
}

private struct LegendItem: View {
  let icon: String
  let label: String

  var body: some View {
    Label(label, systemImage: icon)
      .font(.caption)
  }
}

private struct CategoryToggle: View {
  @EnvironmentObject private var model: AppModel
  let category: SlimCategory
  let serviceQuery: String
  @State private var isExpanded = false

  private var isKeptEnabled: Binding<Bool> {
    Binding(
      get: { model.categoryIsKept(category) },
      set: { model.setCategory(category, keptEnabled: $0) }
    )
  }

  private var showsServices: Bool {
    isExpanded || !normalizedQuery.isEmpty
  }

  private var serviceCount: Int {
    category.labels.count + category.alwaysEnabledServices.count
  }

  private var normalizedQuery: String {
    serviceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var categoryMetadataMatchesQuery: Bool {
    guard !normalizedQuery.isEmpty else { return false }
    return category.name.localizedCaseInsensitiveContains(normalizedQuery)
      || category.description.localizedCaseInsensitiveContains(normalizedQuery)
      || category.downside.localizedCaseInsensitiveContains(normalizedQuery)
  }

  private var visibleLabels: [String] {
    guard !normalizedQuery.isEmpty, !categoryMetadataMatchesQuery else { return category.labels }
    return category.labels.filter {
      $0.localizedCaseInsensitiveContains(normalizedQuery)
        || category.serviceDescription(for: $0).localizedCaseInsensitiveContains(normalizedQuery)
    }
  }

  private var visibleAlwaysEnabledServices: [AlwaysEnabledService] {
    guard !normalizedQuery.isEmpty, !categoryMetadataMatchesQuery else {
      return category.alwaysEnabledServices
    }
    return category.alwaysEnabledServices.filter {
      $0.label.localizedCaseInsensitiveContains(normalizedQuery)
        || $0.reason.localizedCaseInsensitiveContains(normalizedQuery)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Button {
          withAnimation(.easeInOut(duration: 0.16)) {
            isExpanded.toggle()
          }
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: showsServices ? "chevron.down" : "chevron.right")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.secondary)
              .frame(width: 9)

            Text(category.name)
              .font(.subheadline.weight(.medium))
              .fixedSize(horizontal: false, vertical: true)

            Text("\(serviceCount)")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.quaternary, in: Capsule())
          }
        }
        .buttonStyle(.plain)
        .help(showsServices ? "Hide individual services" : "Show individual services")

        Spacer(minLength: 4)

        Toggle("Keep \(category.name) enabled", isOn: isKeptEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(model.isBusy)
          .padding(.top, 1)
          .help("Keep all controllable services in \(category.name) enabled")
      }

      Label(category.approximateMemoryText, systemImage: "memorychip")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.blue)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.blue.opacity(0.1), in: Capsule())
        .help(category.approximateMemoryText)

      (Text("When disabled: ").fontWeight(.semibold) + Text(category.downside))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if showsServices {
        Divider()

        VStack(alignment: .leading, spacing: 6) {
          ForEach(visibleLabels, id: \.self) { label in
            ServiceToggle(label: label, category: category)
          }

          ForEach(visibleAlwaysEnabledServices) { service in
            AlwaysEnabledServiceRow(service: service)
          }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
  }
}

private struct ServiceToggle: View {
  @EnvironmentObject private var model: AppModel
  let label: String
  let category: SlimCategory

  private var isKeptEnabled: Binding<Bool> {
    Binding(
      get: { model.serviceIsKept(label) },
      set: { model.setService(label, in: category, keptEnabled: $0) }
    )
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "gearshape.2")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 15)

      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.caption.monospaced())
          .lineLimit(2)
          .textSelection(.enabled)
        Text(category.serviceDescription(for: label))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: 4)

      Toggle("Keep \(label) enabled", isOn: isKeptEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(model.isBusy)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
  }
}

private struct AlwaysEnabledServiceRow: View {
  let service: AlwaysEnabledService

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "lock.fill")
        .font(.caption)
        .foregroundStyle(.blue)
        .frame(width: 15)

      VStack(alignment: .leading, spacing: 2) {
        Text(service.label)
          .font(.caption.monospaced())
          .lineLimit(2)
          .textSelection(.enabled)
        Text(service.reason)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 4)

      Text("Always on")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.blue)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.blue.opacity(0.1), in: Capsule())
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
  }
}

private struct DerivedDataRow: View {
  @EnvironmentObject private var model: AppModel
  let entry: DerivedDataEntry

  private var isSelected: Bool {
    model.selectedDerivedDataIDs.contains(entry.id)
  }

  var body: some View {
    HStack(spacing: 12) {
      Button {
        model.toggleDerivedDataSelection(entry.id)
      } label: {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
          .font(.title3)
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
      }
      .buttonStyle(.plain)
      .disabled(model.isBusy)
      .frame(width: 24)

      HStack(spacing: 10) {
        Image(systemName: entry.systemImage)
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(entry.kind == "project" ? Color.blue : Color.orange)
          .frame(width: 35, height: 35)
          .background(
            (entry.kind == "project" ? Color.blue : Color.orange).opacity(0.09),
            in: RoundedRectangle(cornerRadius: 9)
          )

        VStack(alignment: .leading, spacing: 2) {
          Text(entry.name)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)

          if let sourcePath = entry.sourceDisplayPath {
            HStack(spacing: 4) {
              if entry.sourceIsMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundStyle(.orange)
              }
              Text(sourcePath)
                .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(entry.sourceIsMissing ? Color.orange : Color.secondary)
            .help(
              entry.sourceIsMissing
                ? "This source workspace no longer exists. The Derived Data may be stale."
                : entry.sourcePath ?? sourcePath)

            Text(entry.directoryName)
              .font(.system(size: 8, design: .monospaced))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .help(entry.path)
          } else {
            Text(entry.directoryName)
              .font(.system(size: 9, design: .monospaced))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .help(entry.path)
          }
        }
      }
      .frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 2) {
        Text(entry.metadataTitle)
          .font(
            entry.bundleIdentifier == nil
              ? .subheadline.weight(.medium)
              : .system(size: 12, weight: .medium, design: .monospaced)
          )
          .foregroundStyle(entry.kind == "project" ? Color.primary : Color.secondary)
          .lineLimit(1)

        if let versionSummary = entry.versionBuildSummary {
          Text(versionSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else if entry.kind == "project" {
          Text("No built app metadata found")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        } else {
          Text("Updated \(entry.modifiedDate.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }

        if let buildContext = entry.buildContextSummary {
          HStack(spacing: 5) {
            Text(buildContext)
            if let buildDate = entry.latestBuildDate {
              Text("·")
              Text(buildDate.formatted(date: .abbreviated, time: .shortened))
            }
          }
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .help(entry.productPath ?? "")
        }
      }
      .frame(width: 340, alignment: .leading)

      Text(entry.sizeText)
        .font(.subheadline.monospacedDigit().weight(.semibold))
        .foregroundStyle(.orange)
        .frame(width: 105, alignment: .trailing)

      Menu {
        Button {
          revealInFinder()
        } label: {
          Label("Show Derived Data in Finder", systemImage: "folder")
        }

        if entry.sourceExists == true, entry.sourcePath != nil {
          Button {
            revealSourceInFinder()
          } label: {
            Label("Show Source Workspace in Finder", systemImage: "folder.badge.gearshape")
          }
        }

        if entry.productPath != nil {
          Button {
            revealBuildProductInFinder()
          } label: {
            Label("Show Built App in Finder", systemImage: "app")
          }
        }

        if let bundleIdentifier = entry.bundleIdentifier {
          Divider()
          Button {
            copyToPasteboard(bundleIdentifier)
          } label: {
            Label("Copy Bundle Identifier", systemImage: "doc.on.doc")
          }
        }

        Divider()
        Button(isSelected ? "Deselect" : "Select") {
          model.toggleDerivedDataSelection(entry.id)
        }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 20)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .disabled(model.isBusy)
      .frame(width: 28)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 8)
    .background(isSelected ? Color.accentColor.opacity(0.075) : Color.clear)
    .animation(.easeInOut(duration: 0.16), value: isSelected)
  }

  private func revealInFinder() {
    let url = URL(fileURLWithPath: entry.path, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      model.presentedError = PresentedError(
        message: "\(entry.name) no longer exists at \(entry.path). Re-scan Derived Data."
      )
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func revealSourceInFinder() {
    guard let sourcePath = entry.sourcePath else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: sourcePath)])
  }

  private func revealBuildProductInFinder() {
    guard let productPath = entry.productPath else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: productPath)])
  }

  private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

private struct SimulatorRow: View {
  @EnvironmentObject private var model: AppModel
  let device: SimulatorDevice
  let diskCleanupCategories: [DiskCleanupCategory]
  @Binding var managementSheet: SimulatorManagementSheet?

  private var isSelected: Bool { model.selectedUDIDs.contains(device.udid) }
  private var operation: String? { model.activeOperations[device.udid] }

  var body: some View {
    VStack(spacing: 7) {
      HStack(spacing: 12) {
        Button {
          model.toggleSelection(device.udid)
        } label: {
          Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .frame(width: 24)

        HStack(spacing: 10) {
          Image(systemName: "iphone")
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(device.isBooted ? Color.blue : Color.secondary)
            .frame(width: 35, height: 35)
            .background(
              (device.isBooted ? Color.blue : Color.secondary).opacity(0.09),
              in: RoundedRectangle(cornerRadius: 9))
          VStack(alignment: .leading, spacing: 2) {
            Text(device.name)
              .font(.subheadline.weight(.semibold))
            HStack(spacing: 5) {
              Text(device.udid)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .textSelection(.enabled)

              Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(device.udid, forType: .string)
              } label: {
                Image(systemName: "doc.on.doc")
                  .font(.system(size: 9, weight: .medium))
                  .frame(width: 14, height: 14)
              }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
              .help("Copy UDID")
              .accessibilityLabel("Copy UDID for \(device.name)")
            }
          }
        }
        .frame(minWidth: 255, maxWidth: .infinity, alignment: .leading)

        Text("iOS \(device.osVersion)")
          .font(.subheadline)
          .frame(width: 74, alignment: .leading)

        BootStateView(isBooted: device.isBooted)
          .frame(width: 86, alignment: .leading)

        ServiceStateView(
          state: model.slimState(for: device),
          isCached: model.stateIsCached(for: device),
          operation: operation
        )
        .frame(width: 150, alignment: .leading)

        Text(model.diskSizeText(for: device))
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(model.diskSizes[device.udid] == nil ? .tertiary : .secondary)
          .frame(width: 105, alignment: .leading)
          .help("Current allocated size of this simulator on disk")

        Group {
          if let measurement = model.measurements[device.udid] {
            Text(measurement.memoryText)
              .font(.subheadline.monospacedDigit())
          } else {
            Text("—")
              .foregroundStyle(.tertiary)
          }
        }
        .frame(width: 82, alignment: .leading)

        Menu {
          Section("Power") {
            if device.isBooted {
              Button {
                Task { await model.shutdownSimulator(device) }
              } label: {
                Label("Shut Down Simulator", systemImage: "stop.fill")
              }
            } else {
              Button {
                Task { await model.bootSimulator(device) }
              } label: {
                Label("Boot Simulator", systemImage: "play.fill")
              }
            }
          }

          Section("Service Profile") {
            Button {
              managementSheet = .slimmingRecommendation([device])
            } label: {
              Label("Slim Simulator", systemImage: "minus.circle")
            }

            Button {
              Task { await model.restoreOriginalServices(for: device) }
            } label: {
              Label("Unslim Simulator", systemImage: "plus.circle")
            }
          }

          Section("Disk Space") {
            Button(role: .destructive) {
              managementSheet = .diskCleanup([device], diskCleanupCategories)
            } label: {
              Label("Clean Disk Data", systemImage: "externaldrive.badge.xmark")
            }
            .disabled(!model.canCleanDisk([device]))
          }

          Section("Simulator") {
            Button {
              managementSheet = .clone(device)
            } label: {
              Label("Clone Simulator", systemImage: "plus.square.on.square")
            }

            Button {
              managementSheet = .rename(device)
            } label: {
              Label("Rename Simulator", systemImage: "pencil")
            }
          }

          Section("Finder") {
            Button {
              openInFinder(simulatorDirectoryURL)
            } label: {
              Label("Show Simulator in Finder", systemImage: "folder")
            }

            Button {
              openInFinder(appDataContainersURL)
            } label: {
              Label("Show App Data Containers in Finder", systemImage: "folder.badge.gearshape")
            }
          }

          Section("Status") {
            Button {
              Task { await model.refresh() }
            } label: {
              Label("Refresh Simulator Status", systemImage: "arrow.clockwise")
            }

            Button {
              Task { await model.measure(device) }
            } label: {
              Label("Refresh RAM", systemImage: "memorychip")
            }
            .disabled(!device.isBooted)
          }

          Section("Selection") {
            Button(isSelected ? "Deselect Simulator" : "Select Simulator") {
              model.toggleSelection(device.udid)
            }
          }

          Section("Destructive Actions") {
            Button(role: .destructive) {
              managementSheet = .erase([device])
            } label: {
              Label("Erase Simulator", systemImage: "eraser")
            }

            Button(role: .destructive) {
              managementSheet = .delete([device])
            } label: {
              Label("Delete Simulator", systemImage: "trash")
            }
          }
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: 20)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isBusy)
        .frame(width: 28)
      }

      if let operation {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(operation)
          Spacer()
          Text("Booting and rebooting can take a few minutes")
            .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 48)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 9)
    .background(isSelected ? Color.accentColor.opacity(0.075) : Color.clear)
    .animation(.easeInOut(duration: 0.16), value: isSelected)
    .animation(.easeInOut(duration: 0.16), value: operation)
  }

  private var simulatorDirectoryURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
      .appendingPathComponent(device.udid, isDirectory: true)
  }

  private var appDataContainersURL: URL {
    simulatorDirectoryURL
      .appendingPathComponent("data", isDirectory: true)
      .appendingPathComponent("Containers/Data/Application", isDirectory: true)
  }

  private func openInFinder(_ url: URL) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      model.presentedError = PresentedError(
        message: "The directory for \(device.name) does not exist at \(url.path)."
      )
      return
    }
    guard NSWorkspace.shared.open(url) else {
      model.presentedError = PresentedError(
        message: "Finder could not open \(url.path)."
      )
      return
    }
  }
}

private struct BootStateView: View {
  let isBooted: Bool

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(isBooted ? Color.green : Color.gray)
        .frame(width: 7, height: 7)
      Text(isBooted ? "Booted" : "Shutdown")
        .font(.subheadline)
        .foregroundStyle(isBooted ? Color.primary : Color.secondary)
    }
  }
}

private struct ServiceStateView: View {
  let state: ServiceSlimState
  let isCached: Bool
  let operation: String?

  var body: some View {
    HStack(spacing: 8) {
      if operation != nil {
        ProgressView()
          .controlSize(.small)
          .frame(width: 17)
      } else {
        Image(systemName: state.systemImage)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 17)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(operation == nil ? state.title : "Changing…")
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        if isCached && operation == nil {
          Text("last verified")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
      }
    }
    .help(
      isCached
        ? "Last verified while booted; launchd state cannot be queried live while this simulator is shutdown."
        : state.title
    )
    .accessibilityLabel("Service slimming: \(state.title)")
  }

}

private struct ActivityPanel: View {
  @EnvironmentObject private var model: AppModel
  let mode: SlimmingMode

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Activity", systemImage: "text.alignleft")
          .font(.subheadline.weight(.semibold))
        Spacer()
        if !model.activity.isEmpty {
          Button("Clear") { model.clearActivity() }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)

      if model.activity.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle")
            .foregroundStyle(.green)
          Text(
            mode == .derivedData
              ? "Ready. Select generated directories, then delete them from the toolbar."
              : "Ready. Select simulators, then choose an action from the toolbar."
          )
          .foregroundStyle(.secondary)
          Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(model.activity.prefix(7)) { entry in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(for: entry.level))
                  .foregroundStyle(color(for: entry.level))
                Text(entry.date.formatted(date: .omitted, time: .standard))
                  .monospacedDigit()
                  .foregroundStyle(.tertiary)
                Text(entry.message)
                  .textSelection(.enabled)
                Spacer()
              }
              .font(.caption)
            }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 9)
        }
        .frame(maxHeight: 95)
      }
    }
    .frame(height: model.activity.isEmpty ? 64 : 122, alignment: .top)
    .background(.bar)
  }

  private func icon(for level: ActivityEntry.Level) -> String {
    switch level {
    case .info: return "arrow.right.circle"
    case .success: return "checkmark.circle.fill"
    case .failure: return "exclamationmark.triangle.fill"
    }
  }

  private func color(for level: ActivityEntry.Level) -> Color {
    switch level {
    case .info: return .blue
    case .success: return .green
    case .failure: return .red
    }
  }
}
