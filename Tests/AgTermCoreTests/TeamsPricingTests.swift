import XCTest
@testable import AgTermCore

/// Ported from agmux `commands/usage_stats.rs` pricing tests, `pricing_catalog.rs`
/// tests and `teams/scan/mod.rs` `current_models_use_shared_prices_for_team_costs`.
final class TeamsPricingTests: XCTestCase {
    let builtIn = PriceCatalog.builtIn

    func rates(_ model: String) -> Rates? { PriceTable.rates(model: model) }

    func catalog(_ entries: [(String, CatalogPrice)]) -> PriceCatalog {
        PriceCatalog(entries: entries.map { PriceCatalog.CatalogEntry(id: $0.0, bareAmbiguous: false, price: $0.1) }, fetchedAt: Date())
    }

    func fixture(_ json: String, fetchedAt: Date = Date()) throws -> PriceCatalog {
        let rows = try XCTUnwrap(JSONValue.parse(json)?.array)
        return PriceCatalog(entries: try PriceCatalog.entries(fromOpenRouter: rows), fetchedAt: fetchedAt)
    }

    func cost(_ model: String, _ spec: TokenCostSpec, _ prices: PriceCatalog = .builtIn) -> Double {
        (try? prices.cost(model: model, spec).get()) ?? 0
    }

    // MARK: - Built-in table

    func testModelPricingKnownRates() {
        let cases: [(String, Double, Double)] = [
            ("claude-opus-4-6", 5, 25), ("claude-haiku-4-5", 1, 5), ("claude-sonnet-4-6", 3, 15),
            ("gpt-5.6", 4, 20), ("gpt-5.4-mini", 0.75, 4.50), ("gpt-5.4-nano", 0.20, 1.25), ("gpt-5.4", 2.50, 15),
            ("gpt-5.1-codex-mini", 0.25, 2), ("o4-mini", 1.10, 4.40), ("o3-mini", 1.10, 4.40), ("o3", 2, 8), ("o1", 15, 60),
            ("gpt-4o-mini", 0.15, 0.60), ("gpt-4.1-mini", 0.40, 1.60), ("gpt-4.1-nano", 0.10, 0.40), ("gpt-4o", 2.50, 10),
            ("gpt-4.1", 2, 8), ("claude-sonnet-5", 2, 10), ("claude-sonnet-4-5", 3, 15),
        ]
        for (model, input, output) in cases {
            XCTAssertEqual(rates(model)?.input, input, model)
            XCTAssertEqual(rates(model)?.output, output, model)
        }
        XCTAssertEqual(rates("gpt-5.4")?.cacheWrite, 2.50)
        XCTAssertEqual(rates("claude-fable-5"), Rates(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5))
        XCTAssertEqual(rates("gpt-5.6-sol"), Rates(input: 4, output: 20, cacheRead: 0.40, cacheWrite: 5))
        XCTAssertEqual(rates("gpt-5.6-terra"), Rates(input: 2, output: 12, cacheRead: 0.20, cacheWrite: 2.50))
        XCTAssertEqual(rates("gpt-5.6-luna"), Rates(input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.25))
    }

    func testModelPricingGrokUsesRealXAIRates() {
        XCTAssertEqual(rates("grok-4.5"), Rates(input: 2, output: 6, cacheRead: 0.30, cacheWrite: 2))
        XCTAssertEqual(rates("grok-4.6")?.cacheRead, 0.50, "4.6 cache reads are not 4.5's $0.30")
        XCTAssertEqual(rates("grok-4.7"), Rates(input: 2, output: 6, cacheRead: 0.50, cacheWrite: 2))
        XCTAssertEqual(rates("grok-4.7-build-fast"), Rates(input: 4, output: 12, cacheRead: 1, cacheWrite: 4))
        XCTAssertEqual(rates("grok-build-0.1")?.input, 1)
        XCTAssertEqual(rates("grok-build-0.1")?.output, 2)
        XCTAssertEqual(rates("grok-4.20-0309-reasoning")?.input, 1.25)
        XCTAssertEqual(rates("grok-4.20-0309-reasoning")?.output, 2.50)
    }

