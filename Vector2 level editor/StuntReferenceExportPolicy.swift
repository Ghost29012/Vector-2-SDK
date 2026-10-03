import Foundation

enum StuntReferenceExportPolicy {
    static func propertiesForExport(_ properties: XMLElement, referenceName: String, filename: String) -> XMLElement {
        let copy = properties.copy() as! XMLElement
        guard referenceName == "Stunt", filename == "triggers.xml" else { return copy }
        for staticNode in copy.elements(forName: "Static") {
            for matrix in staticNode.elements(forName: "Matrix") {
                matrix.detach()
            }
        }
        return copy
    }
}
