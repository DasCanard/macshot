#if !OFFLINE
import Cocoa
import CryptoKit
import UniformTypeIdentifiers

/// S3-compatible uploader that works with AWS S3, Cloudflare R2, MinIO, etc.
/// Uses AWS Signature V4 for authentication — no AWS SDK dependency.
final class S3Uploader {

    static let shared = S3Uploader()

    // MARK: - Configuration

    struct Config {
        let endpoint: String      // e.g. "https://abc123.r2.cloudflarestorage.com"
        let region: String        // e.g. "auto" for R2, "us-east-1" for AWS
        let bucket: String
        let accessKeyID: String
        let secretAccessKey: String
        let publicURLBase: String // e.g. "https://cdn.example.com" — used for the final link
        let pathPrefix: String    // e.g. "screenshots/" — optional prefix within bucket
        let publicRead: Bool      // send `x-amz-acl: public-read` so the object is world-readable

        var isValid: Bool {
            !endpoint.isEmpty && !bucket.isEmpty && !accessKeyID.isEmpty
                && !secretAccessKey.isEmpty && !effectiveRegion.isEmpty
        }

        /// The region to sign with. Clearing the settings field stores "", not
        /// nil, which defeated the `?? "auto"` default and produced a credential
        /// scope with an empty region — surfacing as SignatureDoesNotMatch,
        /// which points nowhere near the empty field.
        var effectiveRegion: String {
            let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "auto" : trimmed
        }
    }

    var config: Config {
        let ud = UserDefaults.standard
        return Config(
            endpoint: ud.string(forKey: "s3Endpoint") ?? "",
            region: ud.string(forKey: "s3Region") ?? "auto",
            bucket: ud.string(forKey: "s3Bucket") ?? "",
            accessKeyID: ud.string(forKey: "s3AccessKeyID") ?? "",
            secretAccessKey: ud.string(forKey: "s3SecretAccessKey") ?? "",
            publicURLBase: ud.string(forKey: "s3PublicURLBase") ?? "",
            pathPrefix: ud.string(forKey: "s3PathPrefix") ?? "",
            publicRead: ud.bool(forKey: "s3PublicRead")
        )
    }

    var isConfigured: Bool { config.isValid }

    /// Progress callback (0.0–1.0), called on main thread.
    var onProgress: ((Double) -> Void)?

    // MARK: - Upload Image

