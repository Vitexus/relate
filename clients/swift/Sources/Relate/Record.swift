// MARK: - Records

/// The column names of one result, with the name → position lookup built
/// once and shared by every ``Record`` of that result.
final class ColumnIndex: Sendable, Hashable {
    let names: [String]
    /// A duplicated name resolves to its last column, as
    /// ``QueryResult/records`` does.
    let positions: [String: Int]

    init(_ names: [String]) {
        self.names = names
        self.positions = Dictionary(
            names.enumerated().map { ($1, $0) }, uniquingKeysWith: { _, last in last })
    }

    static func == (lhs: ColumnIndex, rhs: ColumnIndex) -> Bool { lhs.names == rhs.names }
    func hash(into hasher: inout Hasher) { hasher.combine(names) }
}

/// One row of a ``QueryResult``: its values in column order, readable by
/// position, by column name, or typed.
///
/// ```swift
/// for record in try conn.query("MATCH (b:Book) RETURN b.title AS title, b.year AS year") {
///     let title: String = try record.get("title")
///     let year: Int? = try record.get("year")
/// }
/// ```
public struct Record: Sendable, Hashable, RandomAccessCollection {
    let index: ColumnIndex
    /// The record's values, in column order.
    public let values: [CypherValue]

    /// The result's column names, in order.
    public var columns: [String] { index.names }

    public var startIndex: Int { values.startIndex }
    public var endIndex: Int { values.endIndex }

    /// The value at a column position.
    public subscript(position: Int) -> CypherValue { values[position] }

    /// The value in the named column; `nil` when the result has no such
    /// column. (A column holding Cypher `null` is `.null`, not `nil`.)
    public subscript(column: String) -> CypherValue? {
        index.positions[column].map { values[$0] }
    }

    /// The record as a column-name → value dictionary: the form
    /// `QueryResult.records` returned before it returned `Record`s.
    public var dictionary: [String: CypherValue] {
        Dictionary(zip(index.names, values), uniquingKeysWith: { _, last in last })
    }

    /// The named column's value as a Swift type. Throws
    /// ``RelateError/unexpectedResult(_:)`` — naming the column — when the
    /// result has no such column or its value is not a `T`. Ask for an
    /// `Optional` to accept `null`.
    public func get<T: CypherValueConvertible>(
        _ column: String, as type: T.Type = T.self
    ) throws(RelateError) -> T {
        guard let position = index.positions[column] else {
            throw shapeMismatch(
                path: [column], expected: "a column named \(quotedWire(column))",
                found: "columns \(index.names)")
        }
        return try convert(values[position], under: column)
    }

    /// The value at a column position as a Swift type.
    public func get<T: CypherValueConvertible>(
        _ position: Int, as type: T.Type = T.self
    ) throws(RelateError) -> T {
        guard values.indices.contains(position) else {
            throw shapeMismatch(
                path: ["\(position)"], expected: "a column at position \(position)",
                found: "\(values.count) columns")
        }
        return try convert(values[position], under: index.names[position])
    }
}
