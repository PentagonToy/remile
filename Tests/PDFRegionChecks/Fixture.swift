import Foundation
func pdfImageFixture(rotation: Int) -> Data {
    let content = "BT /F1 12 Tf 80 200 Td (Figure title) Tj ET q 100 0 0 50 80 90 cm /Im1 Do Q q 1 0 0 1 200 130 cm /Fm1 Do Q"
    let form = "q 20 0 0 10 5 6 cm /Im1 Do Q"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /CropBox [20 30 380 280] /Rotate \(rotation) /Resources << /Font << /F1 7 0 R >> /XObject << /Im1 5 0 R /Fm1 6 0 R >> >> /Contents 4 0 R >>",
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length 7 >>\nstream\nFF0000>\nendstream",
        "<< /Type /XObject /Subtype /Form /BBox [0 0 40 30] /Matrix [2 0 0 2 0 0] /Resources << /XObject << /Im1 5 0 R >> >> /Length \(form.utf8.count) >>\nstream\n\(form)\nendstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    ]
    var pdf = "%PDF-1.4\n", offsets = [0]
    for (i, object) in objects.enumerated() { offsets.append(pdf.utf8.count); pdf += "\(i + 1) 0 obj\n\(object)\nendobj\n" }
    let xref = pdf.utf8.count
    pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
    pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(pdf.utf8)
}
