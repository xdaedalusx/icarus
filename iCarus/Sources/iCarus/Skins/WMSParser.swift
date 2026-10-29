import Foundation

/// One element of a Windows Media Player skin layout (.wms).
final class WMSNode {
    /// Lower-cased, because WMP skins are case-insensitive.
    let tag: String
    /// Attribute names are lower-cased. If an attribute appears twice, the last one wins.
    var attributes: [String: String]
    var children: [WMSNode] = []
    weak var parent: WMSNode?

    init(tag: String, attributes: [String: String] = [:]) {
        self.tag = tag
        self.attributes = attributes
    }

    func attr(_ name: String) -> String? { attributes[name.lowercased()] }

    /// This node and everything below it, depth-first, in document order.
    var allNodes: [WMSNode] { [self] + children.flatMap { $0.allNodes } }
}

/// A forgiving reader for .wms files.
///
/// Real WMP skins aren't valid XML (Cerulean repeats attributes on one element, for
/// example), so Apple's XMLParser would reject them. This reader only needs to cope with:
/// comments, quoted attributes (which may contain ">"), repeated attributes,
/// unquoted values and tags in any letter case. Text between tags is ignored.
enum WMSParser {
    /// Returns a synthetic root node whose children are the top-level elements.
    static func parse(_ text: String) -> WMSNode {
        let chars = Array(text)
        let n = chars.count
        let root = WMSNode(tag: "#root")
        var stack: [WMSNode] = [root]
        var i = 0

        func skipSpaces() {
            while i < n && chars[i].isWhitespace { i += 1 }
        }
        func hasPrefix(_ s: String, at index: Int) -> Bool {
            let p = Array(s)
            guard index + p.count <= n else { return false }
            for k in 0..<p.count where chars[index + k] != p[k] { return false }
            return true
        }

        while i < n {
            guard chars[i] == "<" else { i += 1; continue }

            // <!-- comment -->
            if hasPrefix("<!--", at: i) {
                i += 4
                while i < n && !hasPrefix("-->", at: i) { i += 1 }
                i = min(n, i + 3)
                continue
            }
            // <?xml ... ?> or <!DOCTYPE ...>
            if i + 1 < n, chars[i + 1] == "?" || chars[i + 1] == "!" {
                while i < n && chars[i] != ">" { i += 1 }
                i = min(n, i + 1)
                continue
            }
            // </closing>
            if i + 1 < n, chars[i + 1] == "/" {
                i += 2
                var name = ""
                while i < n && chars[i] != ">" { name.append(chars[i]); i += 1 }
                i = min(n, i + 1)
                let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let index = stack.lastIndex(where: { $0.tag == wanted }), index > 0 {
                    stack.removeSubrange(index...)
                }
                continue
            }

            // <opening attr="value" ...>  or  <selfclosing ... />
            i += 1
            var name = ""
            while i < n, !chars[i].isWhitespace, chars[i] != ">", chars[i] != "/" {
                name.append(chars[i])
                i += 1
            }

            var attributes: [String: String] = [:]
            var selfClosing = false
            while i < n {
                skipSpaces()
                guard i < n else { break }
                let c = chars[i]
                if c == ">" { i += 1; break }
                if c == "/" { selfClosing = true; i += 1; continue }

                var key = ""
                while i < n, !chars[i].isWhitespace, chars[i] != "=", chars[i] != ">", chars[i] != "/" {
                    key.append(chars[i])
                    i += 1
                }
                if key.isEmpty { i += 1; continue }   // stray character; always make progress

                skipSpaces()
                var value = ""
                if i < n, chars[i] == "=" {
                    i += 1
                    skipSpaces()
                    if i < n, chars[i] == "\"" || chars[i] == "'" {
                        let quote = chars[i]
                        i += 1
                        while i < n, chars[i] != quote { value.append(chars[i]); i += 1 }
                        i = min(n, i + 1)
                    } else {
                        while i < n, !chars[i].isWhitespace, chars[i] != ">" {
                            value.append(chars[i])
                            i += 1
                        }
                    }
                }
                attributes[key.lowercased()] = value
            }

            guard !name.isEmpty else { continue }
            let node = WMSNode(tag: name.lowercased(), attributes: attributes)
            node.parent = stack.last
            stack.last?.children.append(node)
            if !selfClosing { stack.append(node) }
        }
        return root
    }
}
