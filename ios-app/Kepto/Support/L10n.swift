import Foundation

/// Chuỗi giao diện bám ngôn ngữ hệ thống (vi / en), giống Photos.
enum L10n {
    static var isVI: Bool {
        Locale.current.language.languageCode?.identifier == "vi"
    }

    static var library: String { isVI ? "Thư viện" : "Library" }
    static var forYou: String { isVI ? "Dành cho bạn" : "For You" }
    static var albums: String { isVI ? "Album" : "Albums" }
    static var search: String { isVI ? "Tìm kiếm" : "Search" }

    static var years: String { isVI ? "Năm" : "Years" }
    static var months: String { isVI ? "Tháng" : "Months" }
    static var days: String { isVI ? "Ngày" : "Days" }
    static var allPhotos: String { isVI ? "Tất cả ảnh" : "All Photos" }

    static var select: String { isVI ? "Chọn" : "Select" }
    static var cancel: String { isVI ? "Huỷ" : "Cancel" }
    static var done: String { isVI ? "Xong" : "Done" }
    static var selectAll: String { isVI ? "Chọn tất cả" : "Select All" }
    static var deselectAll: String { isVI ? "Bỏ chọn tất cả" : "Deselect All" }
    static var share: String { isVI ? "Chia sẻ" : "Share" }
    static var favorite: String { isVI ? "Yêu thích" : "Favorite" }
    static var unfavorite: String { isVI ? "Bỏ yêu thích" : "Unfavorite" }
    static var add: String { isVI ? "Thêm" : "Add" }
    static var delete: String { isVI ? "Xoá" : "Delete" }
    static var more: String { isVI ? "Thêm" : "More" }
    static var edit: String { isVI ? "Sửa" : "Edit" }
    static var info: String { isVI ? "Thông tin" : "Info" }
    static var hide: String { isVI ? "Ẩn" : "Hide" }
    static var unhide: String { isVI ? "Bỏ ẩn" : "Unhide" }
    static var slideshow: String { isVI ? "Trình chiếu" : "Slideshow" }
    static var duplicate: String { isVI ? "Nhân bản" : "Duplicate" }
    static var addToAlbum: String { isVI ? "Thêm vào album" : "Add to Album" }
    static var newAlbum: String { isVI ? "Album mới" : "New Album" }
    static var albumName: String { isVI ? "Tên album" : "Album Name" }
    static var save: String { isVI ? "Lưu" : "Save" }
    static var create: String { isVI ? "Tạo" : "Create" }
    static var revert: String { isVI ? "Hoàn tác" : "Revert" }

    static var myAlbums: String { isVI ? "Album của tôi" : "My Albums" }
    static var sharedAlbums: String { isVI ? "Album được chia sẻ" : "Shared Albums" }
    static var peoplePets: String { isVI ? "Người & Thú cưng" : "People & Pets" }
    static var mediaTypes: String { isVI ? "Loại phương tiện" : "Media Types" }
    static var utilities: String { isVI ? "Tiện ích" : "Utilities" }

    static var recents: String { isVI ? "Gần đây" : "Recents" }
    static var favorites: String { isVI ? "Yêu thích" : "Favorites" }
    static var videos: String { isVI ? "Video" : "Videos" }
    static var selfies: String { isVI ? "Ảnh tự chụp" : "Selfies" }
    static var livePhotos: String { isVI ? "Live Photos" : "Live Photos" }
    static var portraits: String { isVI ? "Chân dung" : "Portrait" }
    static var screenshots: String { isVI ? "Ảnh chụp màn hình" : "Screenshots" }
    static var screenRecordings: String { isVI ? "Ghi màn hình" : "Screen Recordings" }
    static var panoramas: String { isVI ? "Toàn cảnh" : "Panoramas" }
    static var bursts: String { isVI ? "Chụp liên tiếp" : "Bursts" }
    static var cinematic: String { isVI ? "Điện ảnh" : "Cinematic" }
    static var animated: String { isVI ? "Ảnh động" : "Animated" }
    static var longExposures: String { isVI ? "Phơi sáng lâu" : "Long Exposures" }
    static var raw: String { isVI ? "RAW" : "RAW" }
    static var sloMo: String { isVI ? "Chuyển động chậm" : "Slo-mo" }
    static var timelapses: String { isVI ? "Tua nhanh" : "Time-lapse" }
    static var hdr: String { "HDR" }
    static var spatial: String { isVI ? "Không gian" : "Spatial" }
    static var imports: String { isVI ? "Đã nhập" : "Imports" }
    static var hidden: String { isVI ? "Đã ẩn" : "Hidden" }
    static var recentlyDeleted: String { isVI ? "Đã xoá gần đây" : "Recently Deleted" }
    static var recentlyAdded: String { isVI ? "Mới thêm" : "Recently Added" }

