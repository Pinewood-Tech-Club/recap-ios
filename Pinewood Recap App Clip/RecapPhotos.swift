// RecapPhotos.swift — Native SwiftUI photo gallery for Pinewood Recap
// iOS 26 · Liquid Glass · iPhone + iPad adaptive

import SwiftUI
import UIKit
import ImageIO

// MARK: - Constants

private let kBase      = "https://photos.recap.pinewood.one"
private let kThreshold = 0.3
private let kAccent    = Color(red: 0.106, green: 0.541, blue: 0.294)
private let kFilmH: CGFloat = 66

// MARK: - Image loading

actor PhotoImageCache {
    static let shared = PhotoImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage, Error>] = [:]

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 180 * 1024 * 1024
    }

    func image(for url: URL, maxPixelSize: CGFloat? = nil) async throws -> UIImage {
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if let task = inFlight[key as String] { return try await task.value }

        let task = Task<UIImage, Error> {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = Self.decode(data, maxPixelSize: maxPixelSize) else {
                throw URLError(.cannotDecodeContentData)
            }
            return image
        }

        inFlight[key as String] = task
        do {
            let image = try await task.value
            cache.setObject(image, forKey: key, cost: Self.cost(of: image))
            inFlight[key as String] = nil
            return image
        } catch {
            inFlight[key as String] = nil
            throw error
        }
    }

    private func cacheKey(for url: URL, maxPixelSize: CGFloat?) -> String {
        if let maxPixelSize {
            return "\(url.absoluteString)#\(Int(maxPixelSize.rounded()))"
        }
        return "\(url.absoluteString)#full"
    }

    private static func decode(_ data: Data, maxPixelSize: CGFloat?) -> UIImage? {
        guard let maxPixelSize else { return UIImage(data: data) }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return UIImage(data: data)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    private static func cost(of image: UIImage) -> Int {
        let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
        return pixels * 4
    }
}

