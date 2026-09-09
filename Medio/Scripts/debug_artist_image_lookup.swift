#!/usr/bin/env swift

import Foundation

struct WikidataSearchResponse: Decodable {
    let search: [WikidataSearchResult]
}

struct WikidataSearchResult: Decodable {
    let id: String
    let label: String?
    let description: String?
}

struct WikidataClaimsResponse: Decodable {
    let claims: [String: [WikidataClaim]]?
}

struct WikidataClaim: Decodable {
    let mainsnak: WikidataSnak?
}

struct WikidataSnak: Decodable {
    let datavalue: WikidataDataValue?
}

struct WikidataDataValue: Decodable {
    let value: String?
}

struct CommonsResponse: Decodable {
    let query: CommonsQuery?
}

struct CommonsQuery: Decodable {
    let pages: [String: CommonsPage]?
}

struct CommonsPage: Decodable {
    let index: Int?
    let title: String
    let imageinfo: [CommonsImageInfo]?
}

struct CommonsImageInfo: Decodable {
    let url: String?
    let thumburl: String?
    let mime: String?
    let extmetadata: [String: CommonsMetadataValue]?
}

struct CommonsMetadataValue: Decodable {
    let value: String?

    enum CodingKeys: String, CodingKey {
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringValue = try? container.decode(String.self, forKey: .value) {
            value = stringValue
        } else if let intValue = try? container.decode(Int.self, forKey: .value) {
            value = String(intValue)
        } else if let doubleValue = try? container.decode(Double.self, forKey: .value) {
            value = String(doubleValue)
        } else if let boolValue = try? container.decode(Bool.self, forKey: .value) {
            value = String(boolValue)
        } else {
            value = nil
        }
    }
}

struct MusicBrainzSearchResponse: Decodable {
    let artists: [MusicBrainzArtist]
}

struct MusicBrainzArtist: Decodable {
    let id: String
    let name: String?
    let score: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        if let intScore = try? container.decode(Int.self, forKey: .score) {
            score = intScore
        } else if let stringScore = try? container.decode(String.self, forKey: .score) {
            score = Int(stringScore)
        } else {
            score = nil
        }
    }
}

struct MusicBrainzLookupResponse: Decodable {
    let relations: [MusicBrainzRelation]?
}

struct MusicBrainzRelation: Decodable {
    let type: String?
    let url: MusicBrainzRelationURL?
}

struct MusicBrainzRelationURL: Decodable {
    let resource: String?
}

let artists = Array(CommandLine.arguments.dropFirst())
let names = artists.isEmpty ? ["Taylor Swift", "The Weeknd", "Radiohead"] : artists
let debugger = LookupDebugger()

for name in names {
    print("\n=== \(name) ===")
    await debugger.inspectArtist(name)
}