    static var memories: String { isVI ? "Kỷ niệm" : "Memories" }
    static var featured: String { isVI ? "Ảnh nổi bật" : "Featured Photos" }
    static var sharedActivity: String { isVI ? "Hoạt động album chia sẻ" : "Shared Album Activity" }
    static var seeAll: String { isVI ? "Xem tất cả" : "See All" }

    static var people: String { isVI ? "Người" : "People" }
    static var places: String { isVI ? "Địa điểm" : "Places" }
    static var categories: String { isVI ? "Danh mục" : "Categories" }
    static var moments: String { isVI ? "Khoảnh khắc" : "Moments" }
    static var searchPlaceholder: String { isVI ? "Ảnh, người, địa điểm…" : "Photos, People, Places…" }
    static var noResults: String { isVI ? "Không có kết quả" : "No Results" }
    static var suggestions: String { isVI ? "Gợi ý" : "Suggestions" }

    static var today: String { isVI ? "Hôm nay" : "Today" }
    static var yesterday: String { isVI ? "Hôm qua" : "Yesterday" }

    static var limitedTitle: String { isVI ? "Quyền truy cập giới hạn" : "Limited Access" }
    static var limitedBody: String {
        isVI
            ? "Bạn chỉ chia sẻ một phần thư viện. Ảnh khác vẫn nằm trong Photos của hệ thống."
            : "You’ve shared a limited selection. The rest stays in the system Photos app."
    }
    static var manage: String { isVI ? "Quản lý" : "Manage" }
    static var allowAccess: String { isVI ? "Cho phép truy cập" : "Allow Access" }
    static var openSettings: String { isVI ? "Mở Cài đặt" : "Open Settings" }
    static var permissionTitle: String { isVI ? "Cần quyền Thư viện ảnh" : "Photo Access Needed" }
    static var permissionBody: String {
        isVI
            ? "Cho phép truy cập để xem thư viện, album, Live Photo và video ngay trên máy."
            : "Allow access to browse your library, albums, Live Photos and videos on this device."
    }
    static var emptyTitle: String { isVI ? "Không có ảnh" : "No Photos" }
    static var emptyBody: String {
        isVI
            ? "Ảnh và video bạn chụp sẽ xuất hiện ở đây."
            : "Photos and videos you take will appear here."
    }
    static var loading: String { isVI ? "Đang tải thư viện…" : "Loading library…" }
    static var peopleNote: String {
        isVI
            ? "Nhận diện khuôn mặt chạy trên thiết bị trong Photos. App này chỉ hiện album người đã đồng bộ, nếu có."
            : "Face recognition stays on-device in Photos. This app lists synced People albums when they exist."
    }
    static var deletedNote: String {
        isVI
            ? "Ảnh xoá từ app này được chuyển vào Đã xoá gần đây của Photos hệ thống và giữ khoảng 30 ngày. PhotoKit công khai không cho app bên thứ ba liệt kê album đó."
            : "Items you delete move to the system Photos Recently Deleted album for about 30 days. Public PhotoKit does not let third-party apps list that album."
    }
    static var hiddenNote: String {
        isVI
            ? "Ảnh ẩn trong app này được lọc khỏi Thư viện. Ảnh ẩn bằng Photos hệ thống cũng hiện ở đây (chỉ xem)."
            : "Photos you hide here are filtered out of Library. Items hidden in the system Photos app are listed read-only."
    }
    static var noShared: String { isVI ? "Chưa có album chia sẻ" : "No Shared Albums" }
    static var videoEditNote: String {
        isVI ? "Trình sửa chỉ áp dụng cho ảnh tĩnh." : "The editor works on still photos."
    }
    static var savedCopy: String { isVI ? "Đã lưu bản chỉnh sửa" : "Saved edited copy" }
    static var adjust: String { isVI ? "Điều chỉnh" : "Adjust" }
    static var filters: String { isVI ? "Bộ lọc" : "Filters" }
    static var crop: String { isVI ? "Cắt" : "Crop" }
    static var markup: String { isVI ? "Đánh dấu" : "Markup" }
    static var exposure: String { isVI ? "Phơi sáng" : "Exposure" }
    static var contrast: String { isVI ? "Tương phản" : "Contrast" }
    static var saturation: String { isVI ? "Bão hoà" : "Saturation" }
    static var brilliance: String { isVI ? "Độ rực" : "Brilliance" }
    static var warmth: String { isVI ? "Ấm" : "Warmth" }
    static var vignette: String { isVI ? "Tối góc" : "Vignette" }
    static var original: String { isVI ? "Gốc" : "Original" }
    static var vivid: String { isVI ? "Sống động" : "Vivid" }
    static var vividWarm: String { isVI ? "Ấm sống động" : "Vivid Warm" }
    static var vividCool: String { isVI ? "Mát sống động" : "Vivid Cool" }
    static var dramatic: String { isVI ? "Kịch tính" : "Dramatic" }
    static var mono: String { isVI ? "Đơn sắc" : "Mono" }
    static var noir: String { isVI ? "Noir" : "Noir" }
    static var silhouette: String { isVI ? "Bóng đen" : "Silhouette" }
    static var free: String { isVI ? "Tự do" : "Free" }
    static var details: String { isVI ? "Chi tiết" : "Details" }
    static var camera: String { isVI ? "Máy ảnh" : "Camera" }
    static var lens: String { isVI ? "Ống kính" : "Lens" }
    static var aperture: String { isVI ? "Khẩu độ" : "Aperture" }
    static var shutter: String { isVI ? "Tốc độ" : "Shutter" }
    static var iso: String { "ISO" }
    static var dimensions: String { isVI ? "Kích thước" : "Dimensions" }
    static var fileSize: String { isVI ? "Dung lượng" : "File Size" }
    static var filename: String { isVI ? "Tên tệp" : "Filename" }
    static var taken: String { isVI ? "Chụp lúc" : "Taken" }
    static var location: String { isVI ? "Vị trí" : "Location" }
    static var media: String { isVI ? "Phương tiện" : "Media" }
    static var edited: String { isVI ? "Đã sửa" : "Edited" }
    static var play: String { isVI ? "Phát" : "Play" }
    static var pause: String { isVI ? "Tạm dừng" : "Pause" }
    static var back: String { isVI ? "Quay lại" : "Back" }

