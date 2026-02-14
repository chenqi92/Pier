import SwiftUI

/// ER (Entity-Relationship) diagram view for database table visualization.
struct ERDiagramView: View {
    let tables: [ERTable]

    /// A table in the ER diagram.
    struct ERTable: Identifiable {
        let id = UUID()
        let name: String
        let columns: [ERColumn]
        var position: CGPoint = .zero
    }

    struct ERColumn: Identifiable {
        let id = UUID()
        let name: String
        let type: String
        let isPrimaryKey: Bool
        let foreignKey: ERForeignKey?
    }

    struct ERForeignKey {
        let referencedTable: String
        let referencedColumn: String
    }

    @State private var positions: [UUID: CGPoint] = [:]
    @State private var dragOffset: CGSize = .zero
    @State private var draggingTable: UUID?
    @State private var scale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "diagram")
                    .foregroundColor(.purple)
                    .font(.caption)
                Text(LS("er.title"))
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()

                // Zoom controls
                Button(action: { withAnimation { scale = max(0.5, scale - 0.1) } }) {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Text(String(format: "%.0f%%", scale * 100))
                    .font(.system(size: 9))
                    .frame(width: 32)

                Button(action: { withAnimation { scale = min(2.0, scale + 0.1) } }) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if tables.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "diagram")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text(LS("er.noTables"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        // Relationship lines
                        relationshipLines

                        // Table boxes
                        ForEach(tables) { table in
                            tableBox(table)
                                .position(tablePosition(table))
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            positions[table.id] = CGPoint(
                                                x: (positions[table.id] ?? tablePosition(table)).x + value.translation.width - dragOffset.width,
                                                y: (positions[table.id] ?? tablePosition(table)).y + value.translation.height - dragOffset.height
                                            )
                                            dragOffset = value.translation
                                            draggingTable = table.id
                                        }
                                        .onEnded { _ in
                                            dragOffset = .zero
                                            draggingTable = nil
                                        }
                                )
                        }
                    }
                    .scaleEffect(scale)
                    .frame(minWidth: 800, minHeight: 600)
                }
            }
        }
        .onAppear { initializePositions() }
    }

    // MARK: - Table Box

    private func tableBox(_ table: ERTable) -> some View {
        VStack(spacing: 0) {
            // Table name header
            HStack {
                Image(systemName: "tablecells")
                    .font(.system(size: 8))
                Text(table.name)
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(0.15))

            Divider()

            // Columns
            VStack(alignment: .leading, spacing: 2) {
                ForEach(table.columns) { column in
                    HStack(spacing: 4) {
                        if column.isPrimaryKey {
                            Image(systemName: "key.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.yellow)
                        } else if column.foreignKey != nil {
                            Image(systemName: "link")
                                .font(.system(size: 7))
                                .foregroundColor(.blue)
                        } else {
                            Color.clear.frame(width: 8)
                        }

                        Text(column.name)
                            .font(.system(size: 9))

                        Spacer()

                        Text(column.type)
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(width: 180)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(draggingTable == table.id ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }

    // MARK: - Relationship Lines

    private var relationshipLines: some View {
        Canvas { context, _ in
            for table in tables {
                let srcPos = tablePosition(table)

                for column in table.columns {
                    guard let fk = column.foreignKey else { continue }
                    guard let targetTable = tables.first(where: { $0.name == fk.referencedTable }) else { continue }
                    let dstPos = tablePosition(targetTable)

                    var path = Path()
                    path.move(to: CGPoint(x: srcPos.x + 90, y: srcPos.y))
                    path.addLine(to: CGPoint(x: dstPos.x - 90, y: dstPos.y))

                    context.stroke(path, with: .color(.blue.opacity(0.5)), lineWidth: 1.5)

                    // Arrow head
                    let dx = dstPos.x - 90 - (srcPos.x + 90)
                    let dy = dstPos.y - srcPos.y
                    let angle = atan2(dy, dx)
                    let arrowLen: CGFloat = 8
                    let arrowPoint = CGPoint(x: dstPos.x - 90, y: dstPos.y)

                    var arrow = Path()
                    arrow.move(to: arrowPoint)
                    arrow.addLine(to: CGPoint(
                        x: arrowPoint.x - arrowLen * cos(angle - .pi / 6),
                        y: arrowPoint.y - arrowLen * sin(angle - .pi / 6)
                    ))
                    arrow.move(to: arrowPoint)
                    arrow.addLine(to: CGPoint(
                        x: arrowPoint.x - arrowLen * cos(angle + .pi / 6),
                        y: arrowPoint.y - arrowLen * sin(angle + .pi / 6)
                    ))
                    context.stroke(arrow, with: .color(.blue.opacity(0.5)), lineWidth: 1.5)
                }
            }
        }
    }

    // MARK: - Layout

    private func tablePosition(_ table: ERTable) -> CGPoint {
        if let pos = positions[table.id] { return pos }
        return table.position
    }

    private func initializePositions() {
        let columns = 3
        let spacingX: CGFloat = 250
        let spacingY: CGFloat = 200

        for (idx, table) in tables.enumerated() {
            let col = idx % columns
            let row = idx / columns
            let x = CGFloat(col) * spacingX + 120
            let y = CGFloat(row) * spacingY + 100
            positions[table.id] = CGPoint(x: x, y: y)
        }
    }
}
