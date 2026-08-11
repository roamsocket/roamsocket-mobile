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
            // The picker only exposes a UIImage; encode to JPEG data once (a
            // single full-bitmap pass) so the VM can downsample via ImageIO
            // instead of decoding the 12 MP frame multiple times.
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 1.0)
            else { return }
            parent.onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}
