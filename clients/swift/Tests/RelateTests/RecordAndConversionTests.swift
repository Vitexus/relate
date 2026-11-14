import CoreLocation
import Foundation
import Testing

import Relate

enum Shelf: String, CypherValueConvertible { case want, reading, read }

@Suite struct RecordAndConversionTests {
    let conn = try! Database.inMemory().connect()

    // MARK: Parameters

    @Test func swiftValuesBindWithoutWrapping() throws {
        let title = "Project Hail Mary"
        let year = 2021
        let rating: Double? = nil
        let authors = ["Andy Weir"]
        let id = try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        let url = try #require(URL(string: "https://example.com/cover.jpg"))
        let record = try conn.query(
            """
            RETURN $title AS title, $year AS year, $rating AS rating, $authors AS authors,
                   $id AS id, $url AS url, $shelf AS shelf, $ratio AS ratio, $small AS small,
                   $props.pages AS pages, $bytes AS bytes
            """,
            [
                "title": title, "year": year, "rating": rating, "authors": authors, "id": id,
                "url": url, "shelf": Shelf.reading, "ratio": Float(0.5), "small": UInt8(200),
                "props": ["pages": 496], "bytes": Data([0, 127, 255]),
            ]
        ).single()
        #expect(record["title"] == .string(title) && record["year"] == .int(2021) && record["rating"] == .null)
        #expect(record["authors"] == ["Andy Weir"] && record["shelf"] == "reading")
        // A UUID binds lowercase, the engine's own spelling.
        #expect(record["id"] == "6f9619ff-8b86-d011-b42d-00c04fc964ff")
        #expect(record["url"] == "https://example.com/cover.jpg")
        #expect(record["ratio"] == .float(0.5) && record["small"] == .int(200) && record["pages"] == .int(496))
        #expect(record["bytes"] == [0, 127, 255])
        // And read back as the same Swift values.
        #expect(try record.get("id", as: UUID.self) == id)
        #expect(try record.get("url", as: URL.self) == url)
        #expect(try record.get("shelf", as: Shelf.self) == .reading)
        #expect(try record.get("bytes", as: Data.self) == Data([0, 127, 255]))
        // A value that is not a list is not Data; a list element that is not
        // a byte is named by its position.
        #expect(try resultMismatch { _ = try record.get("url", as: Data.self) }.expected == "Data")
        let notBytes = try resultMismatch { _ = try Data(cypherValue: .list([.int(1), .int(256)])) }
        #expect(notBytes.path == ["[1]"] && notBytes.reason == "256 is out of range")
    }

    @Test func literalAndTypedDictionariesStillBind() throws {
        // The original entry point: literals, `nil`, and enum cases in one
        // dictionary resolve to it unchanged beside the new overload.
        let literal = try conn.query(
            "RETURN $a AS a, $b AS b, $c AS c, $d AS d", ["a": 1, "b": "x", "c": nil, "d": .float(.infinity)])
        #expect(literal.rows[0] == [1, "x", nil, .float(.infinity)])
        let typed: [String: CypherValue] = ["a": 1]
        #expect(try conn.query("RETURN $a", typed).scalar() == 1)
        // A dictionary of one Swift type, and one mixing variables with a literal.
        let names = ["a": "x", "b": "y"]
        #expect(try conn.query("RETURN $a + $b", names).scalar() == "xy")
        let limit = 3
        #expect(try conn.query("RETURN $limit + $more", ["limit": limit, "more": 4]).scalar() == 7)
    }

