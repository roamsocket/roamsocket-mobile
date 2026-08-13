import SwiftUI
import UIKit

/// System camera presented from the chat composer. Hands back JPEG `Data` so
/// the view model can downsample via ImageIO without ever holding a full 12 MP
/// bitmap (critical when a Metal VLM is resident in memory).
struct CameraCapture: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onCapture: (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .rear
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: CameraCapture

        init(_ parent: CameraCapture) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.isPresented = false
            // The picker only exposes a UIImage; encode to JPEG data once at
            // medium quality so the VM can downsample via ImageIO instead of
            // decoding the 12 MP frame multiple times. Quality 1.0 here used
            // to ship a ~5 MB JPEG only to be re-decoded and re-encoded
            // moments later — a multi-MB allocator spike on top of a multi-GB
            // Metal VLM. 0.92 is visually indistinguishable for the resize
            // step that follows.
            //
            // autoreleasepool scopes the UIImage + intermediate JPEG buffer so
            // they get reclaimed before the (smaller, encoded) `data` is
            // handed to the VM. Without this, the 12 MP bitmap would linger
            // until the next runloop drain — a real OOM risk next to a
            // resident VLM.
            let payload: Data? = autoreleasepool {
                guard let image = info[.originalImage] as? UIImage else { return nil }
                return image.jpegData(compressionQuality: 0.92)
            }
            guard let data = payload else { return }
            parent.onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}
