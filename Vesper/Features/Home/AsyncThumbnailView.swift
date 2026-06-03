//
//  AsyncThumbnailView.swift
//  Vesper
//
//  Decodes JPEG thumbnail data off the main thread so home screen
//  rendering never hitches when reference photos are present.
//

import SwiftUI

struct AsyncThumbnailView: View {
    let data: Data

    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
            }
        }
        .task(id: data) {
            // Decode on a background thread — UIImage(data:) is not free
            let decoded = await Task.detached(priority: .utility) {
                UIImage(data: data)
            }.value
            image = decoded
        }
    }
}