    /// Kepto additions (not in Photos): keys the ported viewer/info
    /// sheet needs for Kepto-only actions.
    static var duration: String { isVI ? "Thời lượng" : "Duration" }
    static var uploaded: String { isVI ? "Ngày tải lên" : "Uploaded" }
    static var saveToPhotos: String { isVI ? "Lưu vào Photos" : "Save to Photos" }
    static var undo: String { isVI ? "Hoàn tác nét" : "Undo" }
    static var clear: String { isVI ? "Xoá nét" : "Clear" }

    /// Kepto additions (step 9): keys for the ported views' inline
    /// strings. Same ternary pattern as the Photos keys above.
    static var importFromPhotos: String { isVI ? "Nhập từ Photos" : "Import from Photos" }
    static var pasteClipboard: String { isVI ? "Dán từ Clipboard" : "Paste Clipboard" }
    static var settings: String { isVI ? "Cài đặt" : "Settings" }
    static var moreOptions: String { isVI ? "Tuỳ chọn khác" : "More options" }
    static var removeFromAlbum: String { isVI ? "Xoá khỏi album" : "Remove from Album" }
    static var addPhotos: String { isVI ? "Thêm ảnh" : "Add Photos" }
    static var renameAlbum: String { isVI ? "Đổi tên album" : "Rename Album" }
    static var deleteAlbum: String { isVI ? "Xoá album" : "Delete Album" }
    static var deleteAlbumAndVideos: String { isVI ? "Xoá album & video" : "Delete Album & Videos" }
    static var deleteAlbumOnly: String { isVI ? "Chỉ xoá album" : "Delete Album Only" }
    static var loadMore: String { isVI ? "Tải thêm" : "Load more" }
    static var rename: String { isVI ? "Đổi tên" : "Rename" }
    static var newAlbumMessage: String { isVI ? "Nhập tên cho album này." : "Enter a name for this album." }
    static var renameAlbumMessage: String { isVI ? "Nhập tên mới cho album này." : "Enter a new name for this album." }
    static var title: String { isVI ? "Tiêu đề" : "Title" }
    static var removeFailed: String { isVI ? "Xoá khỏi album thất bại" : "Remove failed" }
    static var deleteFailed: String { isVI ? "Xoá thất bại" : "Delete failed" }
    static var nothingHere: String { isVI ? "Không có gì ở đây" : "Nothing here" }
    static var noVideosToShow: String { isVI ? "Không có video để xem." : "No videos to show." }
    static var nothingSavedYet: String { isVI ? "Chưa lưu gì cả" : "Nothing saved yet" }
    static var saveLinksHint: String { isVI ? "Lưu vài link, các danh mục sẽ hiện ở đây." : "Save some links and categories will show up here." }
    static var forYouEmptyHint: String { isVI ? "Lưu vài video và ảnh — kỷ niệm và ảnh nổi bật sẽ hiện ở đây." : "Save some videos and photos — memories and featured picks will show up here." }
    static var emptyLibraryHint: String { isVI ? "Chạm + rồi dán link từ TikTok, Instagram, Threads, X, Facebook, Douyin hoặc YouTube." : "Tap + and paste a link from TikTok, Instagram, Threads, X, Facebook, Douyin, or YouTube." }
    static var setupKepto: String { isVI ? "Thiết lập Kepto" : "Set up Kepto" }
    static var setupHint: String { isVI ? "Nhập Worker URL và API key trong Cài đặt để bắt đầu lưu." : "Enter your Worker URL and API key in Settings to start saving." }
    static var saveLink: String { isVI ? "Lưu link" : "Save a link" }
    static var saveLinkAlert: String { isVI ? "Lưu link" : "Save link" }
    static var pasteLinkPlaceholder: String { isVI ? "Dán link TikTok, Instagram…" : "Paste a TikTok, Instagram… link" }
    static var addToCollection: String { isVI ? "Thêm vào collection" : "Add to collection" }
    static var newCollectionName: String { isVI ? "Tên collection mới" : "New collection name" }
    static var noAlbumsHint: String { isVI ? "Chưa có album nào. Tạo album mới để lưu ảnh/video vừa import." : "No albums yet. Create a new album to save the photos/videos you just imported." }
    static var noAlbumsYet: String { isVI ? "Chưa có album nào" : "No albums yet" }
    static var processing: String { isVI ? "Đang xử lý…" : "Processing…" }
    static var playbackSpeed: String { isVI ? "Tốc độ phát" : "Playback speed" }
    static var mute: String { isVI ? "Tắt tiếng" : "Mute" }
    static var unmute: String { isVI ? "Bật tiếng" : "Unmute" }
    static var importedFromPhotos: String { isVI ? "Đã nhập từ Photos" : "Imported from Photos" }
    static var noCameraInfo: String { isVI ? "Không có thông tin máy ảnh" : "No camera information" }
    static var noLensInfo: String { isVI ? "Không có thông tin ống kính" : "No lens information" }
    static var creators: String { "Creators" }
    static var photos: String { isVI ? "Ảnh" : "Photos" }
    static var noMemoriesYet: String { isVI ? "Chưa có kỷ niệm nào" : "No memories yet" }
    static var noFeaturedYet: String { isVI ? "Chưa có ảnh nổi bật" : "No featured photos yet" }
    static var noFavoritesYet: String { isVI ? "Chưa có mục yêu thích" : "No favorites yet" }
    static var noVideosYet: String { isVI ? "Chưa có video nào" : "No videos yet" }
    static var favoriteHint: String { isVI ? "Chạm vào tim trên video để thêm vào Yêu thích." : "Tap the heart on a video to add it to Favorites." }
    static var videosWillAppearHere: String { isVI ? "Video bạn lưu sẽ hiện ở đây." : "Videos you save will appear here." }
    static var addFromFeedMenu: String { isVI ? "Thêm video từ menu long-press trong trình xem." : "Add a video from the feed's long-press menu." }
    static var photosWillAppearHere: String { isVI ? "Ảnh bạn lưu sẽ hiện ở đây." : "Photos you save will appear here." }
    static var clipboardNoLink: String { isVI ? "Không có link trên clipboard." : "No link on the clipboard." }
    static var clipboardNoHttpLink: String { isVI ? "Clipboard không có link http(s) nào." : "The clipboard has no http(s) link." }
    static var createCollectionFailed: String { isVI ? "Không tạo được collection. Kiểm tra kết nối rồi thử lại." : "Couldn't create the collection. Check your connection and try again." }
    static var addToCollectionFailed: String { isVI ? "Không thêm được. Kiểm tra kết nối rồi thử lại." : "Couldn't add. Check your connection and try again." }
    static var shareDownloadFailed: String { isVI ? "Không tải được file để chia sẻ." : "Couldn't download the files to share." }
    static var loadItemsToAddFailed: String { isVI ? "Không tải được mục để thêm." : "Couldn't load the items to add." }
    static var deleteFromCloudMessage: String { isVI ? "Thao tác này sẽ xoá bản lưu trên cloud. Không thể hoàn tác." : "This removes the saved copies from the cloud. This cannot be undone." }
    static var deleteSingleFromCloudMessage: String { isVI ? "Thao tác này sẽ xoá bản lưu trên cloud. Bài gốc không bị ảnh hưởng." : "This removes the saved copy from the cloud. The original post is not affected." }

