import SwiftUI
import UIKit

/// Merged info sheet: Photos' `PhotoInfoView` List structure + Kepto's
/// content (v59–v60 `ItemInfoSheet`). The title (TikTok display name +
/// relative posted time, then the caption) sits OUTSIDE the card, large
/// like TikTok's post header; the Details section has the media type,
/// the "No camera information" / "No lens information" rows, dimensions,
/// file size, duration and the upload date (under Duration); the
/// Saved-from row sits OUTSIDE the card below the list and opens the
/// original post in Safari (album imports show "Imported from Photos").
/// No Save to Photos / Add to Album here (user request — those live on
/// the grid context menu and the viewer toolbar).
///
/// No Map/location section (Item has no location data), no EXIF
/// camera/lens/aperture/shutter/ISO/filename rows (Item has none).
/// The sheet follows the system appearance (Q11) — no forced OLED
/// black background.
struct PhotoInfoView: View {
    let item: Item
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                // Title OUTSIDE the card (TikTok style): display name
                // + relative posted time on one line, large like
                // TikTok's post header, then the caption below. No
                // card, no date here — the date lives in Details.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(authorName)
                            .font(.system(size: 17, weight: .semibold))
                        if let relative = relativeTimeString {
                            Text("· \(relative)")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let caption = item.caption,
                       !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(caption)
                            .font(.system(size: 15))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

                List {
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
                        // Upload date, under Duration.
                        if let dateString = infoDateString {
                            LabeledContent(L10n.uploaded, value: dateString)
                        }
                        if item.isFavorite {
                            LabeledContent(L10n.favorite, value: "♥")
                        }
                    }
                }

                // "Saved from <platform>" OUTSIDE the card, below the
                // list.
                Divider()
                savedFromRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
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

    /// "Saved from <platform>" (tappable — opens the original post in
    /// Safari) or "Imported from Photos".
    private var savedFromRow: some View {
        Group {
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

    /// Date only ("17 Jan 2026") — no weekday, no time (user
    /// request, round 7). The posted date, or the saved date when
    /// the post date is unknown.
    private var infoDateString: String? {
        let date = item.postedDate ?? item.savedDate
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
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
