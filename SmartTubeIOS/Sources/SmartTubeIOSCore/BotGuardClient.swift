import Foundation
import JavaScriptCore
import os

// MARK: - BotGuardError

public enum BotGuardError: Error, CustomStringConvertible {
    case challengeFailed(String)
    case challengeParseError(String)
    case jsFailed(String)
    case integrityTokenFailed(String)
    case mintFailed(String)

    public var description: String {
        switch self {
        case .challengeFailed(let m):       "BotGuard challenge fetch failed: \(m)"
        case .challengeParseError(let m):   "BotGuard challenge parse error: \(m)"
        case .jsFailed(let m):              "BotGuard JS error: \(m)"
        case .integrityTokenFailed(let m):  "BotGuard integrity token failed: \(m)"
        case .mintFailed(let m):            "BotGuard mint failed: \(m)"
        }
    }
}

// MARK: - BotGuardClient

/// Generates YouTube Proof-of-Origin (PO) tokens on-device using JavaScriptCore.
///
/// The BotGuard attestation pipeline mirrors https://github.com/LuanRT/BgUtils (MIT):
/// 1. Fetch the BotGuard challenge (interpreter JS + program + globalName) from Google's WAA API.
/// 2. Execute the interpreter JS in a `JSContext`; call `vm.a(program, callback, …)` to load the program.
/// 3. Call `asyncSnapshotFn(callback, params)` → `botguardResponse` string.
/// 4. POST `botguardResponse` to WAA GenerateIT → `integrityTokenB64`.
/// 5. Call `webPoSignalOutput[0](integrityTokenBytes)` → minter → call minter with videoId bytes → base64 token.
///
/// All JSContext work and blocking network calls run on a dedicated serial `jsQueue` (a real OS thread).
/// Network calls use `URLSession.dataTask` + `DispatchSemaphore` — safe because `jsQueue` is not part of
/// Swift's cooperative concurrency thread pool.
public final class BotGuardClient: PoTokenProvider, @unchecked Sendable {

    // MARK: - WAA API constants
    // Public API key used by YouTube's web client; from BgUtils / YouTube JS source.
    private static let waaAPIKey  = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    // YouTube BotGuard request key (stable; from BgUtils examples).
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    private static let waaCreateURL     = URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/Create")!
    private static let waaGenerateITURL = URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT")!

    // MARK: - Properties
    private let session: URLSession
    private let bgLog = Logger(subsystem: appSubsystem, category: "BotGuard")
    /// All JSContext access serialised on this queue. It is a real OS thread, so
    /// `DispatchSemaphore.wait()` inside blocks here does NOT block the Swift cooperative pool.
    private let jsQueue = DispatchQueue(label: "st.botguard.js", qos: .userInitiated)

    // MARK: - Init

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - PoTokenProvider