    func testPricingAuditRejectsUnverifiedAliasesAndVariants() {
        for model in ["grok-something-new", "grok-composer-2.5-fast", "composer-2", "claude-opus-999", "my-fable-model",
                      "gpt-5.4-turbo", "gpt-5.4-pro", "gpt-5.6-cyber-unknown", "gpt-6-unknown", "codex", "o1-pro", "o3-pro",
                      "gpt-4o-audio-preview", "custom/gpt-4.1", "gpt-5.1-codex-unknown", "totally-unknown-model-xyz-999"] {
            XCTAssertNil(rates(model), "must not invent a rate: \(model)")
            XCTAssertEqual(builtIn.cost(model: model, TokenCostSpec(pureInput: 1000)), .failure(.modelPrice), model)
        }
    }

    func testPricingAuditVerifiedStandardRates() {
        let cases: [(String, Rates)] = [
            ("gpt-6-astra", Rates(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5)),
            ("gpt-6.1-sol", Rates(input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5)),
            ("openai/gpt-6.1-sol", Rates(input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5)),
            ("gpt-6-sol", Rates(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5)),
            ("gpt-6-luna", Rates(input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125)),
            ("openai/gpt-6-sol", Rates(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5)),
            ("openai/gpt-6-luna", Rates(input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125)),
            ("claude-sonnet-5-5", Rates(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5)),
            ("anthropic/claude-sonnet-5.5", Rates(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5)),
            ("claude-opus-5-5", Rates(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5)),
            ("anthropic/claude-opus-5-5-20260922", Rates(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5)),
            ("gpt-5.6-sol", Rates(input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5)),
            ("gpt-5.1-codex", Rates(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.25)),
            ("gpt-5.2-codex", Rates(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 1.75)),
            ("gpt-5.5", Rates(input: 5, output: 30, cacheRead: 0.5, cacheWrite: 5)),
            ("gpt-daybreak-blue-latest", Rates(input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5)),
            ("o1", Rates(input: 15, output: 60, cacheRead: 7.5, cacheWrite: 15)),
            ("o3", Rates(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 2)),
            ("o3-mini", Rates(input: 1.1, output: 4.4, cacheRead: 0.55, cacheWrite: 1.1)),
            ("o4-mini", Rates(input: 1.1, output: 4.4, cacheRead: 0.275, cacheWrite: 1.1)),
            ("gpt-4o", Rates(input: 2.5, output: 10, cacheRead: 1.25, cacheWrite: 2.5)),
            ("gpt-4o-mini", Rates(input: 0.15, output: 0.6, cacheRead: 0.075, cacheWrite: 0.15)),
            ("gpt-4.1", Rates(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 2)),
            ("gpt-4.1-mini", Rates(input: 0.4, output: 1.6, cacheRead: 0.1, cacheWrite: 0.4)),
            ("gpt-4.1-nano", Rates(input: 0.1, output: 0.4, cacheRead: 0.025, cacheWrite: 0.1)),
            ("claude-opus-4-1", Rates(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)),
            ("claude-3-5-haiku-20241022", Rates(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1)),
            ("anthropic/claude-fable-5.1", Rates(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)),
            (" OPENAI/GPT-4.1-2025-04-14 ", Rates(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 2)),
        ]
        for (model, expected) in cases { XCTAssertEqual(rates(model), expected, model) }
    }

    func testNormalizesModelSuffixDates() {
        XCTAssertEqual(PriceTable.normalizeModelName("claude-opus-4-1-20250301"), "claude-opus-4-1")
        XCTAssertEqual(PriceTable.normalizeModelName("o4-mini"), "o4-mini")
        XCTAssertEqual(PriceTable.normalizeModelName("model-2025010"), "model-2025010", "partial digit suffix kept")
        XCTAssertEqual(PriceTable.normalizeModelName("  claude-x  "), "claude-x")
        XCTAssertEqual(PriceTable.normalizeModelName(""), "")
        XCTAssertEqual(PriceTable.normalizeModelName("nodash"), "nodash")
    }

    // MARK: - Cost rules