    static func selectedCount(_ n: Int) -> String {
        if isVI { return n == 0 ? "Chọn ảnh" : "Đã chọn \(n)" }
        if n == 0 { return "Select Photos" }
        return n == 1 ? "1 Photo Selected" : "\(n) Photos Selected"
    }

    static func itemCount(_ n: Int) -> String {
        if isVI { return "\(n)" }
        return n == 1 ? "1" : "\(n)"
    }

    static func deleteTitle(_ n: Int) -> String {
        if isVI { return n <= 1 ? "Xoá ảnh?" : "Xoá \(n) mục?" }
        return n <= 1 ? "Delete Photo?" : "Delete \(n) Items?"
    }

    static var deleteMessage: String {
        isVI
            ? "Mục này sẽ chuyển vào Đã xoá gần đây trong Photos trên mọi thiết bị dùng cùng thư viện iCloud."
            : "These items will move to Recently Deleted in Photos on all devices using this iCloud library."
    }

    static func memoryTitle(month: String, place: String?) -> String {
        if let place, !place.isEmpty { return "\(month) · \(place)" }
        return month
    }

    static func deleteSavedItemsTitle(_ n: Int) -> String {
        if isVI { return n <= 1 ? "Xoá mục đã lưu này?" : "Xoá \(n) mục?" }
        return n <= 1 ? "Delete this saved item?" : "Delete \(n) items?"
    }

