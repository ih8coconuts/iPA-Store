// Views/SearchView.swift
import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var auth: AppleAuthService
    @EnvironmentObject private var downloads: AppDownloadService
    @ObservedObject var searchService: iTunesSearchService
    @State private var query = ""
    
    let columns = [GridItem(.adaptive(minimum: 340), spacing: 16)]
    
    var body: some View {
        VStack(spacing: 0) {
            // Search Bar
            
            
            if searchService.isLoading {
                ProgressView().padding()
            } else {
                ScrollView {
                    HStack{
                        Text("Results for \"\(searchService.query)\"")
                            .bold()
                            .font(.largeTitle)
                            
                        Spacer()
                    }.padding()
                    
                    
                    Divider().padding(.horizontal)
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(searchService.results) { app in
                            AppCardView(
                                app: app,
                                isDownloading: downloads.isDownloading(app),
                                downloadProgress: downloads.activeDownload(for: app)?.progress ?? 0,
                                isDownloaded: downloads.downloadedApp(for: app) != nil
                            ) {
                                Task {
                                    await downloads.downloadToLibrary(app: app, auth: auth)
                                }
                            } onExport: {
                                downloads.export(app: app)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .alert(item: $downloads.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