    func testPricingAuditCacheClassesAndOpenAIBoundary() {
        let claude = cost("claude-fable-5.1", TokenCostSpec(pureInput: 10_000, pureOutput: 20_000, cacheRead: 30_000,
                                                            cacheWrite: 40_000, cacheWrite1h: 50_000))
        XCTAssertEqual(claude, 0.1 + 1.0 + 0.0075 + 0.5 + 1.0, accuracy: 1e-9)
        for (model, input, read, write) in [("gpt-6-astra", 10.0, 1.0, 12.5), ("gpt-6.1-sol", 2.0, 0.1, 2.5),
                                             ("gpt-6-sol", 2.0, 0.2, 2.5), ("gpt-6-luna", 0.1, 0.01, 0.125)] {
            for prompt in [271_999, 272_000, 272_001] {
                let multiplier = prompt > 272_000 ? 2.0 : 1.0
                let actual = cost(model, TokenCostSpec(pureInput: prompt - 2000, cacheRead: 1000, cacheWrite: 1000))
                let expected = (Double(prompt - 2000) * input + 1000 * read + 1000 * write) / 1e6 * multiplier
                XCTAssertEqual(actual, expected, accuracy: 1e-9, "\(model): \(prompt)")
            }
        }
    }

    func testPricingAuditNonClaudeDoesNotInventHourCachePremium() {
        XCTAssertEqual(cost("gpt-5.6-sol", TokenCostSpec(cacheWrite1h: 1000)), 0.005, accuracy: 1e-9)
    }

    func testNoWriteSurchargeStillBillsDisjointWriteTokensAsInput() {
        for model in ["gpt-5.5", "gpt-5.4", "gpt-5.3-codex", "gpt-4.1", "o1", "grok-4.6"] {
            let rate = rates(model)?.input ?? 0
            XCTAssertEqual(cost(model, TokenCostSpec(pureInput: 10, cacheWrite: 5)), 15 * rate / 1e6, accuracy: 1e-12, model)
            XCTAssertFalse(builtIn.requiresCacheWriteUsage(model: model), "equal class rates need no split: \(model)")
        }
    }

