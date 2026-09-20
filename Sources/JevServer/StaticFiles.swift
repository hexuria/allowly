import Foundation

actor StaticFiles {
    private let webRootPath: String?

    init(webRootPath: String?) {
        self.webRootPath = webRootPath
    }

    func serve(path: String, completion: @escaping (Data?, String) -> Void) async {
        guard let webRoot = webRootPath else {
            completion(nil, "text/plain")
            return
        }

        var filePath = path

        if filePath == "/" {
            filePath = "/index.html"
        }

        let sanitizedPath = sanitizePath(filePath)
        let fullPath = (webRoot as NSString).appendingPathComponent(sanitizedPath)

        if isPathSafe(fullPath, within: webRoot) {
            if let data = readFile(fullPath) {
                let mimeType = mimeTypeForPath(sanitizedPath)
                completion(data, mimeType)
                return
            }
        }

        completion(nil, "text/plain")
    }

    // MARK: - Path Handling

    private func sanitizePath(_ path: String) -> String {
        var result = path

        if result.hasPrefix("/") {
            result.removeFirst()
        }

        return result
    }

    /// Inside the web root, and not merely starting with its name.
    ///
    /// A bare `hasPrefix` says `/…/webfoo/secret` is inside `/…/web`,
    /// because the string starts the same way. `GET /../webfoo/secret`
    /// standardises to exactly that, and static files are served with no
    /// token — only `/api/` and `/ws` require one. Requiring the separator
    /// is what makes "inside" mean inside. (`..` traversal proper was
    /// already blocked by `standardizingPath` plus this test.)
    private func isPathSafe(_ fullPath: String, within webRoot: String) -> Bool {
        // Resolve symlinks, not just "..". `standardizingPath` is purely
        // lexical, so `web/x -> /Users/you/.ssh` made `GET /x/id_rsa`
        // look like it was inside the root — and static files need no
        // token. Needs write access to `web/` to exploit, so this is
        // depth rather than a live hole, but it is one call.
        let webRootResolved = URL(fileURLWithPath: webRoot).resolvingSymlinksInPath().path
        let pathResolved = URL(fileURLWithPath: fullPath).resolvingSymlinksInPath().path
        if pathResolved == webRootResolved { return true }
        let boundary = webRootResolved.hasSuffix("/") ? webRootResolved : webRootResolved + "/"
        return pathResolved.hasPrefix(boundary)
    }

    // MARK: - File I/O

    private func readFile(_ path: String) -> Data? {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: path) else {
            return nil
        }

        guard !isDirectory(path) else {
            return nil
        }

        return fileManager.contents(atPath: path)
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let fileManager = FileManager.default

        fileManager.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }

    // MARK: - MIME Types

    private func mimeTypeForPath(_ path: String) -> String {
        let pathLower = path.lowercased()

        if pathLower.hasSuffix(".html") || pathLower.hasSuffix(".htm") {
            return "text/html; charset=utf-8"
        } else if pathLower.hasSuffix(".css") {
            return "text/css; charset=utf-8"
        } else if pathLower.hasSuffix(".js") {
            return "application/javascript; charset=utf-8"
        } else if pathLower.hasSuffix(".json") {
            return "application/json; charset=utf-8"
        } else if pathLower.hasSuffix(".svg") {
            return "image/svg+xml"
        } else if pathLower.hasSuffix(".png") {
            return "image/png"
        } else if pathLower.hasSuffix(".jpg") || pathLower.hasSuffix(".jpeg") {
            return "image/jpeg"
        } else if pathLower.hasSuffix(".gif") {
            return "image/gif"
        } else if pathLower.hasSuffix(".ico") {
            return "image/x-icon"
        } else if pathLower.hasSuffix(".webp") {
            return "image/webp"
        } else if pathLower.hasSuffix(".woff") {
            return "font/woff"
        } else if pathLower.hasSuffix(".woff2") {
            return "font/woff2"
        } else if pathLower.hasSuffix(".ttf") {
            return "font/ttf"
        } else if pathLower.hasSuffix(".otf") {
            return "font/otf"
        } else if pathLower.hasSuffix(".mp3") {
            return "audio/mpeg"
        } else if pathLower.hasSuffix(".wav") {
            return "audio/wav"
        } else if pathLower.hasSuffix(".mp4") {
            return "video/mp4"
        } else if pathLower.hasSuffix(".webm") {
            return "video/webm"
        } else if pathLower.hasSuffix(".txt") {
            return "text/plain; charset=utf-8"
        } else if pathLower.hasSuffix(".xml") {
            return "application/xml; charset=utf-8"
        } else if pathLower.hasSuffix(".pdf") {
            return "application/pdf"
        } else if pathLower.hasSuffix(".zip") {
            return "application/zip"
        } else if pathLower.hasSuffix(".webmanifest") {
            return "application/manifest+json"
        } else {
            return "application/octet-stream"
        }
    }
}
