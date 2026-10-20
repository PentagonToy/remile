import Foundation

extension LibraryHit {
    var assistantPassage: AssistantPassage {
        AssistantPassage(location: AssistantLocation(path: path, unit: page, label: location), text: excerpt)
    }
}
