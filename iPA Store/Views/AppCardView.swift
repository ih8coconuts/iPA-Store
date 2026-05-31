// Views/AppCardView.swift
import SwiftUI

struct AppCardView: View {
    let app: AppResult
    let isDownloading: Bool
    let downloadProgress: Double
    let isDownloaded: Bool
    let onDownload: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // App Icon
            AsyncImage(url: URL(string: app.artworkUrl512)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            // App Info
            VStack(alignment: .leading, spacing: 4) {
                Text(app.trackName)
                    .font(.headline)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Text(app.version.map { "Version \($0)" } ?? "Version unavailable")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text(app.formattedPrice ?? "Free")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            .layoutPriority(1)

            Spacer()

            Button {
                if isDownloaded {
                    onExport()
                } else {
                    onDownload()
                }
            } label: {
                Group {
                    if isDownloading {
                        DownloadProgressRing(progress: downloadProgress)
                            .frame(width: 18, height: 18)
                    } else {
                        Text(isDownloaded ? "Export" : "Download")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                }
                .frame(width: 96, height: 32)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(isDownloading)
            .help(isDownloading ? "Downloading" : (isDownloaded ? "Export IPA" : "Download IPA"))
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
    }
}

struct DownloadProgressRing: View {
    let progress: Double
    
    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 2.4)
            
            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .animation(.linear(duration: 0.15), value: clampedProgress)
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(clampedProgress * 100)) percent")
    }
}
