
/// The type of "like" reaction that a user can apply to a `ForumPost` or `Twarrt`.
/// Only positive reactions are provided in `swiftarr`.

enum LikeType: String, Codable {
    /// A 😆.
    case laugh
    /// A 👍.
    case like
    /// A ❤️.
    case love
}
