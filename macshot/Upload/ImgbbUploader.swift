#if !OFFLINE
import Cocoa

struct ImageUploadResult {
    let link: String
    let deleteURL: String
}

enum ImageUploader {

    private static let defaultAPIKey = "c2c63d156c6baa11136a464dcd22a404"

    static var apiKey: String {
        if let custom = UserDefaults.standard.string(forKey: "imgbbAPIKey"), !custom.isEmpty {
            return custom
        }
        return defaultAPIKey
    }

    static func upload(image: NSImage, completion: @escaping (Result<ImageUploadResult, Error>) -> Void) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            completion(.failure(NSError(domain: "ImageUploader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image"])))
            return
        }

        let base64String = pngData.base64EncodedString()

        var components = URLComponents(string: "https://api.imgbb.com/1/upload")
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))]
        guard let url = components?.url else {
            completion(.failure(NSError(domain: "ImageUploader", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid imgbb API key"])))
            return
        }

        // Build multipart form body
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // image field (base64)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"\r\n\r\n".data(using: .utf8)!)
        body.append(base64String.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "ImageUploader", code: 3, userInfo: [NSLocalizedDescriptionKey: "No response data"])))
                }
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let looksLikeJSON = (try? JSONSerialization.jsonObject(with: data)) != nil
            if !looksLikeJSON {
                // A CDN or proxy error page, not an API response.
                let message = statusCode >= 400
                    ? "imgbb returned HTTP \(statusCode)"
                    : "imgbb returned an unreadable response"
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "ImageUploader", code: 5,
                                                userInfo: [NSLocalizedDescriptionKey: message])))
                }
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success,
                      let dataDict = json["data"] as? [String: Any],
                      let imageURL = dataDict["url"] as? String,
                      let deleteURL = dataDict["delete_url"] as? String else {
                    // Try to extract error message
                    let errorMsg: String
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errData = json["error"] as? [String: Any],
                       let msg = errData["message"] as? String {
                        errorMsg = msg
                    } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let status = json["status_code"] as? Int {
                        errorMsg = "API error (status \(status))"
                    } else {
                        errorMsg = statusCode >= 400 ? "imgbb returned HTTP \(statusCode)" : "Unknown error"
                    }
                    DispatchQueue.main.async {
                        completion(.failure(NSError(domain: "ImageUploader", code: 4, userInfo: [NSLocalizedDescriptionKey: errorMsg])))
                    }
                    return
                }

                let result = ImageUploadResult(link: imageURL, deleteURL: deleteURL)
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

}
#endif