    func testCacheWriteUsageRequirementUsesOnlyKnownDistinctTariffs() {
        for model in ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
                      "openai/gpt-5.6", "claude-sonnet-5", "gpt-6.1-sol", "claude-sonnet-5-5"] {
            XCTAssertTrue(builtIn.requiresCacheWriteUsage(model: model), model)
        }
        for model in ["gpt-5.5", "gpt-5.4", "gpt-5.3-codex", "grok-4.6", "gpt-6-unknown", "codex-auto-review", ""] {
            XCTAssertFalse(builtIn.requiresCacheWriteUsage(model: model), model)
        }
        for rate in [nil, 0.0, 0.5, 1.0, 1.25] as [Double?] {
            let prices = catalog([("vendor/write-contract", CatalogPrice(input: 1, output: 2, cacheRead: nil, cacheWrite: rate))])
            XCTAssertEqual(prices.requiresCacheWriteUsage(model: "vendor/write-contract"), rate.map { $0 != 1.0 } ?? false)
        }
    }

    func testPricingCheckedDistinguishesMissingCacheRatesFromFree() {
        let prices = catalog([("vendor/coverage-test", CatalogPrice(input: 2, output: 5, cacheRead: nil, cacheWrite: 0))])
        let input = TokenCostSpec(pureInput: 1000)
        XCTAssertEqual(prices.cost(model: "coverage-test", input), .success(0.002))
        var read = input
        read.cacheRead = 100
        XCTAssertEqual(prices.cost(model: "coverage-test", read), .failure(.cacheReadPrice))
        var write = input
        write.cacheWrite = 100
        XCTAssertEqual(prices.cost(model: "coverage-test", write), .success(0.002))
        XCTAssertEqual(prices.cost(model: "not-a-real-model", input), .failure(.modelPrice))
        var hour = input
        hour.cacheWrite1h = 100
        XCTAssertEqual(prices.cost(model: "coverage-test", hour), .failure(.cacheWriteHourPrice))

        let unknownWrite = catalog([("vendor/write-unknown", CatalogPrice(input: 0, output: 0, cacheRead: 0, cacheWrite: nil))])
        XCTAssertEqual(unknownWrite.cost(model: "write-unknown", input), .success(0))
        XCTAssertEqual(unknownWrite.cost(model: "write-unknown", write), .failure(.cacheWritePrice))
    }

    func testAggregatedPricingRequiresRequestBoundariesAboveShortContext() {
        for (model, largestShort, input, read, output) in [("grok-4.6", 199_999, 2.0, 0.5, 6.0), ("gpt-6-astra", 272_000, 10.0, 1.0, 50.0)] {
            let group = TokenCostSpec(pureInput: largestShort - 1000, pureOutput: 100, cacheRead: 1000)
            let expected = (Double(largestShort - 1000) * input + 1000 * read + 100 * output) / 1e6
            XCTAssertEqual((try? builtIn.aggregatedCost(model: model, group).get()) ?? -1, expected, accuracy: 1e-9, model)
            var over = group
            over.cacheRead = 1001
            XCTAssertEqual(builtIn.aggregatedCost(model: model, over), .failure(.requestBoundaries))
        }
        XCTAssertEqual(builtIn.aggregatedCost(model: "grok-4.6", TokenCostSpec(pureInput: 1_600_000)), .failure(.requestBoundaries))
        // No context tariff: linear grouped pricing remains valid.
        let linear = (try? builtIn.aggregatedCost(model: "claude-sonnet-4-6", TokenCostSpec(pureInput: 1_600_000)).get()) ?? -1
        XCTAssertEqual(linear, 4.8, accuracy: 1e-9)
    }

    func testPricingAuditGrokThresholdIsInclusive() {
        for input in [199_999, 200_000, 200_001] {
            let rate = input >= 200_000 ? 4.0 : 2.0
            XCTAssertEqual(cost("x-ai/grok-4.6", TokenCostSpec(pureInput: input)), Double(input) / 1e6 * rate, accuracy: 1e-9)
        }
    }

    func testGrokLongContextDoublesInputAndOutput() {
        XCTAssertEqual(cost("grok-4.6", TokenCostSpec(pureInput: 250_000, pureOutput: 1_000_000)), 250_000 / 1e6 * 4 + 12, accuracy: 1e-9)
    }

    func testClaude1hCacheIsBilledAtTwiceInput() {
        XCTAssertEqual(cost("claude-sonnet-4-6", TokenCostSpec(cacheWrite1h: 1_000_000)), 6.0, accuracy: 1e-9)
    }

    func testSonnet45DoesNotApplyRetiredBetaPremium() {
        XCTAssertEqual(cost("claude-sonnet-4-5", TokenCostSpec(pureInput: 250_000)), 250_000 / 1e6 * 3, accuracy: 1e-9)
    }

    func testGPT56SolLongContextUses1_5xOutput() {
        XCTAssertEqual(cost("gpt-5.6-sol", TokenCostSpec(pureInput: 300_000, pureOutput: 1_000_000)), 300_000 / 1e6 * 8 + 30, accuracy: 1e-9)
    }

    func testGPT54MiniHasNoLongContextStep() {
        XCTAssertEqual(cost("gpt-5.4-mini", TokenCostSpec(pureInput: 300_000)), 300_000 / 1e6 * 0.75, accuracy: 1e-9)
    }

    func testCurrentModelsUseSharedPricesForTeamCosts() {
        func event(_ model: String) -> UsageEvent {
            var e = UsageEvent(at: Date(), provider: "Codex", model: model, projectKey: "", sessionID: "s")
            (e.tokensIn, e.tokensOut, e.cacheRead, e.cacheWrite) = (1000, 100, 100, 100)
            return e
        }
        XCTAssertEqual(builtIn.cost(for: event("gpt-6-sol")).usd, (2.0 + 1.0 + 0.02 + 0.25) / 1000, accuracy: 1e-12)
        XCTAssertEqual(builtIn.cost(for: event("gpt-6-luna")).usd, (0.1 + 0.05 + 0.001 + 0.0125) / 1000, accuracy: 1e-12)
        let opus = cost("claude-opus-5-5", TokenCostSpec(pureInput: 1000, pureOutput: 100, cacheRead: 100, cacheWrite: 100, cacheWrite1h: 100))
        XCTAssertEqual(opus, (4.0 + 2.0 + 0.02 + 0.5 + 0.8) / 1000, accuracy: 1e-12)
        let unknown = builtIn.cost(for: event("unknown-model"))
        XCTAssertEqual(unknown.usd, 0)
        XCTAssertTrue(unknown.incomplete)
    }

    // MARK: - OpenRouter catalog

    func testModelPricingUsesOpenRouterCatalogOnMiss() {
        let prices = catalog([("some-new-frontier-9", CatalogPrice(input: 7, output: 21, cacheRead: 0.7, cacheWrite: 8.75))])
        XCTAssertEqual(prices.catalogPrice(for: "some-new-frontier-9")?.input, 7)
        XCTAssertEqual(cost("some-new-frontier-9", TokenCostSpec(pureInput: 1_000_000, pureOutput: 1_000_000, cacheRead: 1_000_000), prices),
                       7 + 21 + 0.7, accuracy: 1e-9)
        // The built-in table wins over the catalog.
        let overridden = catalog([("claude-sonnet-4-6", CatalogPrice(input: 99, output: 99))])
        XCTAssertEqual(cost("claude-sonnet-4-6", TokenCostSpec(pureInput: 1_000_000), overridden), 3, accuracy: 1e-9)
    }

    func testAbsentCacheRatesAreUnknownInTheCatalog() throws {
        let prices = try fixture(#"[{"id":"vendor/example","pricing":{"prompt":"0.000003","completion":"0.000015"}}]"#)
        XCTAssertNil(prices.catalogPrice(for: "vendor/example")?.cacheRead)
        XCTAssertNil(prices.catalogPrice(for: "vendor/example")?.cacheWrite)
    }

    func testNumericOverflowIsNotAPrice() {
        XCTAssertNil(PriceCatalog.tokenPrice("1e308"))
    }

    func testExactNamespacesVariantsAndCollisions() throws {
        let cat = try fixture(#"""
        [{"id":"a/model","pricing":{"prompt":"0.000001","completion":"0.000002"}},
         {"id":"b/model","pricing":{"prompt":"0.000003","completion":"0.000004"}},
         {"id":"a/model-pro","pricing":{"prompt":"0.000005","completion":"0.000006"}},
         {"id":"a/model-fast","pricing":{"prompt":"0.000007","completion":"0.000008"}},
         {"id":"a/model.1","pricing":{"prompt":"0.000001","completion":"0.000002"}}]
        """#)
        XCTAssertEqual(cat.catalogPrice(for: "a/model")?.input ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(cat.catalogPrice(for: "b/model")?.input ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(cat.catalogPrice(for: "model-pro")?.input ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(cat.catalogPrice(for: " A/MODEL-FAST ")?.input ?? 0, 7, accuracy: 1e-9)
        for name in ["model", "c/model", "model-1", "model-pro-20260801", "model:free", "model:batch"] {
            XCTAssertNil(cat.catalogPrice(for: name), name)
        }
    }

    func testZeroInvalidMissingAndConditionalRatesStayDistinct() throws {
        let cat = try fixture(#"""
        [{"id":"a/zero","pricing":{"prompt":"0","completion":"0","input_cache_read":"0","input_cache_write":"0"}},
         {"id":"a/missing","pricing":{"prompt":"0.000001","completion":"0.000002","input_cache_read":null,"input_cache_write":"NaN"}},
         {"id":"a/tiered","pricing":{"prompt":"0.000001","completion":"0.000002","overrides":[{"min_prompt_tokens":200000,"prompt":"0.000004"}]}}]
        """#)
        XCTAssertEqual(cat.catalogPrice(for: "zero")?.cacheRead, 0)
        XCTAssertNotNil(cat.catalogPrice(for: "missing"))
        XCTAssertNil(cat.catalogPrice(for: "missing")?.cacheRead)
        XCTAssertNil(cat.catalogPrice(for: "missing")?.cacheWrite)
        XCTAssertNil(cat.catalogPrice(for: "tiered"))
    }

    func testStaleAndFutureCatalogsAreUnavailable() throws {
        let json = #"[{"id":"a/model","pricing":{"prompt":"0.000001","completion":"0.000002"}}]"#
        XCTAssertNotNil(try fixture(json).catalogPrice(for: "model"))
        XCTAssertNil(try fixture(json, fetchedAt: Date().addingTimeInterval(-PriceCatalog.catalogLifetime)).catalogPrice(for: "model"))
        XCTAssertNil(try fixture(json, fetchedAt: Date().addingTimeInterval(60)).catalogPrice(for: "model"))
    }

    func testUnpriceableRowsStillMakeBareNamesAmbiguous() throws {
        let cat = try fixture(#"[{"id":"a/model","pricing":{"prompt":"0.000001","completion":"0.000002"}},{"id":"b/model","pricing":null}]"#)
        XCTAssertNil(cat.catalogPrice(for: "model"))
        XCTAssertNotNil(cat.catalogPrice(for: "a/model"))
    }

    func testDuplicateFullIDsAreNotOrderDependent() throws {
        let cat = try fixture(#"[{"id":"a/model","pricing":{"prompt":"0.000001","completion":"0.000002"}},{"id":"a/model","pricing":{"prompt":"0.000003","completion":"0.000004"}}]"#)
        XCTAssertNil(cat.catalogPrice(for: "a/model"))
        XCTAssertNil(cat.catalogPrice(for: "model"))
    }

    func testParseTokenPriceToMtok() {
        XCTAssertEqual(PriceCatalog.tokenPrice("0.000003") ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(PriceCatalog.tokenPrice("0.000015") ?? 0, 15, accuracy: 1e-9)
    }

    func testParseOpenRouterKeepsBatchAndFreeAsDistinctIDs() throws {
        let rows = try XCTUnwrap(JSONValue.parse(#"""
        [{"id":"anthropic/claude-sonnet-4.5","pricing":{"prompt":"0.000003","completion":"0.000015","input_cache_read":"0.0000003","input_cache_write":"0.00000375"}},
         {"id":"anthropic/claude-sonnet-4.5:batch","pricing":{"prompt":"0.0000015","completion":"0.0000075"}},
         {"id":"meta-llama/llama-3.3-70b-instruct:free","pricing":{"prompt":"0","completion":"0"}}]
        """#)?.array)
        let entries = try PriceCatalog.entries(fromOpenRouter: rows)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(PriceCatalog.slug(of: entries[0].id), "claude-sonnet-4.5")
        let cat = PriceCatalog(entries: entries, fetchedAt: Date())
        XCTAssertEqual(cat.catalogPrice(for: "anthropic/claude-sonnet-4.5:batch")?.input ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(cat.catalogPrice(for: "meta-llama/llama-3.3-70b-instruct:free")?.input, 0)
        XCTAssertNil(cat.catalogPrice(for: "llama-3.3-70b-instruct"))
        XCTAssertEqual(entries[0].price.input, 3, accuracy: 1e-9)
        XCTAssertEqual(entries[0].price.cacheRead ?? 0, 0.3, accuracy: 1e-9)
    }

    func testLookupExactWithoutGuessedSnapshot() {
        let cat = catalog([("claude-fable-5", CatalogPrice(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5))])
        XCTAssertEqual(cat.catalogPrice(for: "claude-fable-5")?.input, 10)
        XCTAssertNil(cat.catalogPrice(for: "claude-fable-5-20260601"))
    }

    func testLookupEmptyIsNone() {
        let cat = catalog([])
        XCTAssertNil(cat.catalogPrice(for: ""))
        XCTAssertNil(cat.catalogPrice(for: "totally-unknown-xyz-999"))
    }

    func testInitFromOpenRouterBody() throws {
        let body = Data(#"{"data":[{"id":"vendor/new-model","pricing":{"prompt":"0.000002","completion":"0.000008"}}]}"#.utf8)
        let prices = try PriceCatalog(openRouterJSON: body)
        XCTAssertEqual(prices.catalogPrice(for: "new-model")?.output ?? 0, 8, accuracy: 1e-9)
        XCTAssertThrowsError(try PriceCatalog(openRouterJSON: Data(#"{"data":[]}"#.utf8)))
        XCTAssertThrowsError(try PriceCatalog(openRouterJSON: Data("nope".utf8)))
        XCTAssertThrowsError(try PriceCatalog(openRouterJSON: Data(#"{"data":[{"pricing":{}}]}"#.utf8)), "a row without an id")
    }

    func testCatalogPricesFlowIntoTranscriptCosts() {
        let prices = catalog([("vendor/new-model", CatalogPrice(input: 2, output: 8, cacheRead: 0.2, cacheWrite: 2))])
        let line = #"{"timestamp":"2026-07-29T14:05:00Z","payload":{"model":"vendor/new-model","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":500,"cache_write_input_tokens":0,"output_tokens":100}}}}"#
        let e = CodexTranscript.parse(lines: line, sessionID: "s", prices: prices)[0]
        XCTAssertFalse(e.costIncomplete)
        XCTAssertEqual(e.costUSD, (500 * 2 + 500 * 0.2 + 100 * 8) / 1e6, accuracy: 1e-12)
        XCTAssertTrue(CodexTranscript.parse(lines: line, sessionID: "s")[0].costIncomplete)
    }
}
