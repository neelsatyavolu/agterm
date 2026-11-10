import XCTest
@testable import AgTermCore

/// The price list agterm and agmux fetch (`prices.json` in this repo), so a new model's
/// price doesn't need an app update.
final class RemotePricesTests: XCTestCase {
    private let spec = TokenCostSpec(pureInput: 1_000_000, pureOutput: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)

    private func list(_ rows: String) -> Data {
        Data(#"{"version":1,"updated":"2026-11-09","models":[\#(rows)]}"#.utf8)
    }

    func testFable52IsBuiltIn() {
        XCTAssertEqual(PriceTable.rates(model: "claude-fable-5-2"), Rates(input: 8, output: 40, cacheRead: 0.20, cacheWrite: 10))
        XCTAssertEqual(PriceTable.rates(model: "claude-mythos-5-2"), PriceTable.rates(model: "claude-fable-5-2"))
        XCTAssertEqual(try PriceCatalog.builtIn.cost(model: "claude-fable-5.2", spec).get(), 8 + 40 + 0.20 + 10, accuracy: 1e-9)
    }

    func testListedPricesWinOverTheTableAndPriceNewModels() throws {
        let data = list(#"{"ids":["claude-opus-5-5"],"input":1,"output":2,"cacheRead":0.5,"cacheWrite":1.25},"#
            + #"{"ids":["claude-newmodel-6","anthropic/claude-newmodel-6-fast"],"input":3,"output":6,"cacheRead":0.3,"cacheWrite":3.75}"#)
        let prices = try PriceCatalog.builtIn.adding(priceList: data)
        XCTAssertEqual(try prices.cost(model: "claude-opus-5-5", spec).get(), 1 + 2 + 0.5 + 1.25, accuracy: 1e-9)
        XCTAssertEqual(try prices.cost(model: "claude-newmodel-6-20261201", spec).get(), 3 + 6 + 0.3 + 3.75, accuracy: 1e-9)
        XCTAssertEqual(try prices.cost(model: "anthropic/claude-newmodel-6-fast", spec).get(), 3 + 6 + 0.3 + 3.75, accuracy: 1e-9)
        // Claude 1-hour writes stay at twice input.
        XCTAssertEqual(try prices.cost(model: "claude-newmodel-6", TokenCostSpec(cacheWrite1h: 1_000_000)).get(), 6, accuracy: 1e-9)
        // Models the list leaves out keep their built-in price.
        XCTAssertEqual(try prices.cost(model: "claude-sonnet-5-5", spec).get(), 2 + 10 + 0.10 + 2.50, accuracy: 1e-9)
    }

    func testBadListsAreRejected() {
        for body in ["[]", #"{"version":1}"#, #"{"version":2,"models":[]}"#,
                     #"{"version":1,"models":[{"ids":["x"],"input":-1,"output":1,"cacheRead":0,"cacheWrite":0}]}"#,
                     #"{"version":1,"models":[{"ids":[],"input":1,"output":1,"cacheRead":0,"cacheWrite":0}]}"#,
                     #"{"version":1,"models":[{"ids":["x"],"input":"1","output":1,"cacheRead":0,"cacheWrite":0}]}"#] {
            XCTAssertThrowsError(try PriceCatalog.builtIn.adding(priceList: Data(body.utf8)), body)
        }
    }

    /// The file in the repo is the one apps download: it must parse.
    func testRepoPriceListParses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("prices.json")
        let listed = try RemotePrices.parse(Data(contentsOf: url))
        XCTAssertEqual(listed["claude-fable-5-2"], Rates(input: 8, output: 40, cacheRead: 0.20, cacheWrite: 10))
    }
}
