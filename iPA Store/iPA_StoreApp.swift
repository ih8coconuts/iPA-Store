//
//  iPA_StoreApp.swift
//  iPA Store
//
//  Created by ih8coconuts on 5/27/26.
//

import SwiftUI

@main
struct iPA_StoreApp: App {
    @StateObject private var auth = AppleAuthService()
    @StateObject private var downloads = AppDownloadService()
    @StateObject private var signingAccounts = SideloadSigningAccountService()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(downloads)
                .environmentObject(signingAccounts)
        }
    }
}
