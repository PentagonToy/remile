import SwiftUI

struct MarkdownSettings: View {
    @AppStorage("markdown.lineNumbers") private var numbers = false
    @AppStorage("markdown.fontSize") private var size = 18.0
    @AppStorage("markdown.spellcheck") private var spelling = true
    @AppStorage("markdown.livePreview") private var live = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Editor settings").font(RemileType.heading)
            Toggle("Line numbers", isOn: $numbers)
            HStack { Text("Font size"); Spacer(); Stepper("\(Int(size))", value: $size, in: 11...32).frame(width: 115) }
            Toggle("Check spelling and grammar", isOn: $spelling)
            Toggle("Live preview", isOn: $live)
        }.padding(20).frame(width: 300).background(RemileStyle.background)
    }
}