    func uploadImage(_ image: NSImage, completion: @escaping (Result<String, Error>) -> Void) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            completion(.failure(S3Error.encodingFailed))
            return
        }
        let template = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
        let base = FilenameFormatter.format(template: template)
        let filename = "\(base).png"
        upload(data: pngData, filename: filename, contentType: "image/png", completion: completion)
    }

    // MARK: - Upload Video

    func uploadVideo(url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            completion(.failure(S3Error.fileReadFailed))
            return
        }
        let ext = url.pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "gif": contentType = "image/gif"
        case "mp4": contentType = "video/mp4"
        case "mov": contentType = "video/quicktime"
        case "webm": contentType = "video/webm"
        default: contentType = "application/octet-stream"
        }
        // Streamed from disk — a recording can be larger than the memory the
        // app can hold, and the SigV4 content hash is computed incrementally.
        upload(payload: .file(url), filename: url.lastPathComponent, contentType: contentType, completion: completion)
    }

    // MARK: - Core Upload

    func upload(data: Data, filename: String, contentType: String, completion: @escaping (Result<String, Error>) -> Void) {
        upload(payload: .data(data), filename: filename, contentType: contentType, completion: completion)
    }

    func upload(payload: UploadPayload, filename: String, contentType: String, completion: @escaping (Result<String, Error>) -> Void) {
        let cfg = config
        guard cfg.isValid else {
            completion(.failure(S3Error.notConfigured))
            return
        }

        // Build object key with optional prefix
        var prefix = cfg.pathPrefix
        if !prefix.isEmpty && !prefix.hasSuffix("/") { prefix += "/" }
        // Sanitize filename: replace spaces, keep extension
        let safeFilename = filename.replacingOccurrences(of: " ", with: "_")
        let objectKey = "\(prefix)\(safeFilename)"

        // Parse endpoint to get host
        guard let endpointURL = URL(string: cfg.endpoint),
              let host = endpointURL.host else {
            completion(.failure(S3Error.invalidEndpoint))
            return
        }

        // Build the request URL: endpoint/bucket/key (path-style)
        let scheme = endpointURL.scheme ?? "https"
        let port = endpointURL.port.map { ":\($0)" } ?? ""
        let encodedKey = objectKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? objectKey
        // Keep any path the endpoint carries — a self-hosted MinIO or Ceph
        // gateway behind a proxy lives at e.g. https://files.example.com/s3,
        // and dropping the prefix uploaded to the host root instead.
        let basePath = endpointURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefixPath = basePath.isEmpty ? "" : "/\(basePath)"
        let urlString = "\(scheme)://\(host)\(port)\(prefixPath)/\(cfg.bucket)/\(encodedKey)"
        guard let url = URL(string: urlString) else {
            completion(.failure(S3Error.invalidEndpoint))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(host)\(port)", forHTTPHeaderField: "Host")
        // Providers that honour object ACLs (AWS S3, DigitalOcean Spaces, MinIO, Backblaze B2)
        // store objects privately by default, so the public link 403s. Opt-in because R2 has
        // no ACLs and rejects the header outright.
        if cfg.publicRead {
            request.setValue("public-read", forHTTPHeaderField: "x-amz-acl")
        }

        // Sign the request. The payload hash is computed by streaming, so a
        // large recording never has to be held in memory to be signed.
        let now = Date()
        let payloadHash: String
        do {
            payloadHash = try payload.sha256Hex()
        } catch {
            completion(.failure(S3Error.fileReadFailed))
            return
        }
        signRequest(&request, payloadHash: payloadHash, date: now, region: cfg.effectiveRegion,
                     accessKeyID: cfg.accessKeyID, secretAccessKey: cfg.secretAccessKey)

        // Upload from a file so URLSession streams the body off disk.
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot_upload_\(UUID().uuidString).tmp")
        do {
            try payload.write(to: bodyFile)
        } catch {
            completion(.failure(S3Error.fileReadFailed))
            return
        }

        let task = URLSession.shared.uploadTask(with: request, fromFile: bodyFile) { [weak self] responseData, response, error in
            try? FileManager.default.removeItem(at: bodyFile)
            DispatchQueue.main.async { self?.onProgress = nil }

            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(S3Error.noResponse)) }
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let body = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                // Try to extract error message from XML response
                let msg = Self.extractXMLError(body) ?? "HTTP \(httpResponse.statusCode)"
                DispatchQueue.main.async {
                    completion(.failure(S3Error.httpError(httpResponse.statusCode, msg)))
                }
                return
            }

            // Build the public URL
            let publicLink: String
            if !cfg.publicURLBase.isEmpty {
                var base = cfg.publicURLBase
                if !base.hasSuffix("/") { base += "/" }
                publicLink = "\(base)\(encodedKey)"
            } else {
                publicLink = urlString
            }

            DispatchQueue.main.async { completion(.success(publicLink)) }
        }

        // Observe progress
        if onProgress != nil {
            let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                DispatchQueue.main.async { self?.onProgress?(progress.fractionCompleted) }
            }
            // Store observation to keep it alive — released when task completes
            objc_setAssociatedObject(task, &Self.progressObservationKey, observation, .OBJC_ASSOCIATION_RETAIN)
        }

        task.resume()
    }

    private static var progressObservationKey: UInt8 = 0

    // MARK: - AWS Signature V4

    private func signRequest(_ request: inout URLRequest, payloadHash: String, date: Date,
                              region: String, accessKeyID: String, secretAccessKey: String) {
        let service = "s3"
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatter.string(from: date)

        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: date)

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")

        // Content hash (streamed by the caller)
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

        // Canonical request
        let method = request.httpMethod ?? "PUT"
        let url = request.url!
        // URI-encode path components per S3 Sig V4 spec (but preserve slashes)
        let rawPath = url.path.isEmpty ? "/" : url.path
        let canonicalURI = rawPath.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let canonicalQueryString = url.query ?? ""

        // Signed headers (sorted). x-amz-acl is only present when the user opted into
        // public-read; sending it unsigned would fail the signature check.
        var signedHeaderNames = ["content-type", "host", "x-amz-content-sha256", "x-amz-date"]
        if request.value(forHTTPHeaderField: "x-amz-acl") != nil {
            signedHeaderNames.append("x-amz-acl")
            signedHeaderNames.sort()
        }
        let signedHeadersString = signedHeaderNames.joined(separator: ";")

        var canonicalHeaders = ""
        for name in signedHeaderNames {
            let value = request.value(forHTTPHeaderField: name) ?? ""
            canonicalHeaders += "\(name):\(value.trimmingCharacters(in: .whitespaces))\n"
        }

        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQueryString,
            canonicalHeaders,
            signedHeadersString,
            payloadHash
        ].joined(separator: "\n")

        // String to sign
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let canonicalRequestHash = SHA256.hash(data: Data(canonicalRequest.utf8)).hexString
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(credentialScope)\n\(canonicalRequestHash)"

        // Signing key
        let kDate = Self.hmacSHA256(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = Self.hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = Self.hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = Self.hmacSHA256(key: kService, data: Data("aws4_request".utf8))

        // Signature
        let signature = Self.hmacSHA256(key: kSigning, data: Data(stringToSign.utf8)).hexString

        // Authorization header
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeadersString), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    private static func hmacSHA256(key: Data, data: Data) -> Data {
        let key = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(mac)
    }

    // MARK: - Helpers


    private static func extractXMLError(_ body: String) -> String? {
        // Simple extraction of <Message>...</Message> from S3 XML error responses
        guard let start = body.range(of: "<Message>"),
              let end = body.range(of: "</Message>") else { return nil }
        return String(body[start.upperBound..<end.lowerBound])
    }

    // MARK: - Errors

    enum S3Error: LocalizedError {
        case notConfigured
        case invalidEndpoint
        case encodingFailed
        case fileReadFailed
        case noResponse
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "S3 not configured — check Settings"
            case .invalidEndpoint: return "Invalid S3 endpoint URL"
            case .encodingFailed: return "Failed to encode image"
            case .fileReadFailed: return "Failed to read file"
            case .noResponse: return "No response from server"
            case .httpError(let code, let msg): return "S3 error (\(code)): \(msg)"
            }
        }
    }
}

// MARK: - SHA256 hex helper

private extension SHA256Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
#endif
