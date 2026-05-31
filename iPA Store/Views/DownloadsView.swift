import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var downloads: AppDownloadService
    
    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 16)]
    
    var body: some View {
        NavigationStack {
            Group {
                if downloads.activeDownloads.isEmpty && downloads.downloads.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 46, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text("No Downloads")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if !downloads.activeDownloads.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Downloading")
                                        .font(.headline)
                                        .padding(.horizontal)
                                    
                                    LazyVGrid(columns: columns, spacing: 16) {
                                        ForEach(downloads.activeDownloads) { download in
                                            ActiveDownloadCard(download: download)
                                        }
                                    }
                                }
                            }
                            
                            if !downloads.downloads.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Downloaded")
                                        .font(.headline)
                                        .padding(.horizontal)
                                    
                                    LazyVGrid(columns: columns, spacing: 16) {
                                        ForEach(downloads.downloads) { download in
                                            DownloadedAppCard(download: download)
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem {
                    Button {
                        downloads.showDownloadsFolderInFinder()
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .help("Show Downloads in Finder")
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

private struct ActiveDownloadCard: View {
    let download: ActiveDownload
    
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: download.app.artworkUrl512)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(download.app.trackName)
                    .font(.headline)
                    .lineLimit(1)
                
                Text(download.app.artistName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                Text("Downloading \(Int(download.progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            DownloadProgressRing(progress: download.progress)
                .frame(width: 28, height: 28)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
    }
}

private struct DownloadedAppCard: View {
    @EnvironmentObject private var downloads: AppDownloadService
    let download: DownloadedApp
    
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: download.app.artworkUrl512)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(download.app.trackName)
                    .font(.headline)
                    .lineLimit(1)
                
                Text(download.app.artistName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                if let version = download.app.version {
                    Text("Version \(version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            VStack(spacing: 8) {
                Button("Export") {
                    downloads.export(download)
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 78)
                
                Button("Delete", role: .destructive) {
                    downloads.delete(download)
                }
                .buttonStyle(.bordered)
                .frame(minWidth: 78)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
    }
}
