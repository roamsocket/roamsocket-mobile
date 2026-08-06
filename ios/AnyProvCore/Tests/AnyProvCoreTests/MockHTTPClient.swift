import Foundation
@testable import MobileAICore

/// Returns canned responses keyed by URL substring, for provider tests.
struct MockHTTPClient: HTTPClient {
    var routes: [(match: String, status: Int, body: Data)]

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url?.absoluteString ?? ""
        guard let route = routes.first(where: { url.contains($0.match) }) else {
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data("no route".utf8), resp)
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: nil)!
        return (route.body, resp)
    }
}

func json(_ string: String) -> Data { Data(string.utf8) }