struct CachedPhotoImage<Placeholder: View>: View {
    let url: URL
    let maxPixelSize: CGFloat?
    let contentMode: ContentMode
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    private var taskID: String {
        "\(url.absoluteString)#\(maxPixelSize.map { String(Int($0.rounded())) } ?? "full")"
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: taskID) {
            image = nil
            failed = false
            do {
                let loaded = try await PhotoImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
                guard !Task.isCancelled else { return }
                image = loaded
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}

struct ZoomablePhotoImage: View {
    let url: URL
    @Binding var isZoomed: Bool
    let onSingleTap: () -> Void

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                NativeZoomableImageView(
                    image: image,
                    isZoomed: $isZoomed,
                    onSingleTap: onSingleTap
                )
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: url.absoluteString) {
            image = nil
            failed = false
            do {
                let loaded = try await PhotoImageCache.shared.image(for: url, maxPixelSize: nil)
                guard !Task.isCancelled else { return }
                image = loaded
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}

struct NativeZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .black
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        context.coordinator.imageView = imageView
        context.coordinator.configure(scrollView, with: image)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.image !== image else {
            context.coordinator.recenter(scrollView)
            return
        }
        context.coordinator.configure(scrollView, with: image)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: NativeZoomableImageView
        weak var imageView: UIImageView?
        var image: UIImage?

        init(parent: NativeZoomableImageView) {
            self.parent = parent
        }

        func configure(_ scrollView: UIScrollView, with image: UIImage) {
            self.image = image
            imageView?.image = image
            imageView?.frame = CGRect(origin: .zero, size: image.size)
            scrollView.contentSize = image.size
            updateZoomScales(scrollView)
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
            recenter(scrollView)
            parent.isZoomed = false
            DispatchQueue.main.async { [weak scrollView] in
                guard let scrollView else { return }
                self.updateZoomScales(scrollView)
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
                self.recenter(scrollView)
            }
        }

        func updateZoomScales(_ scrollView: UIScrollView) {
            guard let image else { return }
            let bounds = scrollView.bounds.size
            guard bounds.width > 0, bounds.height > 0, image.size.width > 0, image.size.height > 0 else { return }
            let minScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            scrollView.minimumZoomScale = minScale
            scrollView.maximumZoomScale = max(minScale * 4, minScale + 0.01)
        }

        func recenter(_ scrollView: UIScrollView) {
            updateZoomScales(scrollView)
            guard let imageView else { return }
            let bounds = scrollView.bounds.size
            let content = imageView.frame.size
            let horizontal = max((bounds.width - content.width) / 2, 0)
            let vertical = max((bounds.height - content.height) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            recenter(scrollView)
            parent.isZoomed = scrollView.zoomScale > scrollView.minimumZoomScale * 1.02
        }

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            parent.onSingleTap()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView, let imageView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale * 1.02 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let targetScale = min(scrollView.minimumZoomScale * 2.8, scrollView.maximumZoomScale)
                let size = CGSize(width: scrollView.bounds.width / targetScale, height: scrollView.bounds.height / targetScale)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

// MARK: - Models

struct RecapPhoto: Codable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let source: String
    let album: String
    let faces: [RecapFace]
    let slugs: [String]
    var url: URL { URL(string: "\(kBase)/\(path)")! }
}

struct RecapFace: Codable, Hashable {
    let name: String
    let score: Double
    let bbox: [Double]  // [x0,y0,x1,y1] in original image pixels
}

struct RecapCategoryNode: Codable, Hashable, Identifiable {
    var id: String { slug }
    let name: String
    let slug: String
    let albums: [RawAlbum]?
    let subcategories: [RecapCategoryNode]?
    var isLeaf: Bool { albums != nil }
    struct RawAlbum: Codable, Hashable {}
}

struct RecapPerson: Codable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let display_name: String?
    let count: Int
    var displayName: String { display_name ?? name }
}

enum PeopleMode: String, CaseIterable {
    case any = "Any person"
    case all = "All people"
}

private struct PeopleResponse: Codable {
    let people: [RecapPerson]; let slugs: [String: [String]]
}
private struct CategoriesResponse: Codable {
    let tree: [RecapCategoryNode]
}

// MARK: - Data model

enum CheckState { case on, off, mid }

@Observable
final class PhotosModel {
    var photos:     [RecapPhoto]        = []
    var categories: [RecapCategoryNode] = []
    var people:     [RecapPerson]       = []

    var selectedSlugs:  Set<String>    = []
    var selectedPeople: Set<String>    = []   // person .name values
    var peopleMode:     PeopleMode     = .any
    var peopleQuery     = ""
    var isLoading       = true
    var loadError       = false

    // ── Derived ─────────────────────────────────────────────────────────────

    var slugToName: [String: String] {
        var map: [String: String] = [:]
        func walk(_ nodes: [RecapCategoryNode]) {
            for n in nodes { map[n.slug] = n.name; walk(n.subcategories ?? []) }
        }
        walk(categories)
        return map
    }

    var filteredPhotos: [RecapPhoto] {
        var result = photos
        if !selectedSlugs.isEmpty {
            result = result.filter { p in p.slugs.contains(where: { selectedSlugs.contains($0) }) }
        }
        if !selectedPeople.isEmpty {
            let valid: (RecapPhoto, String) -> Bool = { photo, name in
                photo.faces.contains { $0.name == name && $0.score >= kThreshold }
            }
            switch peopleMode {
            case .any: result = result.filter { p in selectedPeople.contains(where: { valid(p, $0) }) }
            case .all: result = result.filter { p in selectedPeople.allSatisfy { valid(p, $0) } }
            }
        }
        return result
    }

    var filteredPeople: [RecapPerson] {
        let q = peopleQuery.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return people.filter { $0.name.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
    }

    var activeFilterCount: Int {
        (selectedSlugs.isEmpty ? 0 : 1) + (selectedPeople.isEmpty ? 0 : 1)
    }

    // ── Loading ──────────────────────────────────────────────────────────────

    func load() async {
        async let ph   = fetch([RecapPhoto].self,       from: "\(kBase)/index/photos.json")
        async let cats = fetch(CategoriesResponse.self,  from: "\(kBase)/index/categories.json")
        async let ppl  = fetch(PeopleResponse.self,      from: "\(kBase)/index/people.json")
        do {
            let (p, c, pp) = try await (ph, cats, ppl)
            photos = p; categories = c.tree; people = pp.people
        } catch { loadError = true }
        isLoading = false
    }

    func clearFilters() { selectedSlugs.removeAll(); selectedPeople.removeAll() }

    // ── Category tree helpers ────────────────────────────────────────────────

    func slugsForNode(_ node: RecapCategoryNode) -> Set<String> {
        node.isLeaf ? [node.slug] : (node.subcategories ?? []).reduce(into: Set()) { $0.formUnion(slugsForNode($1)) }
    }
    func nodeState(_ node: RecapCategoryNode) -> CheckState {
        let leaves = slugsForNode(node)
        let sel    = leaves.filter { selectedSlugs.contains($0) }
        return sel.isEmpty ? .off : sel.count == leaves.count ? .on : .mid
    }
    func toggleNode(_ node: RecapCategoryNode) {
        let leaves = slugsForNode(node)
        if nodeState(node) == .on { selectedSlugs.subtract(leaves) }
        else                      { selectedSlugs.formUnion(leaves) }
    }
    func selectAll() {
        func collect(_ nodes: [RecapCategoryNode]) -> Set<String> {
            nodes.reduce(into: Set()) { s, n in
                if n.isLeaf { s.insert(n.slug) }
                else { s.formUnion(collect(n.subcategories ?? [])) }
            }
        }
        selectedSlugs = collect(categories)
    }

    private func fetch<T: Decodable>(_ t: T.Type, from s: String) async throws -> T {
        let (data, _) = try await URLSession.shared.data(from: URL(string: s)!)
        return try JSONDecoder().decode(t, from: data)
    }
}

// MARK: - Root

struct RecapPhotosView: View {
    @State private var model = PhotosModel()
    @State private var detailTarget: PhotoTarget? = nil
    @State private var showFilters  = false
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if hSizeClass == .regular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .task { await model.load() }
        .fullScreenCover(item: $detailTarget) { target in
            let photos = model.filteredPhotos
            let initialIdx = photos.firstIndex { $0.path == target.path } ?? 0
            PhotoDetailView(
                photos:     photos,
                initialIdx: initialIdx,
                slugToName: model.slugToName
            )
        }
    }

    // ── iPhone ───────────────────────────────────────────────────────────────

    private var iPhoneLayout: some View {
        NavigationStack {
            PhotosGrid(model: model, onTap: { detailTarget = PhotoTarget(path: $0.path) })
                .navigationTitle(gridTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left").fontWeight(.semibold)
                        }
                        .accessibilityLabel("Back")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showFilters = true } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                        }
                        .accessibilityLabel("Filters")
                    }
                }
        }
        .sheet(isPresented: $showFilters) {
            FiltersSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // ── iPad ─────────────────────────────────────────────────────────────────

    private var iPadLayout: some View {
        NavigationSplitView {
            iPadSidebar
        } detail: {
            PhotosGrid(model: model, onTap: { detailTarget = PhotoTarget(path: $0.path) })
                .navigationTitle(gridTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left").fontWeight(.semibold)
                        }
                        .accessibilityLabel("Back")
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var iPadSidebar: some View {
        FiltersSidebarContent(model: model)
            .navigationTitle("Filters")
    }

    private var gridTitle: String {
        "Photos"
    }
}

private struct PhotoTarget: Identifiable {
    let path: String
    var id: String { path }
}

// MARK: - Filters sheet (iPhone)

struct FiltersSheet: View {
    @Bindable var model: PhotosModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FiltersSidebarContent(model: model)
                .navigationTitle("Filters")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                        }
                            .foregroundStyle(kAccent)
                            .accessibilityLabel("Done")
                    }
                }
        }
    }
}

