import Foundation

enum WriterOptions {
    static var fonts: [RemileOption] { WriterFont.allCases.map { RemileOption(id: $0.rawValue, title: $0.rawValue, font: $0.family) } }
    static var spacing: [RemileOption] {
        [1.0, 1.15, 1.2, 1.5, 2.0].map {
            let value = String(format: "%g", $0)
            return RemileOption(id: value, title: $0 == 1 ? "1 · Single" : $0 == 2 ? "2 · Double" : value)
        }
    }
    static var lists: [RemileOption] {
        WriterList.allCases.map { value in
            let name: String, sample: String?
            switch value {
            case .none: name = "None"; sample = nil
            case .bullet: name = "Bullet"; sample = "•"
            case .dash: name = "Dash"; sample = "–"
            case .circle: name = "Circle"; sample = "○"
            case .square: name = "Square"; sample = "■"
            case .numbers: name = "Numbers"; sample = "1."
            case .letters: name = "Letters"; sample = "a."
            case .upperLetters: name = "Letters"; sample = "A."
            case .roman: name = "Roman"; sample = "i."
            case .upperRoman: name = "Roman"; sample = "I."
            }
            return RemileOption(id: value.rawValue, title: name, sample: sample, separator: value == .bullet || value == .numbers)
        }
    }

}
