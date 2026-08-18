import Foundation

/// Public metadata for an OpenPubkey (opkssh) identity, stored on the
/// owning ``SSHKey``. Secrets (refresh token, PK token, access token) live
/// in the Keychain as ``OpenPubkeySecrets``.
nonisolated struct OpenPubkeyInfo: Codable, Hashable, Sendable {
    /// OIDC provider this identity was created against.
    var provider: OIDCProviderConfig

    /// The email claim from the ID token (display + cert key ID). May be
    /// nil for providers that omit it (some Azure tenants).
    var identityEmail: String?

    /// The stable subject (sub) claim; renewals must match it.
    var identitySubject: String

    /// Expiry of the latest ID token (original or refreshed). Drives the
    /// SECONDARY refresh path only (keeping the appended fresh token current
    /// for `oidc_refreshed` servers). It is NOT the real session limit: the
    /// server verifies the ORIGINAL sign-in token, whose age is tracked via
    /// ``lastLoginDate`` and re-minted before the server's ~24h max-age.
    var tokenExpiry: Date

    /// Include the access token in the cert (openpubkey-act extension) so
    /// the server can call the userinfo endpoint. Off by default, matching
    /// opkssh.
    var sendAccessToken: Bool

    /// Whether a refresh token is stored for silent renewal.
    var hasRefreshToken: Bool

    /// Last full browser sign-in.
    var lastLoginDate: Date

    /// Best display string for the signed-in identity.
    var identityDisplay: String {
        identityEmail ?? identitySubject
    }

    var isExpired: Bool {
        Date() >= tokenExpiry
    }
}

/// Keychain-only secrets for an OpenPubkey identity (one blob per key,
/// keyed by the SSHKey UUID).
struct OpenPubkeySecrets: Codable, Sendable {
    /// OIDC refresh token, when the provider returned one.
    var refreshToken: String?

    /// The original 5-segment compact PK token (no fresh-ID-token suffix).
    /// Renewals append the fresh ID token to this base.
    var originalCompactPKT: String

    /// Latest access token; only retained when sendAccessToken is enabled.
    var accessToken: String?
}
