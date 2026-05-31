//
//  ContentView.swift
//  iPA Store
//
//  Created by ih8coconuts on 5/27/26.
//

import SwiftUI
import SwiftUIIntrospect

enum AppStoreTab: String, CaseIterable, Identifiable {
    case discover = "Discover"
    case sideload = "Sideload"
    case downloads = "Downloads"
    
    var id: String { self.rawValue }
    
    var iconName: String {
        switch self {
        case .discover: return "star"
        case .sideload: return "iphone.and.arrow.right.inward"
        case .downloads: return "arrow.down.circle"
        }
    }
}

struct ContentView: View {
    @State private var selectedTab: AppStoreTab? = .discover
    @State private var selectedAppId: String?
    @State private var showingAccount = false
    @EnvironmentObject var auth: AppleAuthService
    @EnvironmentObject var downloads: AppDownloadService
    @State private var searchText: String = ""
    @State var showingSearch : Bool = false
    @StateObject private var searchService = iTunesSearchService()
    @StateObject private var searchPass = iTunesSearchService()
    
    
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(AppStoreTab.allCases) { tab in
                            Button {
                                selectedTab = tab
                                selectedAppId = nil
                                showingSearch = false
                            } label: {
                                SidebarRowButton(
                                    tab: tab,
                                    isSelected: selectedTab == tab,
                                    badgeCount: tab == .downloads ? downloads.activeDownloadCount : 0
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                
                Button {
                    showingAccount = true
                } label: {
                    AccountSidebarButton(
                        isSignedIn: auth.isSignedIn,
                        appleID: auth.appleID
                    )
                }
                .buttonStyle(.plain)
                .help(auth.isSignedIn ? "Open Apple Account" : "Sign In")
                
            }
            .searchable(
                text: $searchText,
                placement: .sidebar,
                prompt: "Search"
            ) {
                if !searchText.isEmpty {
                    ForEach(searchService.results.prefix(10)) { app in
                        Text(app.trackName)
                            .searchCompletion(app.trackName)
                    }
                }
                
                
            }
            .onChange(of: searchText) { _,newValue in
                if searchText.isEmpty {
                    //showingSearch = false
                } else {
                    Task {
                        await searchService.search(query: newValue)
                        
                    }
                    
                   
                }
                
            }
            .onSubmit(of: .search) {
                submitSearch(searchText)
            }
            .background(SearchSubmitBridge { query in
                submitSearch(query)
            })
            .background(.regularMaterial)
            
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
            
            
            
        } detail: {
            if showingSearch {
                SearchView( searchService: searchPass)
            } else {
                switch selectedTab {
                case .downloads:
                    DownloadsView()
                case .sideload:
                    SideloadView()
                case .discover, .none:
                    DiscoverView()
                }
            }
            
        }
        
        .introspect(.window, on: .macOS(.v14, .v15, .v26)) { window in
            guard let toolbar = window.toolbar else { return }
            
            for item in toolbar.items {
                if item.itemIdentifier.rawValue.lowercased().contains("sidebar") {
                    item.isEnabled = true
                    item.view?.isHidden = true
                }
            }
        }
        .sheet(isPresented: $showingAccount) {
            SignInView()
                .environmentObject(auth)
        }
    }
    
    private func submitSearch(_ query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedQuery.isEmpty else {
            showingSearch = false
            searchPass.clear()
            searchPass.query = ""
            return
        }
        
        if searchText != query {
            searchText = query
        }
        showingSearch = true
        searchPass.query = trimmedQuery
        
        Task {
            await searchPass.search(query: trimmedQuery)
        }
    }
}

private struct SearchSubmitBridge: NSViewRepresentable {
    let onSubmit: (String) -> Void
    
    func makeNSView(context: Context) -> SearchSubmitBridgeView {
        let view = SearchSubmitBridgeView()
        view.onSubmit = onSubmit
        return view
    }
    
    func updateNSView(_ nsView: SearchSubmitBridgeView, context: Context) {
        nsView.onSubmit = onSubmit
    }
    
    static func dismantleNSView(_ nsView: SearchSubmitBridgeView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

private final class SearchSubmitBridgeView: NSView {
    var onSubmit: ((String) -> Void)?
    private var keyMonitor: Any?
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMonitor()
    }
    
    deinit {
        stopMonitoring()
    }
    
    fileprivate func stopMonitoring() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
    
    private func updateMonitor() {
        stopMonitoring()
        
        guard window != nil else { return }
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 36 || event.keyCode == 76 else { return event }
            guard let window = self.window else { return event }
            
            if let eventWindow = event.window, eventWindow !== window {
                return event
            }
            
            guard let searchField = Self.activeSearchField(in: window) else {
                return event
            }
            
            let fieldEditorText = (window.firstResponder as? NSTextView)?.string
            let query = fieldEditorText ?? searchField.stringValue
            
            DispatchQueue.main.async { [weak self] in
                self?.onSubmit?(query)
            }
            
            return event
        }
    }
    
    private static func activeSearchField(in window: NSWindow) -> NSSearchField? {
        let rootView = window.contentView?.superview ?? window.contentView
        var searchFields = searchFields(in: rootView)
        
        if let toolbarItems = window.toolbar?.items {
            for item in toolbarItems {
                searchFields.append(contentsOf: self.searchFields(in: item.view))
            }
        }
        
        guard let fieldEditor = window.firstResponder as? NSTextView else {
            return searchFields.first { $0.window?.firstResponder === $0 }
        }
        
        return searchFields.first { $0.currentEditor() === fieldEditor }
    }
    
