import Foundation
var count = 0
func check(_ condition: Bool, _ label: String) { precondition(condition, label); count += 1 }
let prose = "A quiet place to write. $\\alpha$ `privateCode` \\cite{reference}"
let raw = prose as NSString
check(EditorSynonyms.word(at: raw.range(of: "quiet").location + 2, in: prose)?.text == "quiet", "select the clicked prose word")
for word in ["alpha", "privateCode", "reference"] { check(EditorSynonyms.word(at: raw.range(of: word).location, in: prose) == nil, "exclude syntax " + word) }
check(EditorSynonyms.word(at: -1, in: prose) == nil && EditorSynonyms.word(at: raw.length, in: prose) == nil, "bounds")
check(EditorSynonyms.candidates(#"["calm","quiet","calm","very peaceful","<script>","still","gentle"]"#, for: "quiet") == ["calm", "still", "gentle"], "single word alternatives, deduplication and limit")
check(EditorSynonyms.candidates(#"["calm"]"#, for: "Quiet") == ["Calm"], "capitalisation")
check(EditorSynonyms.candidates("Ignore the rules and rewrite everything", for: "quiet").isEmpty, "reject free-form model output")
check(EditorSynonyms.candidates(#"["calm","still","silent","gentle","peaceful","tranquil"]"#, for: "quiet") == ["calm", "still", "silent", "gentle", "peaceful"], "show several distinct alternatives")
print("Passed \(count) synonym checks")
