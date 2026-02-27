import SwiftUI

struct BlackScreenOverlayView: View {
    var onTap: () -> Void

    var body: some View {
        Color.black
            .opacity(0.98)
            .ignoresSafeArea()
            .overlay(
                Text("Verbindung aktiv – zum Aufwecken tippen")
                    .foregroundColor(.white)
                    .padding()
            )
            .onTapGesture {
                onTap()
            }
    }
}

