import Foundation

/// Discrete, non-overlapping token classes for one request or turn. `pureInput`
/// and `pureOutput` exclude cache reads and writes.
public struct TokenCostSpec: Equatable, Sendable {
    public var pureInput = 0
    public var pureOutput = 0
    public var cacheRead = 0
    /// Cache writes at the provider's ordinary (Claude: 5-minute) write rate.
    public var cacheWrite = 0
    /// Claude 1-hour cache writes, billed at twice input.
    public var cacheWrite1h = 0

    public init(pureInput: Int = 0, pureOutput: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0) {
        (self.pureInput, self.pureOutput, self.cacheRead, self.cacheWrite, self.cacheWrite1h) =
            (pureInput, pureOutput, cacheRead, cacheWrite, cacheWrite1h)
    }

    var prompt: Int { max(pureInput, 0) + max(cacheRead, 0) + max(cacheWrite, 0) + max(cacheWrite1h, 0) }
}

/// Why a cost could not be computed. Unavailable is never the same as free.
public enum CostUnavailable: Error, Equatable, Sendable {
    case modelPrice, cacheReadPrice, cacheWritePrice, cacheWriteHourPrice, requestBoundaries
}

/// One OpenRouter rate, USD per million tokens. A nil cache rate is unknown, not zero.
public struct CatalogPrice: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double?
    public var cacheWrite: Double?

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        (self.input, self.output, self.cacheRead, self.cacheWrite) = (input, output, cacheRead, cacheWrite)
    }
}

/// Model prices: agmux's built-in table first, then the OpenRouter catalog
/// (`GET https://openrouter.ai/api/v1/models`) for models the table lacks.
///
/// Catalog matches are exact: a full `vendor/id`, or a bare slug only when one
/// listed model has it. Rows with conditional (`overrides`) tariffs are dropped.
/// Catalog prices expire 24 hours after `fetchedAt`; the built-in table never does.
public struct PriceCatalog: Sendable {
    /// Catalog prices are trusted for this long after the fetch.
    public static let catalogLifetime: TimeInterval = 24 * 3600
    /// The built-in table alone.
    public static let builtIn = PriceCatalog(entries: [], fetchedAt: .distantPast)

    public let fetchedAt: Date
    private let byID: [String: CatalogPrice?]
    private let bySlug: [String: CatalogPrice?]

    /// Malformed or unexpected shapes in the OpenRouter response.
    public enum ParseError: Error, Equatable {
        case notAModelList, noPricedModels
    }

    /// Builds the catalog from the body of OpenRouter's `/api/v1/models`.
    /// Throws when the body is not a model list or prices no model at all.
    public init(openRouterJSON data: Data, fetchedAt: Date = Date()) throws {
        guard let rows = JSONValue.parse(data: data)?["data"]?.array else { throw ParseError.notAModelList }
        let entries = try Self.entries(fromOpenRouter: rows)
        if entries.isEmpty { throw ParseError.noPricedModels }
        self.init(entries: entries, fetchedAt: fetchedAt)
    }

    init(entries: [CatalogEntry], fetchedAt: Date) {
        var byID: [String: CatalogPrice?] = [:]
        var bySlug: [String: CatalogPrice?] = [:]
        for e in entries {
            let id = asciiLowercased(e.id.trimmingCharacters(in: .whitespacesAndNewlines))
            let slug = Self.slug(of: id)
            // Duplicate IDs and shared slugs stay unavailable even when prices coincide.
            bySlug[slug] = bySlug[slug] == nil ? (e.bareAmbiguous ? .some(nil) : .some(e.price)) : .some(nil)
            byID[id] = byID[id] == nil ? .some(e.price) : .some(nil)
        }
        (self.byID, self.bySlug, self.fetchedAt) = (byID, bySlug, fetchedAt)
    }

    /// The catalog rate for an exact ID or unambiguous bare slug, while fresh.
    public func catalogPrice(for model: String) -> CatalogPrice? {
        let age = Date().timeIntervalSince(fetchedAt)
        guard age >= 0, age < Self.catalogLifetime else { return nil }
        let key = asciiLowercased(model.trimmingCharacters(in: .whitespacesAndNewlines))
        let table = key.contains("/") ? byID : bySlug
        return table[key] ?? nil
    }

    // MARK: - Cost

