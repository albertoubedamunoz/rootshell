import Foundation
import CoreLocation

enum AddressState: Equatable {
    case resolving
    case resolved(String)
    case failed(CLLocation)

    static func == (lhs: AddressState, rhs: AddressState) -> Bool {
        switch (lhs, rhs) {
        case (.resolving, .resolving):
            return true
        case (.resolved(let lhsAddr), .resolved(let rhsAddr)):
            return lhsAddr == rhsAddr
        case (.failed(let lhsLoc), .failed(let rhsLoc)):
            return lhsLoc.coordinate.latitude == rhsLoc.coordinate.latitude &&
                   lhsLoc.coordinate.longitude == rhsLoc.coordinate.longitude
        default:
            return false
        }
    }
}

struct LocationDiaryEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D
    var addressState: AddressState
    var retryCount: Int = 0

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: timestamp)
    }

    var coordinateString: String {
        String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }

    var formattedCoordinateString: String {
        let latDirection = coordinate.latitude >= 0 ? "N" : "S"
        let lonDirection = coordinate.longitude >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@",
                     abs(coordinate.latitude), latDirection,
                     abs(coordinate.longitude), lonDirection)
    }

    static func == (lhs: LocationDiaryEntry, rhs: LocationDiaryEntry) -> Bool {
        lhs.id == rhs.id
    }
}
