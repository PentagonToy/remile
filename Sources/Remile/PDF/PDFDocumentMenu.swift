import AppKit
import SwiftUI

struct PDFDocumentMenu: View {
    var reader: ReadingSession?
    @ObservedObject var zoom: ReaderZoom
    let compact: Bool
    let showsOverview: Bool
    @State private var applications: [PDFFileAccess.Application] = []

    var body: some View {
        Menu {
            if compact {
                ReaderZoomMenuItems(zoom: zoom).disabled(showsOverview)
                if reader?.url != nil { Divider() }
            }
            if let reader, let url = reader.url {
                Menu("Open With") {
                    ForEach(applications) { application in
                        Button(application.name) { reader.openPDF(in: application.url) }
                    }
                    if applications.isEmpty { Text("No other PDF apps").disabled(true) }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Divider()
                Button("Reload PDF…") { reader.reloadPDFFile() }
            }
        } label: {
            SymbolIcon(systemName: "ellipsis")
                .frame(width: RemileControl.toolHit, height: RemileControl.toolHit)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel("PDF options").remileHelp("PDF options")
        .task(id: reader?.url) {
            applications = reader?.url.map(PDFFileAccess.applications(for:)) ?? []
        }
    }
}

struct PDFFileNotice: View {
    @ObservedObject var reader: ReadingSession

    var body: some View {
        if reader.pdfChangedOutside || reader.pdfFileError != nil {
            HStack(spacing: RemileControl.spacing) {
                Text(reader.pdfFileError ?? "This PDF changed in another app.")
                    .font(RemileType.caption).textSelection(.enabled)
                Spacer(minLength: RemileControl.spacing)
                if reader.pdfChangedOutside {
                    Button("Save a Copy…") { reader.saveCopy() }
                    Button("Reload…") { reader.reloadPDFFile() }
                } else {
                    Button("Dismiss") { reader.dismissPDFFileError() }
                }
            }
            .padding(RemileControl.spacing).background(RemileStyle.editorBar)
        }
    }
}
