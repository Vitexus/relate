import Foundation
import Relate

enum Shelf: String, CypherValueConvertible { case want, reading, read }

let conn = try Database.inMemory().connect()

// Swift values bind as they are: no .string(…) wrapping, nil is null, an
// enum binds through its raw value once it declares the conformance.
let books: [(title: String, year: Int, rating: Double?, shelf: Shelf)] = [
    ("The Left Hand of Darkness", 1969, 4.5, .read),
    ("Project Hail Mary", 2021, nil, .reading),
]
for book in books {
    try conn.query(
        "CREATE (:Book {title: $title, year: $year, rating: $rating, shelf: $shelf, added: $added})",
        [
            "title": book.title, "year": book.year, "rating": book.rating, "shelf": book.shelf,
            "added": Date(),
        ])
}

// A result is a collection of records; a typed accessor converts strictly.
let result = try conn.query(
    "MATCH (b:Book) RETURN b.title AS title, b.year AS year, b.rating AS rating, b.shelf AS shelf ORDER BY year")
for record in result {
    let title: String = try record.get("title")
    let rating: Double? = try record.get("rating")  // Optional accepts null
    let shelf: Shelf = try record.get("shelf")
    print(title, try record.get("year", as: Int.self), rating.map { "\($0)" } ?? "unrated", shelf)
}
let shelves = try result.map { try $0.get("shelf", as: Shelf.self) }
precondition(shelves == [.read, .reading])
precondition(result.first?["title"] == "The Left Hand of Darkness")

// A mismatch names the column, the type asked for and the kind found.
do {
    _ = try result[1].get("rating", as: Double.self)
    preconditionFailure("a null rating is not a Double")
} catch {
    guard case .unexpectedResult(let mismatch) = error else { throw error }
    print("mismatch:", mismatch.message)
    precondition(mismatch.path == ["rating"] && mismatch.expected == "Double" && mismatch.found == "null")
}

// single() and scalar(as:) check the shape as well as the type.
let count = try conn.query("MATCH (b:Book) RETURN count(b)").scalar(as: Int.self)
precondition(count == 2)
let newest = try conn.query("MATCH (b:Book) RETURN b.title AS title ORDER BY b.year DESC LIMIT 1").single()
let newestTitle: String = try newest.get("title")
precondition(newestTitle == "Project Hail Mary")