    static func deleteAlbumTitle(_ name: String) -> String {
        isVI ? "Xoá album \"\(name)\"?" : "Delete Album \"\(name)\"?"
    }

    static func deleteAlbumMessage(_ count: Int) -> String {
        if isVI {
            return "Xoá album & video sẽ xoá vĩnh viễn album và mọi video trong đó (\(count) video). Chỉ xoá album sẽ chỉ gỡ album — video vẫn còn trong thư viện."
        }
        return "Delete Album & Videos permanently deletes the album and every video in it (\(count) video\(count == 1 ? "" : "s")). Delete Album Only removes just the album — the videos stay saved in the library."
    }

    static func deleteCreatorMessage(_ count: Int) -> String {
        if isVI {
            return "Thao tác này sẽ xoá vĩnh viễn album và tất cả \(count) video của creator này. Không thể hoàn tác."
        }
        return "This permanently deletes the album and all \(count) video\(count == 1 ? "" : "s") by this creator. This cannot be undone."
    }

    static func addedCountToCollection(_ added: Int, _ name: String) -> String {
        isVI ? "Đã thêm \(added) vào \(name)." : "Added \(added) to \(name)."
    }

    static func addedToCollection(_ name: String) -> String {
        isVI ? "Đã thêm vào \(name)." : "Added to \(name)."
    }