final class LookupDebugger {
    private let session: URLSession
    private var lastMusicBrainzRequest: Date?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }

    func inspectArtist(_ artistName: String) async {
        let wikidataIDs = await inspectWikidata(artistName)
        if wikidataIDs.isEmpty {
            print("wikidata: no matching music-artist entity")
        }

        for entityID in wikidataIDs.prefix(4) {
            await inspectWikidataImage(entityID: entityID)
        }

        await inspectMusicBrainz(artistName)
        await inspectCommonsSearch("\(artistName) portrait singer musician band")
        await inspectCommonsSearch("\(artistName) concert singer musician band")
    }

    private func inspectWikidata(_ artistName: String) async -> [String] {
        guard let url = wikidataSearchURL(for: artistName) else { return [] }

        do {
            let response = try await decoded(WikidataSearchResponse.self, from: url, service: "wikimedia")
            let normalizedArtistName = normalizedSearchText(artistName)
            let matching = response.search.filter { result in
                let label = normalizedSearchText(result.label ?? "")
                let description = normalizedSearchText(result.description ?? "")
                let labelMatches = label == normalizedArtistName
                    || label.contains(normalizedArtistName)
                    || normalizedArtistName.contains(label)
                return labelMatches && descriptionLooksLikeMusicArtist(description)
            }
            for result in response.search {
                print("wikidata candidate: \(result.id) | \(result.label ?? "?") | \(result.description ?? "?")")
            }
            return matching.map(\.id)
        } catch {
            print("wikidata search failed: \(error)")
            return []
        }
    }

    private func inspectWikidataImage(entityID: String) async {
        guard let url = wikidataClaimsURL(entityID: entityID) else { return }

        do {
            let response = try await decoded(WikidataClaimsResponse.self, from: url, service: "wikimedia")
            guard let fileName = response.claims?["P18"]?.first?.mainsnak?.datavalue?.value else {
                print("wikidata \(entityID): no P18 image")
                return
            }
            print("wikidata \(entityID): P18 File:\(fileName)")
            await inspectCommonsFile("File:\(fileName)", source: "wikidata \(entityID)")
        } catch {
            print("wikidata \(entityID): claims failed: \(error)")
        }
    }

    private func inspectMusicBrainz(_ artistName: String) async {
        guard let url = musicBrainzSearchURL(for: artistName) else { return }

        do {
            let search = try await decoded(MusicBrainzSearchResponse.self, from: url, service: "musicbrainz")
            for artist in search.artists.prefix(3) {
                print("musicbrainz candidate: \(artist.id) | \(artist.name ?? "?") | score \(artist.score.map(String.init) ?? "?")")
                guard (artist.score ?? 100) >= 75, let lookupURL = musicBrainzLookupURL(id: artist.id) else { continue }
                let detail = try await decoded(MusicBrainzLookupResponse.self, from: lookupURL, service: "musicbrainz")
                let resources = (detail.relations ?? []).compactMap(\.url?.resource)
                for resource in resources where resource.contains("wikidata.org") || resource.contains("wikimedia.org") || resource.contains("wikipedia.org") {
                    print("musicbrainz relation: \(resource)")
                }
            }
        } catch {
            print("musicbrainz failed: \(error)")
        }
    }

    private func inspectCommonsSearch(_ query: String) async {
        guard let url = commonsSearchURL(for: query) else { return }

        do {
            let response = try await decoded(CommonsResponse.self, from: url, service: "wikimedia")
            let pages = response.query?.pages?.values.sorted {
                ($0.index ?? Int.max) < ($1.index ?? Int.max)
            } ?? []
            print("commons search: \(query)")
            for page in pages.prefix(5) {
                guard let info = page.imageinfo?.first else {
                    print("  skip: \(page.title) | no imageinfo")
                    continue
                }
                print("  \(candidateSummary(page: page, info: info))")
            }
        } catch {
            print("commons search failed for \(query): \(error)")
        }
    }

    private func inspectCommonsFile(_ title: String, source: String) async {
        guard let url = imageInfoURL(forTitle: title) else { return }

        do {
            let response = try await decoded(CommonsResponse.self, from: url, service: "wikimedia")
            let pages = response.query?.pages?.values.sorted {
                ($0.index ?? Int.max) < ($1.index ?? Int.max)
            } ?? []
            guard let page = pages.first, let info = page.imageinfo?.first else {
                print("\(source): no Commons imageinfo for \(title)")
                return
            }
            print("\(source): \(candidateSummary(page: page, info: info))")
            if info.isSupportedRasterImage,
               licenseAllows(info.extmetadata),
               let rawImageURL = info.thumburl ?? info.url,
               let imageURL = URL(string: rawImageURL) {
                await verifyImageDownload(imageURL)
            }
        } catch {
            print("\(source): Commons imageinfo failed for \(title): \(error)")
        }
    }

    private func candidateSummary(page: CommonsPage, info: CommonsImageInfo) -> String {
        let license = plainText(info.extmetadata?["LicenseShortName"]?.value ?? "unknown")
        let url = info.thumburl ?? info.url ?? "no-url"
        let allowed = licenseAllows(info.extmetadata) ? "license ok" : "license rejected"
        let raster = info.isSupportedRasterImage ? "raster ok" : "not raster"
        return "\(page.title) | \(info.mime ?? "mime ?") | \(license) | \(raster) | \(allowed) | \(url)"
    }

    private func verifyImageDownload(_ url: URL) async {
        do {
            let (data, response) = try await data(from: url, service: "wikimedia")
            let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            print("download ok: \(data.count) bytes | \(contentType)")
        } catch {
            print("download failed: \(error)")
        }
    }

    private func decoded<T: Decodable>(_ type: T.Type, from url: URL, service: String) async throws -> T {
        let (data, _) = try await data(from: url, service: service)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func data(from url: URL, service: String) async throws -> (Data, HTTPURLResponse) {
        if service == "musicbrainz" {
            await waitForMusicBrainz()
        }

        var request = URLRequest(url: url)
        request.setValue("MedioDebug/1.0 local artist image lookup", forHTTPHeaderField: "User-Agent")
        request.setValue(url.path.hasSuffix("/w/api.php") || url.host == "api.wikimedia.org" || service == "musicbrainz" ? "application/json" : "*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    private func waitForMusicBrainz() async {
        if let lastMusicBrainzRequest {
            let delay = 1.1 - Date().timeIntervalSince(lastMusicBrainzRequest)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        lastMusicBrainzRequest = Date()
    }

    private func wikidataSearchURL(for artistName: String) -> URL? {
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbsearchentities"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "type", value: "item"),
            URLQueryItem(name: "search", value: artistName),
            URLQueryItem(name: "limit", value: "5")
        ]
        return components?.url
    }

    private func wikidataClaimsURL(entityID: String) -> URL? {
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbgetclaims"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "entity", value: entityID),
            URLQueryItem(name: "property", value: "P18")
        ]
        return components?.url
    }

    private func imageInfoURL(forTitle title: String) -> URL? {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "titles", value: normalizedWikiTitle(title, prefix: "File")),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|mime|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "640")
        ]
        return components?.url
    }

    private func commonsSearchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrsearch", value: query),
            URLQueryItem(name: "gsrlimit", value: "12"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|mime|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "640")
        ]
        return components?.url
    }

    private func musicBrainzSearchURL(for artistName: String) -> URL? {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist")
        components?.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(artistName)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "3")
        ]
        return components?.url
    }

    private func musicBrainzLookupURL(id: String) -> URL? {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist/\(id)")
        components?.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "inc", value: "url-rels")
        ]
        return components?.url
    }
}

