import SwiftUI

struct PieceMapView: View {
    let pieces: [Bool]
    let columns: Int = 40
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Piece Map (\(pieces.count) pieces)")
                .font(.headline)
            
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(12), spacing: 2), count: columns), spacing: 2) {
                    ForEach(0..<pieces.count, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(pieces[index] ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 12, height: 12)
                            .help("Piece \(index)")
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: 300)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        }
    }
}
