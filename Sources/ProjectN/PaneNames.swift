import Foundation

/// Friendly names given to new panes so each agent is easy to tell apart.
enum PaneNames {
    static let all = [
        "Ada", "Alan", "Grace", "Linus", "Margaret", "Dennis", "Ken", "Barbara", "Edsger", "Donald",
        "Hedy", "Tim", "Vint", "Radia", "Frances", "John", "Katherine", "Dorothy", "Claude", "Niklaus",
        "Bjarne", "Guido", "Yukihiro", "Anders", "Brendan", "Rasmus", "James", "Larry", "Sophie", "Fernando",
        "Marie", "Nikola", "Albert", "Isaac", "Rosalind", "Carl", "Galileo", "Johannes", "Emmy", "Srinivasa",
        "Hypatia", "Leonardo", "Charles", "Rachel", "Jane", "Neil", "Sally", "Mae", "Valentina", "Yuri",
    ]

    /// A random name not already used by any open pane (falls back to "Name 2", "Name 3"… when all are taken).
    static func pick(avoiding used: Set<String>) -> String {
        if let n = all.filter({ !used.contains($0) }).randomElement() { return n }
        let base = all.randomElement()!
        var i = 2
        while used.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }
}
