import Foundation

// MARK: - Foundation types as Cypher values

extension Foundation.Date: CypherValueConvertible {
    /// A UTC `.dateTime`, to the microsecond.
    public func cypherValue() throws(RelateError) -> CypherValue {
        try CypherValue(self)
    }

    /// The instant a `.dateTime` names. A `.localDateTime` has no instant
    /// without a zone and is refused; resolve it with
    /// `foundationDate(in:)`. So is a `.dateTime` whose stored components
    /// name no instant.
    public init(cypherValue: CypherValue) throws(RelateError) {
        let value = try payload(\.dateTimeValue, of: cypherValue, as: Foundation.Date.self)
        guard let date = value.foundationDate else {
            throw mismatch(
                Foundation.Date.self, cypherValue, reason: "its components name no instant")
        }
        self = date
    }
}

extension URL: CypherValueConvertible {
    /// The URL's absolute string.
    public func cypherValue() -> CypherValue { .string(absoluteString) }

    public init(cypherValue: CypherValue) throws(RelateError) {
        let text = try payload(\.stringValue, of: cypherValue, as: URL.self)
        guard let url = URL(string: text) else {
            throw mismatch(URL.self, cypherValue, reason: "the string is not a URL")
        }
        self = url
    }
}

extension UUID: CypherValueConvertible {
    /// The lowercase string form — how the engine's own `randomUUID()`
    /// spells one, so a bound UUID equals a generated one.
    public func cypherValue() -> CypherValue { .string(uuidString.lowercased()) }

    public init(cypherValue: CypherValue) throws(RelateError) {
        let text = try payload(\.stringValue, of: cypherValue, as: UUID.self)
        guard let uuid = UUID(uuidString: text) else {
            throw mismatch(UUID.self, cypherValue, reason: "the string is not a UUID")
        }
        self = uuid
    }
}

extension Data: CypherValueConvertible {
    /// A list of integers `0...255`, the form bytes cross the C ABI in.
    public func cypherValue() -> CypherValue {
        .list(map { .int(Int64($0)) })
    }

    /// A `.list` of integers `0...255`. A value of another kind is reported
    /// as not being `Data`; a list element that is not a byte is reported
    /// at its position.
    public init(cypherValue: CypherValue) throws(RelateError) {
        self = Data(try [UInt8](items: try payload(\.listValue, of: cypherValue, as: Data.self)))
    }
}

#if canImport(CoreLocation)
import CoreLocation

extension CLLocationCoordinate2D: CypherValueConvertible {
    /// A 2D WGS 84 `.point`. Throws ``RelateError/invalidParameter(_:)``
    /// for a coordinate off the globe.
    public func cypherValue() throws(RelateError) -> CypherValue { try CypherValue(self) }

    /// A geographic `.point`'s latitude and longitude.
    public init(cypherValue: CypherValue) throws(RelateError) {
        let point = try payload(\.pointValue, of: cypherValue, as: CLLocationCoordinate2D.self)
        guard let coordinate = point.coordinate else {
            throw mismatch(
                CLLocationCoordinate2D.self, cypherValue,
                reason: "srid \(point.srid) is not geographic")
        }
        self = coordinate
    }
}
#endif