    public func token(for videoId: String) async throws -> String {
        bgLog.notice("[BotGuard] token requested for \(videoId, privacy: .public)")

        // Phase 1 – fetch challenge (async Swift network call, off jsQueue).
        let challenge = try await fetchChallenge()
        bgLog.notice("[BotGuard] challenge ok, globalName=\(challenge.globalName, privacy: .public) jsLen=\(challenge.interpreterJS.count)")

        // Phase 2–5 – run entirely on jsQueue to keep all JSValue references on one thread.
        let token = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            jsQueue.async {
                do {
                    let tok = try self.runPipelineSync(challenge: challenge, videoId: videoId)
                    cont.resume(returning: tok)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        bgLog.notice("[BotGuard] ✅ PO token minted (len=\(token.count)) for \(videoId, privacy: .public)")
        return token
    }

    // MARK: - Challenge model

    private struct BotGuardChallenge {
        let interpreterJS: String
        let program: String
        let globalName: String
    }

    // MARK: - Phase 1: fetch challenge from WAA Create endpoint

    private func fetchChallenge() async throws -> BotGuardChallenge {
        var req = URLRequest(url: Self.waaCreateURL, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.waaAPIKey,              forHTTPHeaderField: "x-goog-api-key")
        req.setValue("grpc-web-javascript/0.1",   forHTTPHeaderField: "x-user-agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [Self.requestKey])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BotGuardError.challengeFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        // Log raw response for parse debugging (truncated to 300 chars)
        let rawPreview = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "<binary>"
        bgLog.notice("[BotGuard] WAA Create raw response (first 300): \(rawPreview, privacy: .public)")

        // Response: [requestKey, [messageId?, interpreterHash, interpreterURL_or_JS, program, globalName, ...]]
        // Some YouTube builds wrap the inner array: [requestKey, [[inner...]]].
        // Since Swift casts [[Any]] as [Any] successfully, we must check element count
        // to distinguish the direct layout (≥5 string elements) from the nested layout
        // (1 element that is itself the [messageId, hash, url, program, globalName] array).
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [Any],
              outer.count >= 2 else {
            throw BotGuardError.challengeParseError("outer array missing")
        }
        let inner: [Any]
        if let candidate = outer[1] as? [Any] {
            bgLog.notice("[BotGuard] outer[1] count=\(candidate.count) firstIsArray=\(candidate.first is [Any])")
            if candidate.count >= 5 {
                inner = candidate
            } else if let nested = candidate.first as? [Any], nested.count >= 4 {
                inner = nested
            } else if let nested = candidate.first as? [Any] {
                bgLog.notice("[BotGuard] nested inner count=\(nested.count) — too short")
                throw BotGuardError.challengeParseError("inner array too short (\(nested.count))")
            } else {
                bgLog.notice("[BotGuard] candidate.count=\(candidate.count) and first is not [Any]")
                throw BotGuardError.challengeParseError("inner array too short (\(candidate.count))")
            }
        } else {
            bgLog.notice("[BotGuard] outer[1] is not [Any]")
            throw BotGuardError.challengeParseError("inner array missing at outer[1]")
        }

        // inner layout (BgUtils parseChallengeData):
        // [0] = messageId (optional string — omitted in some YouTube builds)
        // When 5+ elements: [msgId, hash, url, program, globalName]
        // When 4 elements:  [hash, url, program, globalName]  (no messageId)
        let hasMessageId = inner.count >= 5
        let hashIdx    = hasMessageId ? 1 : 0
        let urlIdx     = hasMessageId ? 2 : 1
        let programIdx = hasMessageId ? 3 : 2
        let nameIdx    = hasMessageId ? 4 : 3
        bgLog.notice("[BotGuard] inner count=\(inner.count) hasMessageId=\(hasMessageId)")

        var interpreterJS = ""
        if let raw = inner[urlIdx] as? String, !raw.isEmpty {
            let urlStr = raw.hasPrefix("//") ? "https:\(raw)" : raw
            if let jsURL = URL(string: urlStr), jsURL.scheme != nil, jsURL.host != nil {
                // Fetch interpreter script from URL
                let (jsData, _) = try await session.data(from: jsURL)
                interpreterJS = String(data: jsData, encoding: .utf8) ?? ""
                bgLog.notice("[BotGuard] interpreter JS fetched from URL (len=\(interpreterJS.count))")
            } else {
                interpreterJS = raw
            }
        }

        guard !interpreterJS.isEmpty else {
            throw BotGuardError.challengeParseError("interpreter JS empty")
        }
        guard let program = inner[programIdx] as? String, !program.isEmpty else {
            throw BotGuardError.challengeParseError("program empty")
        }
        guard let globalName = inner[nameIdx] as? String, !globalName.isEmpty else {
            throw BotGuardError.challengeParseError("globalName empty")
        }

        return BotGuardChallenge(interpreterJS: interpreterJS, program: program, globalName: globalName)
    }

    // MARK: - Phase 2–5: synchronous pipeline on jsQueue

    /// Runs the entire BotGuard pipeline synchronously:
    /// JS VM execution → integrity token fetch (blocking) → mint (JS).
    /// Must be called from `jsQueue` only.
    private func runPipelineSync(challenge: BotGuardChallenge, videoId: String) throws -> String {

        // --- Set up JSContext with minimal polyfills ---
        guard let ctx = JSContext() else {
            throw BotGuardError.jsFailed("JSContext() returned nil")
        }
        ctx.exceptionHandler = { [weak self] _, exc in
            self?.bgLog.warning("[BotGuard] JSContext exception: \(exc?.toString() ?? "nil", privacy: .public)")
        }
        installPolyfills(ctx)

        // --- Load BotGuard interpreter VM ---
        ctx.evaluateScript(challenge.interpreterJS)
        if let exc = ctx.exception {
            throw BotGuardError.jsFailed("interpreter load: \(exc)")
        }

        // --- Locate the VM object in global scope ---
        guard let vm = ctx.globalObject?.objectForKeyedSubscript(challenge.globalName),
              !vm.isNull, !vm.isUndefined else {
            throw BotGuardError.jsFailed("VM '\(challenge.globalName)' not in JSContext global")
        }

        // --- Phase 2: call vm.a(program, vmFunctionsCallback, true, undefined, noop, [[], []]) ---
        var asyncSnapshotFn: JSValue?
        let vmFnCallback: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> Void = { fn, _, _, _ in
            asyncSnapshotFn = fn
        }
        let undef    = JSValue(undefinedIn: ctx)!
        let noopFn   = JSValue(object: { } as @convention(block) () -> Void, in: ctx)!
        let initPair = ctx.evaluateScript("[[],[]]")!

        // invokeMethod sets this=vm, required by the real BotGuard VM's internal methods.
        let vmCallResult = vm.invokeMethod("a", withArguments: [
            challenge.program,
            JSValue(object: vmFnCallback, in: ctx)!,
            NSNumber(value: true),
            undef,
            noopFn,
            initPair
        ])

        if let exc = ctx.exception { throw BotGuardError.jsFailed("vm.a(): \(exc)") }

        // vm.a() may return [syncFn, ...] or [Promise, ...]; pump microtasks either way.
        if let initPromise = vmCallResult?.objectAtIndexedSubscript(0),
           initPromise.objectForKeyedSubscript("then")?.isObject == true {
            _ = try resolvePromise(initPromise, in: ctx, label: "vm.a() init")
        } else {
            pumpMicrotasks(ctx, count: 3)
        }

        guard let snapFn = asyncSnapshotFn, !snapFn.isNull, !snapFn.isUndefined else {
            throw BotGuardError.jsFailed("asyncSnapshotFn not set after vm.a() — VM may have changed API")
        }

        // --- Phase 3: asyncSnapshotFn(callback, [undefined, undefined, webPoSignalOutput, undefined]) ---
        var botguardResponse: String?
        let webPoSignalOutput = ctx.evaluateScript("[]")!   // JS array, populated by VM
        ctx.setObject(webPoSignalOutput, forKeyedSubscript: "__bgSO" as NSString)

        let snapCallback: @convention(block) (JSValue) -> Void = { response in
            botguardResponse = response.isNull || response.isUndefined ? nil : response.toString()
        }
        let snapArgs = ctx.evaluateScript("[undefined, undefined, __bgSO, undefined]")!

        snapFn.call(withArguments: [
            JSValue(object: snapCallback, in: ctx)!,
            snapArgs
        ])
        if let exc = ctx.exception { throw BotGuardError.jsFailed("asyncSnapshotFn: \(exc)") }
        pumpMicrotasks(ctx, count: 5)   // flush in case callback fires asynchronously

        guard let bgResponse = botguardResponse, !bgResponse.isEmpty else {
            throw BotGuardError.jsFailed("botguard response empty after asyncSnapshotFn")
        }

        // --- Phase 4: fetch integrity token (blocking URLSession, safe on jsQueue) ---
        let integrityB64 = try fetchIntegrityTokenSync(bgResponse: bgResponse)
        bgLog.notice("[BotGuard] integrity token obtained (len=\(integrityB64.count))")

        // --- Phase 5: mint PO token ---
        return try mintSync(
            ctx: ctx,
            signalOutput: webPoSignalOutput,
            integrityB64: integrityB64,
            videoId: videoId
        )
    }

    // MARK: - Phase 4: integrity token (blocking, on jsQueue)

    private func fetchIntegrityTokenSync(bgResponse: String) throws -> String {
        let payload = [Self.requestKey, bgResponse]
        var req = URLRequest(url: Self.waaGenerateITURL, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.waaAPIKey,              forHTTPHeaderField: "x-goog-api-key")
        req.setValue("grpc-web-javascript/0.1",   forHTTPHeaderField: "x-user-agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        var result: Result<String, Error>?
        let sema = DispatchSemaphore(value: 0)

        session.dataTask(with: req) { data, response, error in
            defer { sema.signal() }
            if let error { result = .failure(error); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let token = json.first as? String, !token.isEmpty else {
                result = .failure(BotGuardError.integrityTokenFailed(
                    "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                ))
                return
            }
            result = .success(token)
        }.resume()

        sema.wait()
        return try result!.get()
    }

    // MARK: - Phase 5: mint (JS, on jsQueue)

    private func mintSync(ctx: JSContext, signalOutput: JSValue, integrityB64: String, videoId: String) throws -> String {

        // Decode integrity token bytes
        guard let integrityData = Data(base64Encoded: integrityB64) else {
            throw BotGuardError.mintFailed("integrityToken base64 decode failed")
        }

        // Build JS Uint8Array for integrity token bytes
        let integrityU8 = try buildUint8Array(from: integrityData, in: ctx, label: "integrityToken")

        // getMinter = webPoSignalOutput[0]  (a function set by the VM during asyncSnapshotFn)
        guard let getMinterFn = signalOutput.objectAtIndexedSubscript(0),
              !getMinterFn.isNull, !getMinterFn.isUndefined else {
            throw BotGuardError.mintFailed("webPoSignalOutput[0] (getMinter) not set")
        }

        // mintCallback = await getMinter(integrityTokenBytes)  – may return Promise or function directly
        let getMinterResult = getMinterFn.call(withArguments: [integrityU8])
        if let exc = ctx.exception { throw BotGuardError.mintFailed("getMinter(): \(exc)") }
        let mintCallbackFn = try resolvePromise(getMinterResult ?? JSValue(undefinedIn: ctx)!, in: ctx, label: "getMinter")

        guard !mintCallbackFn.isNull, !mintCallbackFn.isUndefined else {
            throw BotGuardError.mintFailed("mintCallback is null after getMinter")
        }

        // tokenBytes = await mintCallback(TextEncoder().encode(videoId))
        guard let videoIdData = videoId.data(using: .utf8) else {
            throw BotGuardError.mintFailed("videoId UTF-8 encoding failed")
        }
        let videoIdU8 = try buildUint8Array(from: videoIdData, in: ctx, label: "videoId")

        let mintResult = mintCallbackFn.call(withArguments: [videoIdU8])
        if let exc = ctx.exception { throw BotGuardError.mintFailed("mintCallback(): \(exc)") }
        let tokenValue = try resolvePromise(mintResult ?? JSValue(undefinedIn: ctx)!, in: ctx, label: "mintCallback")

        // Extract bytes from the result (Uint8Array or plain Array)
        var tokenBytes = Data()
        if let lengthVal = tokenValue.objectForKeyedSubscript("length"), lengthVal.isNumber {
            let length = Int(lengthVal.toInt32())
            for i in 0..<length {
                let byte = tokenValue.objectAtIndexedSubscript(i).toUInt32()
                tokenBytes.append(UInt8(byte & 0xFF))
            }
        }

        guard !tokenBytes.isEmpty else {
            throw BotGuardError.mintFailed("mint result was empty")
        }

        return tokenBytes.base64EncodedString()
    }

    // MARK: - JSContext helpers

    /// Installs minimal polyfills for APIs the BotGuard interpreter JS may reference.
    private func installPolyfills(_ ctx: JSContext) {
        // window / globalThis aliasing (BotGuard may write to window.X)
        ctx.evaluateScript("""
        if (typeof window === 'undefined') { var window = this; }
        if (typeof globalThis === 'undefined') { var globalThis = window; }
        if (typeof self === 'undefined') { var self = window; }
        """)

        // Minimal document stub (prevents crashes on e.g. document.createElement)
        ctx.evaluateScript("""
        if (typeof document === 'undefined') {
            var document = {
                createElement: function(tag) { return { tagName: tag, style: {}, setAttribute: function(){}, appendChild: function(){} }; },
                createTextNode: function(t) { return { textContent: t }; },
                getElementsByTagName: function() { return []; },
                querySelector: function() { return null; },
                querySelectorAll: function() { return []; },
                head: { appendChild: function(s){ if(s && s.src){ } } },
                body: { appendChild: function(){} },
                cookie: ''
            };
        }
        """)

        // navigator stub
        ctx.evaluateScript("""
        if (typeof navigator === 'undefined') {
            var navigator = { userAgent: 'Mozilla/5.0', language: 'en-US', languages: ['en-US'], cookieEnabled: true };
        }
        """)

        // setTimeout / setInterval stubs (synchronous — fires callback immediately for best-effort compat)
        // BotGuard typically does not rely on real timer semantics in its VM.
        let setTimeoutFn: @convention(block) (JSValue, JSValue) -> NSNumber = { cb, _ in
            if cb.isObject { cb.call(withArguments: []) }
            return 0
        }
        ctx.setObject(setTimeoutFn, forKeyedSubscript: "setTimeout" as NSString)
        ctx.setObject({ (_: JSValue, _: JSValue) -> NSNumber in 0 } as @convention(block) (JSValue, JSValue) -> NSNumber,
                      forKeyedSubscript: "setInterval" as NSString)
        ctx.setObject({ (_: NSNumber) in } as @convention(block) (NSNumber) -> Void,
                      forKeyedSubscript: "clearTimeout" as NSString)
        ctx.setObject({ (_: NSNumber) in } as @convention(block) (NSNumber) -> Void,
                      forKeyedSubscript: "clearInterval" as NSString)
    }

    /// Builds a JS `Uint8Array` from `Data`. Used for passing byte arrays across the Swift/JS bridge.
    private func buildUint8Array(from data: Data, in ctx: JSContext, label: String) throws -> JSValue {
        guard let arr = ctx.evaluateScript("new Uint8Array(\(data.count))"),
              !arr.isNull, !arr.isUndefined else {
            throw BotGuardError.mintFailed("Uint8Array(\(label)) creation failed")
        }
        for (i, byte) in data.enumerated() {
            arr.setObject(NSNumber(value: byte), atIndexedSubscript: i)
        }
        return arr
    }

    /// Pumps pending JSC microtasks by re-entering the JS engine.
    /// Each call to `evaluateScript` creates a drain-point where JSC flushes its microtask queue.
    private func pumpMicrotasks(_ ctx: JSContext, count: Int) {
        for _ in 0..<count { ctx.evaluateScript("undefined") }
    }

    /// Resolves a JS Promise synchronously using a pure-JS then-handler that writes
    /// the settled value to a context global (`__bgR`), then reads it back in Swift.
    ///
    /// Avoids crossing the JS→Swift callback boundary during microtask draining
    /// (Swift `@convention(block)` callbacks from within JSC microtasks can be unreliable
    /// when microtask draining occurs re-entrantly inside `JSObjectCallAsFunction`).
    ///
    /// The `__bgR` global is single-use and deleted after reading; safe because jsQueue is serial.
    /// Returns `promise` directly if it is not thenable (mirrors `await nonPromise` in JS).
    private func resolvePromise(_ promise: JSValue, in ctx: JSContext, label: String, maxPumps: Int = 20) throws -> JSValue {
        guard promise.objectForKeyedSubscript("then")?.isObject == true else {
            return promise
        }

        // Store the promise in a JS global so the IIFE can access it by name.
        ctx.setObject(promise, forKeyedSubscript: "__bgP" as NSString)

        // The IIFE calls p.then(handler) as a method (this=p, correct binding).
        // JSEvaluateScript calls vm.drainMicrotasks() after the IIFE returns, which
        // executes the queued then-callback and sets __bgR before returning to Swift.
        ctx.evaluateScript("""
        (function() {
            var p = globalThis.__bgP;
            delete globalThis.__bgP;
            p.then(
                function(v) { globalThis.__bgR = { ok: 1, v: v }; },
                function(e) { globalThis.__bgR = { ok: 0, e: String(e) }; }
            );
        })();
        """)
        if let exc = ctx.exception {
            throw BotGuardError.jsFailed("resolvePromise '\(label)' setup: \(exc)")
        }

        // Read result — usually set during the evaluateScript above; pump more if needed
        // (e.g. multi-hop Promise chains that require additional microtask turns).
        for _ in 0..<maxPumps {
            if let r = ctx.evaluateScript("globalThis.__bgR"),
               !r.isNull, !r.isUndefined {
                ctx.evaluateScript("delete globalThis.__bgR")
                if r.objectForKeyedSubscript("ok")?.toInt32() == 1 {
                    return r.objectForKeyedSubscript("v") ?? JSValue(undefinedIn: ctx)!
                } else {
                    let err = r.objectForKeyedSubscript("e")?.toString() ?? "rejected"
                    throw BotGuardError.jsFailed("Promise '\(label)' rejected: \(err)")
                }
            }
            ctx.evaluateScript("undefined")   // additional microtask drain
        }

        throw BotGuardError.jsFailed("Promise '\(label)' did not settle after \(maxPumps) pumps")
    }
}
