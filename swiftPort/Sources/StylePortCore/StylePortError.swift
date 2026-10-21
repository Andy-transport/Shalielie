import Foundation

public enum StylePortError: LocalizedError, Equatable {
    case invalidData(String)
    case unsupportedPhoto
    case missingResource(String)
    case photoPermissionDenied
    case photoSavePermissionDenied
    case photoAssetUnavailable
    case originalIsNotHEIC
    case alreadyHasTexture
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidData(let message):
            return message
        case .unsupportedPhoto:
            return String(localized: "This HEIC is not supported yet.", bundle: .main)
        case .missingResource(let name):
            return String(localized: "A bundled StylePort resource is missing: \(name).", bundle: .main)
        case .photoPermissionDenied:
            return String(localized: "Photos access is required to retrieve the original HEIC and Live Photo video.", bundle: .main)
        case .photoSavePermissionDenied:
            return String(localized: "Photos add access is required to save the StylePort result.", bundle: .main)
        case .photoAssetUnavailable:
            return String(localized: "The selected Photos asset is no longer available.", bundle: .main)
        case .originalIsNotHEIC:
            return String(localized: "The selected asset's original photo is not HEIC.", bundle: .main)
        case .alreadyHasTexture:
            return String(localized: "This photo already has a Photographic Style and Texture/Grain.", bundle: .main)
        case .saveFailed(let message):
            return String(localized: "Could not save the result: \(message)", bundle: .main)
        }
    }
}
