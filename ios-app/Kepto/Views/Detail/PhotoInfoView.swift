import SwiftUI
import UIKit

/// Merged info sheet: Photos' `PhotoInfoView` List structure + Kepto's
/// content (v59–v60 `ItemInfoSheet`). The title is the TikTok display
/// name + relative posted time, then the caption, then the absolute
/// posted date; the Details section has the media type, the "No camera
/// information" / "No lens information" rows, dimensions, file size and
/// duration; the Saved-from row opens the original post in Safari
/// (album imports show "Imported from Photos"); Save to Photos and
/// Add to Album live here too.
///
/// No Map/location section (Item has no location data), no EXIF
/// camera/lens/aperture/shutter/ISO/filename rows (Item has none).
/// The sheet follows the system appearance (Q11) — no forced OLED
/// black background.
struct PhotoInfoView: View {
    let item: Item
    var onSaveToPhotos: () -> Void = {}
    var onAddToAlbum: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Title: TikTok display name + relative posted time,
                // large like the TikTok header; then the caption;
                // then the absolute posted date, like Photos.
                Section {
                    HStack(spacing: 6) {
                        Text(authorName)
                            .font(.title2)
                            .fontWeight(.semibold)
                        if let relative = relativeTimeString {
                            Text("· \(relative)")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let caption = item.caption,
                       !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(caption)
                            .font(.title3)
                    }
                    if let dateString = infoDateString {
                        Text(dateString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(L10n.details) {
                    LabeledContent(L10n.media, value: mediaLabel)
                    LabeledContent(L10n.camera, value: L10n.noCameraInfo)
                    LabeledContent(L10n.lens, value: L10n.noLensInfo)
                    if let dims = item.formattedDimensions {
                        LabeledContent(L10n.dimensions, value: dims)
                    }
                    if let size = item.formattedFileSize {
                        LabeledContent(L10n.fileSize, value: size)
                    }
                    if let duration = item.formattedDuration {
                        LabeledContent(L10n.duration, value: duration)
                    }
                    if item.isFavorite {
                        LabeledContent(L10n.favorite, value: "♥")
                    }
                }

                // "Saved from <platform>" (tappable — opens the
                // original post in Safari) or "Imported from Photos".
                Section {
                    if let originalURL = URL(string: item.originalUrl),
                       let scheme = originalURL.scheme, scheme.hasPrefix("http") {
                        Button {
                            dismiss()
                            UIApplication.shared.open(originalURL)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "link")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color(.systemGray4), in: RoundedRectangle(cornerRadius: 8))
                                Text(L10n.savedFrom(item.platform.displayName))
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "photo")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Color(.systemGray4), in: RoundedRectangle(cornerRadius: 8))
                            Text(L10n.importedFromPhotos)
                                .font(.subheadline)
                            Spacer()
                        }
                    }
                }

                Section {
                    Button {
                        dismiss()
                        onSaveToPhotos()
                    } label: {
                        Label(L10n.saveToPhotos, systemImage: "arrow.down.to.line")
                    }
                    Button {
                        dismiss()
                        onAddToAlbum()
                    } label: {
                        Label(L10n.addToAlbum, systemImage: "folder.badge.plus")
                    }
                }
            }
            .navigationTitle(L10n.info)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.done) { dismiss() }
                }
            }
        }
    }

    /// TikTok display name (author), else "@username", else the
    /// platform name.
    private var authorName: String {
        if let author = item.author,
           !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return author
        }
        return item.collectionName
    }

    /// "1d ago" / "2h ago" / "3w ago" from the posted date (else
    /// the saved date).
    private var relativeTimeString: String? {
        guard let date = item.postedDate ?? item.savedDate else { return nil }
        return L10n.relativeAgo(seconds: Int(Date().timeIntervalSince(date)))
    }

    /// "Saturday · 17 Jan 2026 · 09:47" — the posted date, or the
    /// saved date when the post date is unknown.
    private var infoDateString: String? {
        let date = item.postedDate ?? item.savedDate
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE · d MMM yyyy · HH:mm"
        return formatter.string(from: date)
    }

    private var isVideo: Bool { item.contentType?.hasPrefix("video/") == true }

    /// Media type + codec, e.g. "Videos · MP4" / "All Photos · JPEG".
    private var mediaLabel: String {
        var parts: [String] = [isVideo ? L10n.videos : L10n.allPhotos]
        if let codec = codecBadge { parts.append(codec) }
        return parts.joined(separator: " · ")
    }

    /// Short codec/container label from the stored MIME type
    /// ("MP4", "MOV", "JPEG", "HEIC", …) for the media row.
    private var codecBadge: String? {
        guard let type = item.contentType else { return nil }
        let subtype = type.split(separator: "/").last.map(String.init) ?? ""
        switch subtype.lowercased() {
        case "mp4": return "MP4"
        case "quicktime": return "MOV"
        case "x-matroska": return "MKV"
        case "jpeg": return "JPEG"
        case "png": return "PNG"
        case "heic": return "HEIC"
        case "webp": return "WEBP"
        case "gif": return "GIF"
        case "hevc": return "HEVC"
        default: return subtype.isEmpty ? nil : subtype.uppercased()
        }
    }
}
