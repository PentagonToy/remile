import SwiftUI

struct OverleafProjectIDButton: View {
    let project: OverleafConnection
    var body: some View {
        Button("Copy project ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(OverleafProjectID.reference(project.projectID), forType: .string)
        }
    }
}