private extension CommonsImageInfo {
    var isSupportedRasterImage: Bool {
        if let mime = mime?.lowercased(), !mime.isEmpty {
            return ["image/jpeg", "image/png", "image/webp"].contains(mime)
        }
        guard let rawImageURL = url ?? thumburl,
              let imageURL = URL(string: rawImageURL) else {
            return false
        }
        return imageURL.isSupportedRasterImageURL
    }
}

private extension URL {
    var isSupportedRasterImageURL: Bool {
        let lowercasedPath = path.lowercased()
        return lowercasedPath.hasSuffix(".jpg")
            || lowercasedPath.hasSuffix(".jpeg")
            || lowercasedPath.hasSuffix(".png")
            || lowercasedPath.hasSuffix(".webp")
    }
}

private func licenseAllows(_ metadata: [String: CommonsMetadataValue]?) -> Bool {
    let values = metadata ?? [:]
    let joined = values.values
        .compactMap(\.value)
        .map(plainText)
        .joined(separator: " ")
        .lowercased()

    if joined.contains("noncommercial")
        || joined.contains("non-commercial")
        || joined.contains("by-nc")
        || joined.contains("by nc")
        || joined.contains("no derivative")
        || joined.contains("no-derivative")
        || joined.contains("nonderivative")
        || joined.contains("by-nd")
        || joined.contains("by nd")
        || joined.contains("fair use")
        || joined.contains("all rights reserved") {
        return false
    }

    return joined.contains("cc0")
        || joined.contains("public domain")
        || joined.contains("/publicdomain/zero/1.0")
        || joined.contains("/publicdomain/mark/1.0")
        || joined.contains("creative commons attribution-share alike")
        || joined.contains("creative commons attribution share alike")
        || joined.contains("creative commons attribution")
        || joined.contains("cc by-sa")
        || joined.contains("cc-by-sa")
        || joined.contains("cc by ")
        || joined.contains("cc-by ")
        || joined.contains("creativecommons.org/licenses/by/")
        || joined.contains("creativecommons.org/licenses/by-sa/")
        || joined.contains("gnu free documentation license")
        || joined.contains("gfdl")
        || joined.contains("free art license")
}

private func plainText(_ html: String) -> String {
    html
        .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#039;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedSearchText(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
}

private func descriptionLooksLikeMusicArtist(_ description: String) -> Bool {
    [
        "singer",
        "songwriter",
        "musician",
        "band",
        "rapper",
        "composer",
        "producer",
        "dj",
        "vocalist",
        "instrumentalist",
        "recording artist",
        "musical artist",
        "musical group",
        "music group",
        "music duo",
        "music trio",
        "electronic music",
        "hip hop group",
        "pop group",
        "rock group",
        "orchestra",
        "choir",
        "disc jockey",
        "record producer",
        "girl group",
        "boy band",
        "vocal group",
        "jazz ensemble"
    ].contains { description.contains($0) }
}

private func normalizedWikiTitle(_ title: String, prefix: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let wantedPrefix = "\(prefix):"
    if trimmed.range(of: wantedPrefix, options: [.caseInsensitive, .anchored]) != nil {
        return trimmed
    }
    let components = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
    if components.count == 2, ["file", "category"].contains(components[0].lowercased()) {
        return "\(wantedPrefix)\(components[1])"
    }
    return "\(wantedPrefix)\(trimmed)"
}
