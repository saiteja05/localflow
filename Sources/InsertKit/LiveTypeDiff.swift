/// Diffs two strings by Character (grapheme cluster, not UTF-16 unit) so
/// multi-scalar emoji and combining marks are never split mid-cluster.
public enum LiveTypeDiff {
    public static func compute(from old: String, to new: String) -> (backspaces: Int, suffix: String) {
        let oldChars = Array(old)
        let newChars = Array(new)
        var common = 0
        while common < oldChars.count, common < newChars.count, oldChars[common] == newChars[common] {
            common += 1
        }
        let backspaces = oldChars.count - common
        let suffix = String(newChars[common...])
        return (backspaces, suffix)
    }
}