    private static func searchFields(in view: NSView?) -> [NSSearchField] {
        guard let view else { return [] }
        
        var result: [NSSearchField] = []
        if let searchField = view as? NSSearchField {
            result.append(searchField)
        }
        
        for subview in view.subviews {
            result.append(contentsOf: searchFields(in: subview))
        }
        
        return result
    }
}

struct DiscoverView: View {
    @State private var offsetY: CGFloat = 0
    @State private var window: NSWindow?
    var showSmallTitle: Bool {
        offsetY < -100
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: ScrollOffsetKey.self,
                            value: geo.frame(in: .named("scroll")).minY
                        )
                }
                .frame(height: 0)

                VStack(alignment: .leading, spacing: 20) {
                    Text("Discover")
                        .bold()
                        .font(.largeTitle)
                        .opacity(showSmallTitle ? 0 : 1)
                        .animation(.easeInOut, value: showSmallTitle)
                        .padding()

                    Rectangle()
                        .fill(.gray.opacity(0.25))
                        .frame(height: 300)

                    Rectangle()
                        .fill(.gray.opacity(0.25))
                        .frame(height: 300)

                    Rectangle()
                        .fill(.gray.opacity(0.25))
                        .frame(height: 300)
                }
          
            }
            .coordinateSpace(name: "scroll")
            .onPreferenceChange(ScrollOffsetKey.self) { value in
                offsetY = value
            }
          
            .navigationTitle(showSmallTitle ? "Discover" : "")
        }
    }
    
    private func updateWindowTitlebar(_ window: NSWindow, showSmallTitle: Bool) {
        window.titleVisibility = showSmallTitle ? .visible : .hidden
        window.titlebarAppearsTransparent = !showSmallTitle

        if showSmallTitle {
            window.styleMask.remove(.fullSizeContentView)
        } else {
            window.styleMask.insert(.fullSizeContentView)
        }

        window.toolbarStyle = showSmallTitle ? .unified : .unifiedCompact
    }
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct SidebarRowButton: View {
    let tab: AppStoreTab
    let isSelected: Bool
    let badgeCount: Int
    
    var body: some View {
        
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? .blue : .primary.opacity(0.8))
                    .frame(width: 24, height: 24)
                
                if badgeCount > 0 {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, badgeCount > 9 ? 4 : 0)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 7, y: -5)
                }
            }
            .frame(width: 24, height: 24)
            
            Text(tab.rawValue)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(isSelected ? .blue : .primary)
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Background tint mirroring the App Store button states
        .background {
            if isSelected {
                Rectangle()
                    .fill(.ultraThickMaterial)
            }
        }
        .cornerRadius(8)
        .contentShape(Rectangle())
    }
    
    private var badgeText: String {
        badgeCount > 99 ? "99+" : "\(badgeCount)"
    }
}

struct AccountSidebarButton: View {
    let isSignedIn: Bool
    let appleID: String
    
    var body: some View {
        HStack {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .frame(width: 32, height: 32)
                .foregroundColor(isSignedIn ? .gray : .blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSignedIn ? .primary : .blue)
                    .lineLimit(1)
                
                Text("Apple Account")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(16)
        .contentShape(Rectangle())
    }
    
    private var title: String {
        if isSignedIn, !appleID.isEmpty {
            return appleID
        }
        
        return "Sign In"
    }
}

// 4. Mock Subviews to populate the app layout
struct UserProfileBottomBar: View {
    var body: some View {
        HStack {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .frame(width: 32, height: 32)
                .foregroundColor(.gray)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Developer Name")
                    .font(.system(size: 13, weight: .medium))
                Text("Apple Account")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }
}

struct AppListView: View {
    let tab: AppStoreTab
    @Binding var selectedAppId: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tab.rawValue)
                .font(.largeTitle.bold())
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
            
            Divider()
            
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(1...20, id: \.self) { item in
                        let appId = "App \(item)"
                        
                        Button {
                            selectedAppId = appId
                        } label: {
                            AppListRow(item: item, isSelected: selectedAppId == appId)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(tab.rawValue)
    }
}

struct AppListRow: View {
    let item: Int
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.gradient)
                .frame(width: 44, height: 44)
            
            VStack(alignment: .leading, spacing: 3) {
                Text("Awesome App \(item)")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text("Short description goes here.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
    }
}

struct AppDetailView: View {
    let appId: String
    
    var body: some View {
        VStack(spacing: 20) {
            Text(appId)
                .font(.largeTitle)
                .bold()
            Text("Detailed product page description, screenshots, and reviews.")
                .foregroundColor(.secondary)
        }
        
    }
}

#Preview {
    ContentView()
        .frame(minWidth: 900, minHeight: 600)
        .environmentObject(AppleAuthService())
        .environmentObject(AppDownloadService())
        .environmentObject(SideloadSigningAccountService())
}


//SearchView()
//    .toolbar {
//        ToolbarItem {
//            Button {
//                showSignIn = true
//            } label: {
//                Label(
//                    auth.isSignedIn ? auth.appleID : "Sign In",
//                    systemImage: auth.isSignedIn ? "person.fill.checkmark" : "person.crop.circle"
//                )
//            }
//        }
//    }
//    .sheet(isPresented: $showSignIn) {
//        SignInView()
//            .environmentObject(auth)
//    }
