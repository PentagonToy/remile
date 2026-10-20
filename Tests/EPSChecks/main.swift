import Foundation
let output = URL(fileURLWithPath: CommandLine.arguments[1]), source = output.appendingPathComponent("Original")
try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
let eps = "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 32 32\nnewpath 0 0 moveto 32 32 lineto 2 setlinewidth stroke\nshowpage\n%%EOF\n"
let tex = "\\documentclass{article}\n\\usepackage{graphicx}\n\\begin{document}\n\\includegraphics{figure.eps}\n\\end{document}\n"
try eps.write(to: source.appendingPathComponent("figure.eps"), atomically: true, encoding: .utf8)
try tex.write(to: source.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
let result = try TeXCompileJob().run(root: source, main: "main.tex", buffers: ["main.tex": tex], configuration: .current, output: output.appendingPathComponent("Compiled"))
try result.log.write(to: output.appendingPathComponent("compiler.log"), atomically: true, encoding: .utf8)
precondition(result.success && result.pdf != nil)
let original = try String(contentsOf: source.appendingPathComponent("figure.eps"), encoding: .utf8)
precondition(original == eps)
precondition(!FileManager.default.fileExists(atPath: source.appendingPathComponent("figure-eps-converted-to.pdf").path))
precondition(FileManager.default.fileExists(atPath: output.appendingPathComponent("Compiled/Source/figure-eps-converted-to.pdf").path))
print("Passed restricted EPS preparation: compiled PDF, unchanged original and build-only converted graphics")