    static func alreadyInCollection(_ name: String) -> String {
        isVI ? "Đã có trong \(name)." : "Already in \(name)."
    }

    static func createdCollection(_ name: String) -> String {
        isVI ? "Đã tạo collection \"\(name)\"." : "Created collection \"\(name)\"."
    }

    static func createdButNotAdded(_ name: String) -> String {
        isVI ? "Đã tạo \(name) nhưng chưa thêm được video." : "Created \(name) but couldn't add the video."
    }

    static func deletedCount(_ deleted: Int) -> String {
        if isVI { return "Đã xóa \(deleted) video." }
        return "Deleted \(deleted) video\(deleted == 1 ? "" : "s")."
    }

    static func deletedCountPartial(_ deleted: Int, _ failures: Int) -> String {
        if isVI { return "Đã xóa \(deleted) video, \(failures) video lỗi." }
        return "Deleted \(deleted) video\(deleted == 1 ? "" : "s"), \(failures) failed."
    }

    static func savedToPhotos(_ saved: Int) -> String {
        isVI ? "Đã lưu \(saved) vào Photos." : "Saved \(saved) to Photos."
    }

    static func savedToPhotosPartial(_ saved: Int, _ failed: Int) -> String {
        if isVI { return "Đã lưu \(saved) vào Photos, \(failed) lỗi." }
        return "Saved \(saved) to Photos, \(failed) failed."
    }

    static func itemsCount(_ n: Int) -> String {
        if isVI { return "\(n) mục" }
        return n == 1 ? "1 Item" : "\(n) Items"
    }

    static func collectionVideoCount(_ n: Int) -> String {
        if isVI { return "\(n) video" }
        return n == 1 ? "1 video" : "\(n) videos"
    }

    static func photoCount(_ n: Int) -> String {
        if isVI { return n == 1 ? "1 ảnh" : "\(n) ảnh" }
        return n == 1 ? "1 Photo" : "\(n) Photos"
    }

    static func videoCount(_ n: Int) -> String {
        if isVI { return n == 1 ? "1 video" : "\(n) video" }
        return n == 1 ? "1 Video" : "\(n) Videos"
    }

    static func uploadingCount(_ done: Int, _ total: Int) -> String {
        isVI ? "Đang tải lên \(done)/\(total)…" : "Uploading \(done)/\(total)…"
    }

    static func savedFrom(_ platform: String) -> String {
        isVI ? "Đã lưu từ \(platform)" : "Saved from \(platform)"
    }

    static func videosFromCreator(_ name: String) -> String {
        isVI ? "Video đã lưu từ \(name) sẽ hiện ở đây." : "Videos saved from \(name) will appear here."
    }

    /// "just now" / "5m ago" / "2h ago" … from a posted/saved date.
    static func relativeAgo(seconds: Int) -> String {
        if seconds < 60 { return isVI ? "vừa xong" : "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return isVI ? "\(minutes)p trước" : "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return isVI ? "\(hours)g trước" : "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return isVI ? "\(days)n trước" : "\(days)d ago" }
        let weeks = days / 7
        if weeks < 5 { return isVI ? "\(weeks)t trước" : "\(weeks)w ago" }
        let months = days / 30
        if months < 12 { return isVI ? "\(months)th trước" : "\(months)mo ago" }
        return isVI ? "\(days / 365)n trước" : "\(days / 365)y ago"
    }
}
