import SwiftUI

struct CatalogView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    @State private var viewModel: CatalogViewModel?
    @State private var selectedMedia: SeerrMedia?
    @State private var selectedFilter: CatalogFilter?
    @State private var selectedSection: Section = .discover

    private enum Section: Hashable {
        case discover, myRequests, allRequests
    }

    var body: some View {
        ThemeNavigationStack {
            Group {
                if !appState.isSeerrConnected {
                    notConnectedState
                } else if let vm = viewModel {
                    VStack(spacing: 0) {
                        Picker("", selection: $selectedSection) {
                            Text("catalog.tab.discover").tag(Section.discover)
                            Text("catalog.tab.myRequests").tag(Section.myRequests)
                            if appState.activeSeerrUser?.canManageRequests == true {
                                Text("catalog.tab.allRequests").tag(Section.allRequests)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, metrics.rowInset)
                        .padding(.top, 20)

                        switch selectedSection {
                        case .discover:
                            CatalogDiscoverView(
                                viewModel: vm,
                                onSelect: { media in selectedMedia = media },
                                onSelectFilter: { filter in selectedFilter = filter }
                            )
                        case .myRequests:
                            CatalogMyRequestsView(viewModel: vm)
                        case .allRequests:
                            CatalogAllRequestsView(viewModel: vm)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Present details as a full-screen cover (over the tab bar) instead of a push, so the bar is never hidden/removed and thus never re-templated gray on return (the tvOS 26 system bug). See detailCover.
            .detailCover(item: $selectedMedia) { media in
                CatalogDetailView(media: media)
            }
            .detailCover(item: $selectedFilter) { filter in
                CatalogFilteredGridView(filter: filter, cacheIdentity: appState.cacheIdentity)
            }
        }
        .onAppear(perform: bootstrap)
        .onChange(of: selectedSection) { _, newValue in
            guard let vm = viewModel else { return }
            switch newValue {
            case .myRequests:
                guard vm.myRequests.isEmpty,
                      let userID = appState.activeSeerrUser?.id else { return }
                Task { await vm.loadMyRequests(userID: userID) }
            case .allRequests:
                guard vm.allRequests.isEmpty else { return }
                Task {
                    await vm.loadAllRequests()
                    await vm.refreshAllRequestsCounts()
                }
            case .discover:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .seerrRequestsDidChange)) { _ in
            // Section-switch handlers only load EMPTY lists, so refresh already-loaded ones here; empty lists load on next switch.
            guard let vm = viewModel else { return }
            if !vm.myRequests.isEmpty, let userID = appState.activeSeerrUser?.id {
                Task { await vm.loadMyRequests(userID: userID) }
            }
            if !vm.allRequests.isEmpty {
                Task {
                    await vm.loadAllRequests()
                    await vm.refreshAllRequestsCounts()
                }
            }
        }
        .onChange(of: appState.activeUser?.id) { _, _ in
            // Profile switch: cached Seerr state (permission-scoped discover, prior-user My Requests) is stale; reset so bootstrap() rebuilds once Seerr reconnects.
            viewModel = nil
            selectedMedia = nil
            selectedFilter = nil
            selectedSection = .discover
        }
        .onChange(of: appState.isSeerrConnected) { _, connected in
            // Seerr came online after .onAppear already bailed bootstrap (no connection then); without this trigger the user saw an endless spinner until tab-hopping away and back.
            if connected {
                bootstrap()
            } else {
                viewModel = nil
                selectedMedia = nil
                selectedFilter = nil
                selectedSection = .discover
            }
        }
    }

    private func bootstrap() {
        guard appState.isSeerrConnected else { return }
        if viewModel == nil {
            let vm = CatalogViewModel(
                discoverService: dependencies.seerrDiscoverService,
                requestService: dependencies.seerrRequestService,
                mediaService: dependencies.seerrMediaService,
                cacheIdentity: appState.cacheIdentity
            )
            viewModel = vm
            Task { await vm.loadDiscover() }
        }
    }

    private var notConnectedState: some View {
        VStack(spacing: 24) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("catalog.empty.noServer.title")
                .font(.headline)
            Text("catalog.empty.noServer.description")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)

            // Quick-jump into Seerr setup so first-time users have a path forward; pushed inside Catalog's own NavigationStack so back returns to the tab.
            // themedNavigationDestination for the same reason every Settings push carries it: the
            // pushed host paints its own opaque background on iOS, which shows as a black page over
            // the app backdrop.
            NavigationLink {
                SeerrSettingsView()
                    .hidesShellTabBar()
                    .themedNavigationDestination()
            } label: {
                Label {
                    Text(String(
                        localized: "catalog.empty.noServer.setup",
                        defaultValue: "Set up Seerr"
                    ))
                } icon: {
                    Image(systemName: "arrow.right.circle")
                }
                .font(.body)
                .fontWeight(.medium)
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
            }
            .buttonStyle(SettingsTileButtonStyle())
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
