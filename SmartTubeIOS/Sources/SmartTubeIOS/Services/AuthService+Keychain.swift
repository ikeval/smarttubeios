import Foundation

extension AuthService {

    // MARK: - Persistence (delegates to TokenManager)

    func saveToKeychain() {
        let access = accessToken
        let refresh = refreshToken
        let expiry = tokenExpiry
        let name = accountName
        let avatar = accountAvatarURL
        Task {
            await tokenManager.setToken(
                access: access,
                refresh: refresh,
                expiry: expiry,
                accountName: name,
                avatarURL: avatar
            )
        }
    }

    func loadFromKeychain() {
        let snap = tokenManager.initialSnapshot
        accessToken      = snap.accessToken
        refreshToken     = snap.refreshToken
        tokenExpiry      = snap.tokenExpiry
        accountName      = snap.accountName
        accountAvatarURL = snap.accountAvatarURL
        sapisid          = snap.sapisid
        // Migration: if the user was signed in before SAPISID support was added,
        // force sign-out so the next sign-in fetches and persists the SAPISID cookie.
        // Without SAPISID, WEB_CREATOR returns LOGIN_REQUIRED and high-res streams
        // are unavailable. Re-signing in is a one-time cost.
        let wouldBeSignedIn = accessToken != nil || refreshToken != nil
        if wouldBeSignedIn && sapisid == nil {
            authLog.notice("loadFromKeychain: signed in but no SAPISID — forcing re-auth to obtain SAPISID")
            accessToken      = nil
            refreshToken     = nil
            tokenExpiry      = nil
            accountName      = nil
            accountAvatarURL = nil
            Task { await tokenManager.clearToken() }
            isSignedIn = false
            return
        }
        // If the stored access token has already expired, clear it so that
        // view observers (e.g. HomeView.task(id: auth.accessToken)) don't fire
        // API requests with a stale token. scheduleProactiveRefresh() will
        // obtain a fresh token and set accessToken once it succeeds.
        if let expiry = tokenExpiry, expiry <= Date() {
            accessToken = nil
        }
        isSignedIn = accessToken != nil || refreshToken != nil
        if isSignedIn { scheduleProactiveRefresh() }
    }

    func clearKeychain() {
        Task { await tokenManager.clearToken() }
    }
}

