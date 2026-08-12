import SwiftUI
import PhotosUI
import UIKit

/// PHPicker-backed gallery picker. Hands back JPEG `Data` for each selected
/// photo so the view model can downsample via ImageIO without ever holding a
/// full bitmap. Multiple selection enabled so the user can stage several
/// vision items before Send.
///
/// PHPicker runs out-of-process — no Photos permission prompt needed on
/// iOS 14+. (We still declare `NSPhotoLibraryUsageDescription` for the few
/// legacy paths that hand back file URLs and for App Review transparency.)
struct GalleryPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    /// Maximum number of items the picker will let the user select at once.
    /// Mirrored in `ChatViewModel.maxAttachedImages` so the composer can also
    /// tell the user why the button is grey before they even open the picker.
    var selectionLimit: Int
    var onPicked: ([Data]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        // JPEG/PNG/HEIC all accepted at the picker layer — we re-encode to
        // JPEG on our own downsampling path so a 30 MB DNG never reaches the
        // Anthropic-compat vision endpoint (that's exactly what causes the
        // upstream `input_tokens` pre-count to time out and abort the turn).
        config.filter = .images
        config.selectionLimit = selectionLimit
        // `.current` keeps the original asset (no iCloud HDR re-encode) so we
        // can decide locally how to downsample — see the long comment on
        // `preferredAssetRepresentationMode` in the Apple devforums thread.
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: GalleryPicker

        init(_ parent: GalleryPicker) {
            self.parent = parent
        }

        func pickerController(
            _ controller: PHPickerViewController,
            didFinishPicking results: [PHPickerResult]
        ) {
            parent.isPresented = false
            guard !results.isEmpty else { return }

            // DispatchGroup lets us fan out the per-item async loads and only
            // invoke `onPicked` once every payload has resolved. `loadData`
            // is genuinely async — a busy-wait on a semaphore would block the
            // main runloop and risk a watchdog kill. Using a group + lock-
            // guarded array is the canonical pattern for "wait for N async
            // loads."
            //
            // Each provider load runs on its own autoreleasepool-scoped
            // background queue so the Data buffer for photo N is reclaimable
            // before photo N+1's load starts. Without this, four 12 MP DNGs
            // would coexist in RAM for the full loop duration.
            let group = DispatchGroup()
            let lock = NSLock()
            var payloads: [Data] = []
            payloads.reserveCapacity(results.count)

            for result in results {
                let provider = result.itemProvider
                let identifiers = provider.registeredTypeIdentifiers
                // Prefer JPEG, then PNG, then HEIC, then any image. The
                // picker can hand back several representations and we want
                // the smallest one that doesn't need re-encoding.
                let preferred: [String] = [
                    "public.jpeg",
                    "public.png",
                    "public.heic",
                    "public.image",
                ]
                let chosen = preferred.first { identifiers.contains($0) }
                    ?? identifiers.first

                guard let typeID = chosen else { continue }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    autoreleasepool {
                        provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
                            defer { group.leave() }
                            guard let data, !data.isEmpty else { return }
                            lock.lock()
                            payloads.append(data)
                            lock.unlock()
                        }
                    }
                }
            }

            // Wait for every load to settle, then hand the bundle to the VM
            // on the main actor. `group.notify` is the right primitive here —
            // it never blocks the current queue and fires on the queue of
            // choice once `enter()`/`leave()` pairs balance out.
            group.notify(queue: .main) { [weak self] in
                guard !payloads.isEmpty else { return }
                self?.parent.onPicked(payloads)
            }
        }
    }
}