// Shared sidebar / filter content (used in both sheet and iPad sidebar)
struct FiltersSidebarContent: View {
    @Bindable var model: PhotosModel

    var body: some View {
        List {
            // ── People ────────────────────────────────────────────────────
            Section {
                // Selected people chips
                if !model.selectedPeople.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(model.selectedPeople).sorted(), id: \.self) { name in
                                let display = model.people.first(where: { $0.name == name })?.displayName ?? name
                                HStack(spacing: 4) {
                                    Text(display).font(.subheadline.weight(.medium))
                                    Button { withAnimation { _ = model.selectedPeople.remove(name) } } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.hierarchical)
                                    }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background { Capsule().fill(kAccent.opacity(0.12)) }
                                .foregroundStyle(kAccent)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))

                    // AND / OR mode picker (shown when 2+ people selected)
                    if model.selectedPeople.count >= 2 {
                        Picker("Match mode", selection: $model.peopleMode) {
                            ForEach(PeopleMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }

                // Search field
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search people", text: $model.peopleQuery)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                // People list
                let shown = model.filteredPeople
                if shown.isEmpty && !model.peopleQuery.isEmpty {
                    Text("No results").foregroundStyle(.secondary)
                } else if shown.isEmpty {
                    Text("Search to add people")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shown) { person in
                        let selected = model.selectedPeople.contains(person.name)
                        Button {
                            withAnimation {
                                if selected { model.selectedPeople.remove(person.name) }
                                else        { model.selectedPeople.insert(person.name) }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.displayName)
                                        .foregroundStyle(selected ? kAccent : .primary)
                                    if person.display_name != nil {
                                        Text(person.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(person.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                if selected {
                                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(kAccent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("People").textCase(nil)
            }

            // ── Categories ────────────────────────────────────────────────
            Section {
                ForEach(model.categories) { cat in
                    CategoryNodeRow(node: cat, model: model)
                }
            } header: {
                HStack {
                    Text("Categories")
                    Spacer()
                    Button("Reset") { withAnimation { model.selectedSlugs.removeAll() } }
                        .font(.caption.weight(.semibold)).foregroundStyle(kAccent)
                        .disabled(model.selectedSlugs.isEmpty)
                }
                .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
    }
}

// Recursive category row
struct CategoryNodeRow: View {
    let node: RecapCategoryNode
    @Bindable var model: PhotosModel
    @State private var expanded = false
    private var state: CheckState { model.nodeState(node) }

    var body: some View {
        if node.isLeaf {
            Button { withAnimation { model.toggleNode(node) } } label: {
                Label { Text(node.name).foregroundStyle(state == .on ? kAccent : .primary) }
                      icon: { CheckCircleView(state: state) }
            }.buttonStyle(.plain)
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.subcategories ?? []) { child in
                    CategoryNodeRow(node: child, model: model)
                }
            } label: {
                Button { withAnimation { model.toggleNode(node) } } label: {
                    Label {
                        Text(node.name).fontWeight(.semibold)
                            .foregroundStyle(state == .on ? kAccent : state == .mid ? kAccent.opacity(0.7) : .primary)
                    } icon: { CheckCircleView(state: state) }
                }.buttonStyle(.plain)
            }
        }
    }
}

struct CheckCircleView: View {
    let state: CheckState
    var body: some View {
        ZStack {
            Circle().fill(state == .off ? .clear : kAccent)
            Circle().strokeBorder(state == .off ? Color(uiColor: .tertiaryLabel) : kAccent, lineWidth: 1.5)
            if state == .on  { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
            if state == .mid { Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - Photo grid

struct PhotosGrid: View {
    let model: PhotosModel
    let onTap: (RecapPhoto) -> Void
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var columns: [GridItem] {
        let count = hSizeClass == .regular ? 4 : 3
        return Array(repeating: GridItem(.flexible(), spacing: 2), count: count)
    }

    var body: some View {
        let photos = model.filteredPhotos
        ScrollView {
            if model.isLoading {
                VStack(spacing: 14) {
                    ProgressView().tint(kAccent).controlSize(.large)
                    Text("Loading photos…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 100)
            } else if model.loadError {
                VStack(spacing: 14) {
                    Image(systemName: "wifi.slash").font(.system(size: 48)).foregroundStyle(.quaternary)
                    Text("Couldn't load photos").font(.headline)
                    Text("Check your connection.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 100)
            } else if photos.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 52)).foregroundStyle(.quaternary)
                    Text("No Photos").font(.headline)
                    Text("Try adjusting your filters.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 100)
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(photos) { photo in
                        PhotoCell(url: photo.url)
                            .id(photo.path)
                            .onTapGesture { onTap(photo) }
                    }
                }
            }
        }
    }
}

struct PhotoCell: View {
    let url: URL
    var body: some View {
        // GeometryReader to measure width → enforce 3:2 height
        Color.clear
            .aspectRatio(3/2, contentMode: .fit)
            .overlay {
                CachedPhotoImage(url: url, maxPixelSize: 520, contentMode: .fill) {
                    Color(uiColor: .tertiarySystemFill)
                        .overlay { ProgressView().controlSize(.small) }
                }
                .clipped()
            }
            .clipped()
    }
}

// MARK: - Photo detail viewer

struct PhotoDetailView: View {
    let photos: [RecapPhoto]
    let initialIdx: Int
    let slugToName: [String: String]
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    @State private var navDir  = NavDir.fwd
    @State private var isZoomed = false

    // Live drag gesture
    @State private var dragMode: PhotoDragMode? = nil
    @State private var dragOffset: CGSize = .zero
    @State private var isCompletingPageTurn = false
    @State private var viewportSize: CGSize = .zero

    // UI
    @State private var chromeVisible  = true
    @State private var chromeTask: Task<Void, Never>? = nil

    // Loaded image (for share)
    @State private var loadedImage:  UIImage? = nil
    @State private var loadedPath:   String?  = nil
    @State private var sharingBusy   = false
    @State private var shareItem:    ShareImageItem? = nil

    // Filmstrip scroll position (two-way binding drives live photo changes)
    @State private var filmId: Int? = nil

    init(photos: [RecapPhoto], initialIdx: Int, slugToName: [String: String]) {
        self.photos = photos; self.initialIdx = initialIdx; self.slugToName = slugToName
        self._index  = State(initialValue: initialIdx)
        self._filmId = State(initialValue: initialIdx)
    }

    private var photo: RecapPhoto { photos[index] }
    private var topChromeInset: CGFloat {
        0
    }
    private var leadingChromeInset: CGFloat {
        0
    }

    // ── Navigation ───────────────────────────────────────────────────────────

    private func navigate(to target: Int, dir: NavDir? = nil, animated: Bool = true) {
        guard target >= 0, target < photos.count, target != index else { return }
        navDir = dir ?? (target > index ? .fwd : .bwd)
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) { index = target }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { index = target }
        }
        filmId = target
        isZoomed = false
    }

    // ── Chrome auto-hide ─────────────────────────────────────────────────────

    private func pingChrome() {
        chromeTask?.cancel()
        chromeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { chromeVisible = false }
        }
    }

    // ── Category label ────────────────────────────────────────────────────────

    private var categoryLabel: String {
        // Look up each slug in reverse — most specific category name wins
        for slug in photo.slugs.reversed() {
            if let name = slugToName[slug] { return name }
        }
        // Fallback: humanize the last slug component
        return photo.slugs.last?.components(separatedBy: "/").last?
            .replacingOccurrences(of: "-", with: " ")
            .capitalized ?? ""
    }

    // ── Body ─────────────────────────────────────────────────────────────────

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    ZStack {
                        photoPager(size: geo.size)
                        .opacity(dragOffset.height > 0 ? max(0.3, 1 - dragOffset.height / 250) : 1)
                        .scaleEffect(dragOffset.height > 0 ? max(0.88, 1 - dragOffset.height / 800) : 1, anchor: .center)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .simultaneousGesture(navigationDrag)
                    .onAppear { viewportSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in viewportSize = newSize }

                    if chromeVisible {
                        filmstripView
                            .frame(height: kFilmH)
                            .background(.black.opacity(0.6))
                            .background(.ultraThinMaterial.opacity(0.5))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }

            // ── Chrome overlays ───────────────────────────────────────────────
            if chromeVisible {
                VStack {
                    topBarView
                        .padding(.top, topChromeInset)
                        .padding(.leading, leadingChromeInset)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden()
        .sheet(item: $shareItem) { item in ShareSheet(image: item.image) }
        .onAppear {
            filmId = index
            pingChrome()
        }
        .onChange(of: chromeVisible) { _, visible in
            if visible { pingChrome() }
        }
    }

    // ── Gestures ──────────────────────────────────────────────────────────────

    private func photoPager(size: CGSize) -> some View {
        ZStack {
            ForEach(visiblePageIndices, id: \.self) { pageIndex in
                photoPage(for: pageIndex, size: size)
                    .offset(x: pageOffset(for: pageIndex, width: size.width), y: pageVerticalOffset)
            }
        }
    }

    private var visiblePageIndices: [Int] {
        var result = [index]
        if index > 0 { result.append(index - 1) }
        if index < photos.count - 1 { result.append(index + 1) }
        return result
    }

    private var pageVerticalOffset: CGFloat {
        max(0, dragOffset.height)
    }

    private func pageOffset(for pageIndex: Int, width: CGFloat) -> CGFloat {
        return CGFloat(pageIndex - index) * width + dragOffset.width
    }

    private func photoPage(for pageIndex: Int, size: CGSize) -> some View {
        ZoomablePhotoImage(
            url: photos[pageIndex].url,
            isZoomed: pageIndex == index ? $isZoomed : .constant(false),
            onSingleTap: toggleChrome
        )
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(pageIndex == index)
    }

    // Single DragGesture handles horizontal navigation and dismiss; zoomed image panning is native UIScrollView.
    private var navigationDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isCompletingPageTurn, !isZoomed else { return }
                let dx = value.translation.width
                let dy = value.translation.height

                if dragMode == nil {
                    if abs(dx) > abs(dy), abs(dx) > 8, canSwipe(dx) {
                        dragMode = .swipe
                    } else if dy > 0, abs(dy) > 8 {
                        dragMode = .dismiss
                    }
                }

                switch dragMode {
                case .swipe:
                    dragOffset = CGSize(width: constrainedSwipeOffset(dx), height: 0)
                case .dismiss:
                    dragOffset = CGSize(width: 0, height: max(0, dy))
                case nil:
                    break
                }
            }
            .onEnded { value in
                guard !isZoomed else {
                    finishDrag()
                    return
                }
                let dx = value.translation.width
                let dy = value.translation.height
                let vx = value.velocity.width
                let vy = value.velocity.height

                switch dragMode {
                case .swipe:
                    if dx < -60 || vx < -500 { completeSwipe(to: index + 1, dir: .fwd) }
                    else if dx > 60 || vx > 500 { completeSwipe(to: index - 1, dir: .bwd) }
                    else { finishDrag() }
                case .dismiss:
                    if dy > 120 || vy > 600 { dismiss() }
                    finishDrag()
                case nil:
                    finishDrag()
                }
            }
    }

    private func toggleChrome() {
        let willShow = !chromeVisible
        withAnimation(.easeInOut(duration: 0.18)) { chromeVisible = willShow }
        if willShow { pingChrome() }
    }

    private func keepChromeVisible() {
        chromeTask?.cancel()
        if !chromeVisible {
            withAnimation(.easeInOut(duration: 0.18)) { chromeVisible = true }
        }
        pingChrome()
    }

    private func canSwipe(_ dx: CGFloat) -> Bool {
        (dx < 0 && index < photos.count - 1) || (dx > 0 && index > 0)
    }

    private func constrainedSwipeOffset(_ dx: CGFloat) -> CGFloat {
        guard canSwipe(dx) else { return dx * 0.18 }
        return dx
    }

    private func finishDrag() {
        dragMode = nil
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            dragOffset = .zero
        }
    }

    private func completeSwipe(to target: Int, dir: NavDir) {
        guard target >= 0, target < photos.count else {
            finishDrag()
            return
        }

        isCompletingPageTurn = true
        let pageWidth = max(viewportSize.width, 1)
        let destinationX = dir == .fwd ? -pageWidth : pageWidth
        withAnimation(.easeOut(duration: 0.18)) {
            dragOffset = CGSize(width: destinationX, height: 0)
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            navDir = dir
            index = target
            filmId = target
            isZoomed = false
            dragMode = nil
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dragOffset = .zero
            }
            isCompletingPageTurn = false
        }
    }

    // ── Sub-views ─────────────────────────────────────────────────────────────

    private var topBarView: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityLabel("Close")

            Text(categoryLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { Task { await triggerShare() } } label: {
                ZStack {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .opacity(sharingBusy ? 0 : 1)
                    if sharingBusy { ProgressView().controlSize(.small).tint(.white) }
                }
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .disabled(sharingBusy)
            .accessibilityLabel("Share photo")
        }
        .padding(.horizontal, 18)
        .padding(.top, 8).padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    // ── Filmstrip scrubber ────────────────────────────────────────────────────

    private var filmstripView: some View {
        ScrollViewReader { proxy in
            GeometryReader { geo in
                let thumbW: CGFloat = 58.5
                let thumbH: CGFloat = 40.5
                let margin = max(0, (geo.size.width - thumbW) / 2)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 4) {
                        ForEach(Array(photos.enumerated()), id: \.element.path) { idx, photo in
                            CachedPhotoImage(url: photo.url, maxPixelSize: 180, contentMode: .fill) {
                                Color.white.opacity(0.07)
                            }
                            .frame(width: thumbW, height: thumbH)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(idx == index ? kAccent : .clear, lineWidth: 2)
                            )
                            .opacity(idx == index ? 1 : 0.45)
                            .scaleEffect(idx == index ? 1 : 0.94)
                            .animation(.easeInOut(duration: 0.15), value: idx == index)
                            .id(idx)
                            .onTapGesture {
                                keepChromeVisible()
                                navigate(to: idx, animated: false)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in keepChromeVisible() }
                        .onEnded { _ in keepChromeVisible() }
                )
                .contentMargins(.horizontal, margin, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $filmId, anchor: .center)
                // Scrolling the filmstrip immediately drives the displayed photo
                .onChange(of: filmId) { _, newId in
                    keepChromeVisible()
                    if let id = newId, id != index { navigate(to: id, animated: false) }
                }
                .onChange(of: index) { _, newIdx in
                    if filmId != newIdx {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            filmId = newIdx
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
                .onAppear {
                    filmId = index
                    DispatchQueue.main.async {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }

    // ── Share ─────────────────────────────────────────────────────────────────

    private func triggerShare() async {
        sharingBusy = true; defer { sharingBusy = false }
        if loadedPath == photo.path, let img = loadedImage {
            shareItem = ShareImageItem(image: img); return
        }
        guard let img = try? await PhotoImageCache.shared.image(for: photo.url, maxPixelSize: nil) else { return }
        loadedImage = img; loadedPath = photo.path
        shareItem = ShareImageItem(image: img)
    }
}

enum NavDir { case fwd, bwd }
private enum PhotoDragMode { case swipe, dismiss }

struct ShareImageItem: Identifiable {
    let id = UUID(); let image: UIImage
}