    @Test func aValueCypherCannotHoldIsRefusedBeforeTheEngine() throws {
        let message = try invalidParameterMessage { try conn.query("RETURN $n", ["n": UInt64.max]) }
        #expect(message.contains("UInt64") && message.contains("does not fit"))
        #expect(try conn.query("RETURN $n", ["n": UInt64(Int64.max)]).scalar() == .int(.max))
        #expect(try invalidParameterMessage {
            try conn.query("RETURN $d", ["d": Date(timeIntervalSinceReferenceDate: .nan)])
        }.contains("not finite"))
        let offTheGlobe = CLLocationCoordinate2D(latitude: 95, longitude: 0)
        #expect(try invalidParameterMessage { try conn.query("RETURN $p", ["p": offTheGlobe]) }
            .contains("latitude 95.0"))
    }

    @Test func datesAndPointsBindAsTheirTypedKinds() throws {
        let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-11-08T13:00:00.123Z")
        let here = CLLocationCoordinate2D(latitude: 46.87, longitude: -113.99)
        let record = try conn.query(
            "RETURN $at AS at, $here AS here, $p AS p, $day AS day",
            [
                "at": date, "here": here, "p": CypherValue.Point(x: 1, y: 2),
                "day": CypherValue.Date(year: 2026, month: 11, day: 8),
            ]
        ).single()
        #expect(record["at"]?.kind == .dateTime && record["here"]?.kind == .point && record["day"]?.kind == .date)
        #expect(try record.get("at", as: Date.self) == date)
        let back: CLLocationCoordinate2D = try record.get("here")
        #expect(back.latitude == 46.87 && back.longitude == -113.99)
        #expect(try record.get("p", as: CypherValue.Point.self).crs == .cartesian)
        // A Cartesian point is not a coordinate; a local datetime is not an instant.
        #expect(try resultMismatch { _ = try record.get("p", as: CLLocationCoordinate2D.self) }.reason == "srid 7203 is not geographic")
        let local = try conn.query("RETURN localdatetime('2026-11-08T13:00:00') AS at").single()
        #expect(try resultMismatch { _ = try local.get("at", as: Date.self) }.found == "localDateTime")
        // Nor is a datetime built by hand from components that name no instant.
        let thirteenthMonth = CypherValue.dateTime(.init(
            year: 2026, month: 13, day: 1, hour: 0, minute: 0, second: 0, nanosecond: 0,
            offsetSeconds: 0, zone: nil))
        #expect(try resultMismatch { _ = try Date(cypherValue: thirteenthMonth) }.reason
            == "its components name no instant")
    }

    // MARK: Records

    @Test func aResultIsACollectionOfRecords() throws {
        try conn.query("UNWIND range(1, 3) AS i CREATE (:Book {title: 'Book ' + toString(i), year: 2000 + i})")
        let result = try conn.query("MATCH (b:Book) RETURN b.title AS title, b.year AS year ORDER BY year")
        #expect(result.count == 3 && !result.isEmpty)
        #expect(result.columns == ["title", "year"] && result[0].columns == ["title", "year"])
        var titles: [String] = []
        for record in result { titles.append(try record.get("title")) }
        #expect(titles == ["Book 1", "Book 2", "Book 3"])
        #expect(try result.map { try $0.get("year", as: Int.self) } == [2001, 2002, 2003])
        let first = try #require(result.first)
        #expect(first[0] == "Book 1" && first["year"] == 2001 && first["absent"] == nil)
        #expect(first.values == ["Book 1", 2001] && Array(first) == first.values && first.count == 2)
        #expect(first.dictionary == ["title": "Book 1", "year": 2001])
        #expect(try first.get(1, as: Int.self) == 2001)
        // `records` is the same records as an array; `rows` and a record's
        // dictionary are the plain forms of the same data.
        #expect(result.records == Array(result) && result.records.map(\.values) == result.rows)
        #expect(result.records[1].dictionary == ["title": "Book 2", "year": 2002])
        #expect(result[2] == result[2] && result[0] != result[1])
    }

    @Test func typedAccessorsAreStrictAndNameTheColumn() throws {
        let record = try conn.query(
            "RETURN 'x' AS s, 300 AS n, 1.5 AS f, null AS nothing, [1, 'two'] AS mixed, {k: 'v'} AS m, '4' AS digits"
        ).single()
        // An integer widens to a float; a float does not narrow to an integer.
        #expect(try record.get("n", as: Double.self) == 300 && record.get("f", as: Float.self) == 1.5)
        var failure = try resultMismatch { _ = try record.get("f", as: Int.self) }
        #expect(failure.path == ["f"] && failure.expected == "Int" && failure.found == "float")
        // A string is never parsed into a number.
        failure = try resultMismatch { _ = try record.get("digits", as: Int.self) }
        #expect(failure.path == ["digits"] && failure.found == "string")
        // A null is not a value; ask for an Optional to accept one.
        failure = try resultMismatch { _ = try record.get("nothing", as: String.self) }
        #expect(failure.found == "null" && failure.message == "nothing: expected String, found null")
        #expect(try record.get("nothing", as: String?.self) == nil && record.get("s", as: String?.self) == "x")
        // An out-of-range integer names the value.
        failure = try resultMismatch { _ = try record.get("n", as: UInt8.self) }
        #expect(failure.reason == "300 is out of range")
        // A container names the element that failed.
        failure = try resultMismatch { _ = try record.get("mixed", as: [Int].self) }
        #expect(failure.path == ["mixed", "[1]"] && failure.found == "string")
        failure = try resultMismatch { _ = try record.get("m", as: [String: Int].self) }
        #expect(failure.path == ["m", "k"])
        #expect(try record.get("m", as: [String: String].self) == ["k": "v"])
        // A column the result does not have.
        failure = try resultMismatch { _ = try record.get("absent", as: String.self) }
        #expect(failure.path == ["absent"] && failure.found.contains("digits"))
        failure = try resultMismatch { _ = try record.get(99, as: String.self) }
        #expect(failure.found == "7 columns")
        // A raw value outside the enum.
        failure = try resultMismatch { _ = try record.get("s", as: Shelf.self) }
        #expect(failure.expected == "Shelf" && failure.reason == "x is not one of its raw values")
    }

    @Test func aVectorReadsAsAnArrayOfItsCoordinates() throws {
        let floats: [Float] = [0.25, 0.5]
        let record = try conn.query("RETURN $v AS v", ["v": try CypherValue(vector: floats)]).single()
        #expect(try record.get("v", as: [Float].self) == floats && record.get("v", as: [Double].self) == [0.25, 0.5])
        #expect(try record.get("v", as: CypherValue.Vector.self).dtype == .float32)
        // An array of floats binds as a list, never silently as a vector.
        #expect(try conn.query("RETURN $v", ["v": floats]).scalar().kind == .list)
    }

    @Test func singleAndTypedScalarCheckTheShape() throws {
        #expect(try conn.query("RETURN 42").scalar(as: Int.self) == 42)
        #expect(try conn.query("RETURN 42").single()[0] == 42)
        var failure = try resultMismatch { _ = try conn.query("UNWIND [1, 2] AS i RETURN i").single() }
        #expect(failure.path.isEmpty && failure.expected == "exactly one record" && failure.found == "2 records")
        failure = try resultMismatch { _ = try conn.query("MATCH (n:Nothing) RETURN n").single() }
        #expect(failure.found == "0 records")
        failure = try resultMismatch { _ = try conn.query("RETURN 'x' AS label").scalar(as: Int.self) }
        #expect(failure.path == ["label"] && failure.expected == "Int")
        // The untyped scalar refuses a wrong shape the same way.
        failure = try resultMismatch { _ = try conn.query("UNWIND [1, 2] AS i RETURN i").scalar() }
        #expect(failure.expected == "exactly one record" && failure.found == "2 records")
        failure = try resultMismatch { _ = try conn.query("RETURN 1 AS a, 2 AS b").scalar() }
        #expect(failure.expected == "exactly one column" && failure.found == "2 columns")
    }


    @Test func resultsCompareByValue() throws {
        let a = try conn.query("RETURN 1 AS n")
        #expect(a == a)
        // Timings are part of a result, so compare rows across runs.
        #expect(a.rows == (try conn.query("RETURN 1 AS n")).rows)
        #expect(a != (try conn.query("RETURN 2 AS n")))
    }

    @Test func entitiesConvertButDoNotBind() throws {
        let record = try conn.query("CREATE (a:A {k: 1})-[r:R]->(b:B) RETURN a, r, b").single()
        let node: CypherValue.Node = try record.get("a")
        #expect(node.labels == ["A"] && node.properties["k"] == 1)
        #expect(try record.get("r", as: CypherValue.Relationship.self).type == "R")
        // A node is not a map; its properties are.
        #expect(try resultMismatch { _ = try record.get("a", as: [String: Int].self) }.found == "node")
        _ = try invalidParameterMessage { try conn.query("RETURN $n", ["n": node]) }
    }
}
