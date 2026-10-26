import XCTest
@testable import PokeTokenBar

private struct ChosenEggProvider: PokeProviding, SpeciesCatalogProviding {
    func speciesCatalog() async throws -> [CatalogSpecies] {
        if offline { throw URLError(.notConnectedToInternet) }
        return [
            CatalogSpecies(id: 4, parentID: nil, names: ["en": "Charmander"]),
            CatalogSpecies(id: 5, parentID: 4, names: ["en": "Charmeleon"]),
            CatalogSpecies(id: 6, parentID: 5, names: ["en": "Charizard"]),
            CatalogSpecies(id: 25, parentID: 172, names: ["en": "Pikachu", "ko": "피카츄"]),
            CatalogSpecies(id: 26, parentID: 25, names: ["en": "Raichu"]),
            CatalogSpecies(id: 172, parentID: nil, names: ["en": "Pichu"]),
            CatalogSpecies(id: 700, parentID: nil, names: ["en": "Sylveon"]),
        ]
    }

    var offline = false
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        if offline { throw URLError(.notConnectedToInternet) }
        let ids = baseSpeciesID == 172 ? [172, 25, 26] : [baseSpeciesID, baseSpeciesID + 1, baseSpeciesID + 2]
        let tree = EvoNode(speciesID: ids[0], children: [
            EvoNode(speciesID: ids[1], children: [EvoNode(speciesID: ids[2], children: [])]),
        ])
        return EvoLine(baseID: ids[0], tree: tree, rarity: .common, names: [:])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor
final class ChosenEggTests: XCTestCase {
    private func store(active: Bool = true, offline: Bool = false, eggUsage: Int = 0,
                       used: Int = 5_000_000_000) -> CompanionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chosen-egg-\(UUID().uuidString).json")
        let mon = "{\"baseID\":10,\"pathIDs\":[10],\"stageIndex\":0,\"usedAtStage\":200000000,"
            + "\"rarity\":\"common\",\"totalForms\":3}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":\(used),\"spentTokens\":0,\"eggUsage\":\(eggUsage),"
            + "\"lastDate\":\"d\",\"active\":\(active ? mon : "null"),\"dex\":[],\"collectedFinals\":[]}"
        try? json.data(using: .utf8)!.write(to: url)
        return CompanionStore(provider: ChosenEggProvider(offline: offline),
                              clock: { Date(timeIntervalSince1970: 1_700_000_000) },
                              fileURL: url, rng: SeededRNG(seed: 7))
    }

    // MARK: Choice Egg

    func testCatalogSkipsSpeciesWithoutSprites() async {
        let s = store()
        await s.loadSpeciesCatalog()
        XCTAssertFalse(s.speciesCatalog.contains { $0.id == 700 }, "Gen 6+ has no animated sprite")
        XCTAssertEqual(s.searchCatalog("pika").map(\.id), [25])
        XCTAssertEqual(s.searchCatalog("피카").map(\.id), [25], "any language matches")
        XCTAssertEqual(s.searchCatalog("#25").first?.id, 25, "exact number ranks first")
        XCTAssertEqual(s.searchCatalog("  ").count, 0)
    }

    func testCostsTheSameAsThePlainEgg() {
        let s = store()
        XCTAssertEqual(s.price(of: .chosenEgg), s.price(of: .egg(nil)))
    }

    func testBuyingReleasesActiveAndRemembersSpecies() async {
        let s = store()
        await s.loadSpeciesCatalog()
        XCTAssertTrue(s.buyChosenEgg(speciesID: 25))
        XCTAssertNil(s.state.active)
        XCTAssertEqual(s.state.pendingHatchID, 172, "egg belongs to Pikachu's line")
        XCTAssertEqual(s.chosenEggSpeciesID, 25)
        XCTAssertEqual(s.state.eggUsage, 0, "a new egg needs the usual incubation")
        XCTAssertEqual(s.state.spentTokens, s.price(of: .egg(nil)))
        XCTAssertTrue(s.state.dex.contains { $0.baseID == 10 && $0.isReleased }, "released partner stays in the dex")
    }

    /// The chosen species survives incubation and hatches at its own stage.
    func testChosenEggHatchesIntoPickedSpecies() async {
        let s = store()
        await s.loadSpeciesCatalog()
        XCTAssertTrue(s.buyChosenEgg(speciesID: 6))
        s.update(todayTokensByProvider: ["test": 0], todayDate: "d", monthTotal: 0,
                 burnTier: .idle, limitWarning: false, hasUsageData: true)
        s.update(todayTokensByProvider: ["test": s.eggHatchThreshold + 1], todayDate: "d", monthTotal: 0,
                 burnTier: .idle, limitWarning: false, hasUsageData: true)
        await s.hatchIfNeeded()
        XCTAssertEqual(s.state.active?.currentID, 6)
        XCTAssertEqual(s.state.active?.pathIDs, [4, 5, 6])
        XCTAssertEqual(s.state.active?.stageIndex, 2)
        XCTAssertNil(s.state.pendingStartID)
        XCTAssertNil(s.chosenEggSpeciesID)
    }

    func testChoiceSurvivesSaveAndReload() async throws {
        let s = store()
        await s.loadSpeciesCatalog()
        XCTAssertTrue(s.buyChosenEgg(speciesID: 25))
        let data = try JSONEncoder().encode(s.state)
        let decoded = try JSONDecoder().decode(CompanionState.self, from: data)
        XCTAssertEqual(decoded.pendingHatchID, 172)
        XCTAssertEqual(decoded.pendingStartID, 25)
    }

    /// Same gate as the plain egg: no partner to release, or not enough tokens, means no sale.
    func testBlockedWithoutActiveOrTokens() async {
        let egg = store(active: false)
        await egg.loadSpeciesCatalog()
        XCTAssertFalse(egg.buyChosenEgg(speciesID: 25))
        XCTAssertEqual(egg.state.spentTokens, 0)

        let broke = store(used: 1)
        await broke.loadSpeciesCatalog()
        XCTAssertFalse(broke.buyChosenEgg(speciesID: 25))
        XCTAssertEqual(broke.state.active?.baseID, 10)
    }

    /// Without the catalog the line is unknown — the purchase must not take tokens.
    func testBuyingWithoutCatalogDoesNothing() {
        let s = store()
        XCTAssertFalse(s.buyChosenEgg(speciesID: 25))
        XCTAssertEqual(s.state.active?.baseID, 10)
        XCTAssertEqual(s.state.spentTokens, 0)
    }
}
