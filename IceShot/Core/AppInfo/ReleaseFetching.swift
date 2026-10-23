import Foundation

/// 拉取最新 Release 的抽象。
///
/// 抽成协议只为一件事：`UpdateChecker` 的节流 / 去重 / 提示逻辑要能在单测里跑，
/// 而单测不该真的打网络。生产实现见 `GitHubReleaseClient`，测试注入假实现。
protocol ReleaseFetching: Sendable {
    func latestRelease() async throws -> RemoteRelease
}

/// 检查失败的统一语义。
///
/// 不区分超时 / 非 200 / 解码失败：对用户来说这几种都是「现在查不到」，
/// 后台提示静默、手动检查给同一句话，没必要让用户知道是哪一种。
enum ReleaseFetchError: Error {
    /// 网络层错误、非 2xx、或返回体无法解析。
    case unavailable
    /// 仓库里一条已发布的 Release 都没有。
    case noRelease
}

/// `api.github.com` 的最小客户端。
///
/// 只请求一次列表接口，取第一条非草稿的 Release，字段用完即弃。
/// 不携带任何标识：没有 User-Agent 里的设备信息（只放 Apple 要求的应用名与版本，
/// 这是 HTTP 客户端身份，不是用户标识）、没有 token、没有查询参数。
struct GitHubReleaseClient: ReleaseFetching {
    static let repository = "aice109/ice-shot"

    private let session: URLSession

    /// 作默认参数时要能在非隔离上下文求值，所以和 `AppVersion` 一样显式 nonisolated。
    nonisolated init(session: URLSession = GitHubReleaseClient.makeSession()) {
        self.session = session
    }

    /// 超时压到 10 秒：接口通常 1 秒内返回，用户不该为一个后台检查等一分钟。
    nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        // 更新检查总要用最新的答案，任何一层缓存都可能让用户看到过期版本。
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            "User-Agent": "IceShot/\(AppVersion.shortVersion)",
        ]
        return URLSession(configuration: configuration)
    }

    func latestRelease() async throws -> RemoteRelease {
        guard let url = URL(
            string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=1"
        ) else {
            throw ReleaseFetchError.unavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReleaseFetchError.unavailable
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw ReleaseFetchError.unavailable
        }

        let payloads: [Payload]
        do {
            payloads = try JSONDecoder().decode([Payload].self, from: data)
        } catch {
            throw ReleaseFetchError.unavailable
        }

        // 列表端点按发布时间倒序，取第一条已发布（非草稿）的即可。
        guard let payload = payloads.first(where: { !$0.draft }) else {
            throw ReleaseFetchError.noRelease
        }
        guard let htmlURL = URL(string: payload.htmlURL) else {
            throw ReleaseFetchError.unavailable
        }

        return RemoteRelease(
            tagName: payload.tagName,
            htmlURL: htmlURL,
            notes: payload.body ?? "",
            diskImage: Self.diskImage(in: payload.assets)
        )
    }

    /// 挑选 `.dmg` 资产，并配上同名 `.sha256` 文件的地址。
    ///
    /// 找不到 `.dmg` 就返回 `nil`：调用侧会退回网页下载，不猜到别的文件类型。
    /// 校验值本身在下载完 `.sha256` 后才解析（需要发一次小请求），
    /// 所以这里只带地址，不带值。
    static func diskImage(in assets: [Payload.Asset]) -> ReleaseAsset? {
        guard let dmg = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
              let dmgURL = URL(string: dmg.browserDownloadURL)
        else {
            return nil
        }

        let checksumAsset = assets.first { $0.name == dmg.name + ".sha256" }
        let checksumTextURL = checksumAsset.flatMap { URL(string: $0.browserDownloadURL) }

        return ReleaseAsset(
            name: dmg.name,
            url: dmgURL,
            checksumTextURL: checksumTextURL
        )
    }

    /// 只解码用得到的字段；缺失的 `body` 用 `nil` 兜住，不当成错误。
    struct Payload: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let draft: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case draft
            case assets
        }
    }
}