    /// Cost of one request. Long-context steps and Claude's 1-hour cache rate are
    /// applied per request, so a session sum can never trip a context tier.
    public func cost(model: String?, _ spec: TokenCostSpec) -> Result<Double, CostUnavailable> {
        guard let name = model?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return .failure(.modelPrice)
        }
        guard let priced = pricing(model: name) else { return .failure(.modelPrice) }
        if let catalog = priced.catalog {
            // A generic catalog write rate does not establish a 1-hour tariff.
            if spec.cacheWrite1h > 0 { return .failure(.cacheWriteHourPrice) }
            if spec.cacheRead > 0, catalog.cacheRead == nil { return .failure(.cacheReadPrice) }
            if spec.cacheWrite > 0, catalog.cacheWrite == nil { return .failure(.cacheWritePrice) }
        }
        var r = priced.rates
        if let step = PriceTable.longContextStep(model: name), spec.prompt > step.threshold {
            r = Rates(input: r.input * step.inputMultiplier, output: r.output * step.outputMultiplier,
                      cacheRead: r.cacheRead * step.inputMultiplier, cacheWrite: r.cacheWrite * step.inputMultiplier)
        }
        let hourWrite = priced.catalog == nil && PriceTable.key(name).hasPrefix("claude-") && r.cacheWrite > 0
            ? r.input * 2 : r.cacheWrite
        let parts: [(Int, Double)] = [(spec.pureInput, r.input), (spec.pureOutput, r.output), (spec.cacheRead, r.cacheRead),
                                      (spec.cacheWrite, r.cacheWrite), (spec.cacheWrite1h, hourWrite)]
        return .success(parts.reduce(0) { $0 + Double(max($1.0, 0)) / 1_000_000 * $1.1 })
    }

    /// Prices a group of requests only when its total prompt proves every request
    /// was below the model's context step; otherwise request boundaries are needed.
    public func aggregatedCost(model: String?, _ spec: TokenCostSpec) -> Result<Double, CostUnavailable> {
        if let name = model, let step = PriceTable.longContextStep(model: name), spec.prompt > step.threshold {
            return .failure(.requestBoundaries)
        }
        return cost(model: model, spec)
    }

    /// agmux `cost_for_checked`: reprices an event from its own token classes,
    /// with every cache write at the ordinary write rate. Unknown prices give
    /// `(0, true)`. Transcript readers already set `costUSD` with their fuller rules.
    public func cost(for event: UsageEvent) -> (usd: Double, incomplete: Bool) {
        let spec = TokenCostSpec(pureInput: event.tokensIn, pureOutput: event.tokensOut,
                                 cacheRead: event.cacheRead, cacheWrite: event.cacheWrite)
        switch cost(model: event.model, spec) {
        case .success(let usd): return (usd, false)
        case .failure: return (0, true)
        }
    }

    /// Whether a known write-class rate differs from ordinary input pricing, so a
    /// missing write counter cannot be treated as zero. False for unknown models.
    public func requiresCacheWriteUsage(model: String) -> Bool {
        guard let priced = pricing(model: model) else { return false }
        if let catalog = priced.catalog, catalog.cacheWrite == nil { return false }
        return priced.rates.cacheWrite != priced.rates.input
    }

    private func pricing(model: String) -> (rates: Rates, catalog: CatalogPrice?)? {
        if let rates = PriceTable.rates(model: model) { return (rates, nil) }
        guard let c = catalogPrice(for: model) else { return nil }
        return (Rates(input: c.input, output: c.output, cacheRead: c.cacheRead ?? 0, cacheWrite: c.cacheWrite ?? 0), c)
    }

    // MARK: - OpenRouter parsing

    struct CatalogEntry: Equatable {
        var id: String
        var bareAmbiguous: Bool
        var price: CatalogPrice
    }

    static func slug(of id: String) -> String {
        id.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? id
    }

    /// OpenRouter rows to priced entries. Unpriceable rows still count toward slug
    /// ambiguity. A wrongly typed field rejects the whole list, as serde does.
    static func entries(fromOpenRouter rows: [JSONValue]) throws -> [CatalogEntry] {
        let ids = try rows.map { row -> String in
            guard let id = row["id"]?.string else { throw ParseError.notAModelList }
            return id
        }
        let normalized = ids.map { asciiLowercased($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let idCounts = Dictionary(normalized.map { ($0, 1) }, uniquingKeysWith: +)
        let slugCounts = Dictionary(normalized.map { (slug(of: $0), 1) }, uniquingKeysWith: +)
        var out: [CatalogEntry] = []
        for (row, (id, key)) in zip(rows, zip(ids, normalized)) {
            guard idCounts[key] == 1, let pricing = try pricingFields(row["pricing"]) else { continue }
            // No request instant or override evaluator: a base rate could underprice.
            if let overrides = pricing.overrides, overrides != .null, overrides.array?.isEmpty != true { continue }
            guard let input = pricing.prompt.flatMap(tokenPrice), let output = pricing.completion.flatMap(tokenPrice) else { continue }
            let rowSlug = asciiLowercased(slug(of: id))
            if rowSlug.isEmpty || rowSlug == "free" { continue }
            out.append(CatalogEntry(id: id, bareAmbiguous: (slugCounts[rowSlug] ?? 0) > 1, price: CatalogPrice(
                input: input, output: output,
                cacheRead: pricing.cacheRead.flatMap(tokenPrice), cacheWrite: pricing.cacheWrite.flatMap(tokenPrice))))
        }
        return out
    }

    private struct PricingFields {
        var prompt, completion, cacheRead, cacheWrite: String?
        var overrides: JSONValue?
    }

    private static func pricingFields(_ value: JSONValue?) throws -> PricingFields? {
        guard let value, value != .null else { return nil }
        guard value.isObject else { throw ParseError.notAModelList }
        func text(_ key: String) throws -> String? {
            switch value[key] {
            case nil, .null?: return nil
            case .string(let s)?: return s
            default: throw ParseError.notAModelList
            }
        }
        return PricingFields(prompt: try text("prompt"), completion: try text("completion"),
                             cacheRead: try text("input_cache_read"), cacheWrite: try text("input_cache_write"),
                             overrides: value["overrides"])
    }

    /// OpenRouter's USD-per-token string to USD per million tokens; nil when invalid.
    static func tokenPrice(_ text: String) -> Double? {
        guard let perToken = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              perToken.isFinite, perToken >= 0 else { return nil }
        let perMillion = perToken * 1_000_000
        return perMillion.isFinite ? perMillion : nil
    }
}
