import Foundation

/// 云端转写 HTTP 发送（URLSession；对齐 Android HttpPosterImpl：连接 10s / 读 30s 超时）。
enum CloudPoster {
    static func transcribe(config: CloudTranscriberConfig, wav: Data,
                           completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: config.url) else {
            completion(.failure(TranscribeError.http(0, "URL 无效")))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(CloudCodec.contentType(config), forHTTPHeaderField: "Content-Type")
        if let auth = CloudCodec.authHeader(config) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = CloudCodec.buildBody(config, wav: wav)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(TranscribeError.http(0, error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let detail = String(body.prefix(300))
                completion(.failure(TranscribeError.http(status, detail)))
                return
            }
            do {
                let text = try CloudCodec.parseResponse(data ?? Data(), responseField: config.responseField)
                completion(.success(text))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }
}
