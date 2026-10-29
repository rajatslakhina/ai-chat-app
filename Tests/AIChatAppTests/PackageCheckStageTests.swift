import Foundation
import GuardrailKit
import PackageClaimKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

/// Thursday, October 29, 2026, 00:00 UTC.
private let october29 = Date(timeIntervalSince1970: 1_793_232_000)

private func day(_ text: String) -> Date {
    (try? Date(text + "T00:00:00Z", strategy: .iso8601)) ?? .distantPast
}

private let snapshot = [
    PackageFacts(ecosystem: .pypi, name: "requests", firstPublished: day("2011-02-14"), latestVersion: "2.34.2",
                 versions: ["2.34.2"]),
    PackageFacts(ecosystem: .pypi, name: "fastapi-jwt-shield", firstPublished: day("2026-10-23"),
                 latestVersion: "0.0.1", versions: ["0.0.1"]),
    PackageFacts(ecosystem: .crates, name: "serde", firstPublished: day("2014-12-05"), latestVersion: "1.0.229",
                 versions: ["1.0.229"])
]

private func review(
    _ answer: String,
    registry: StaticRegistry? = StaticRegistry(snapshot)
) async -> (AnswerReview, PipelineTrace) {
    let pipeline = PostModelPipeline(
        guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
        packages: registry.map { PackageVetter(registry: $0) }
    )
    var trace = PipelineTrace()
    let reviewed = await pipeline.review(
        answer: answer, sources: [], messages: [LLMMessage(role: .user, content: "What do I install?")],
        now: october29, trace: &trace
    )
    return (reviewed, trace)
}

@Suite("PackageClaimKit - the packages an answer tells someone to install")
struct PackageCheckStageTests {
    @Test("a name that does not exist gets a note, after languageMatch, and the text is unchanged")
    func missingNameGetsANote() async throws {
        let answer = "Install it:\n```bash\npip install reqeusts\n```"
        let (reviewed, trace) = await review(answer)
        #expect(reviewed.publishableText == answer)
        #expect(reviewed.packageNote == "Package check: `reqeusts` (`pip install`): no package by that name on "
            + "PyPI; did you mean `requests`? A name that does not exist fails to install today, and anyone can "
            + "register it tomorrow (slopsquatting): check names before running the commands.")
        #expect(trace.outcome(for: .packageCheck) == .ran(detail: "1 package: 1 wrong (reqeusts)"))
        let stages = trace.records.map(\.stage)
        let packages = try #require(stages.firstIndex(of: .packageCheck))
        let language = try #require(stages.firstIndex(of: .languageMatch))
        #expect(packages > language)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.packageNote == reviewed.packageNote)
    }

    @Test("a package first published days ago is a caution note")
    func newPackageGetsACautionNote() async {
        let (reviewed, trace) = await review("`pip install requests fastapi-jwt-shield`")
        #expect(reviewed.packageNote == "Package check: `fastapi-jwt-shield` (`pip install`): was first published "
            + "6 days ago. Look at who published a new or look-alike package before installing it.")
        #expect(trace.outcome(for: .packageCheck)
            == .ran(detail: "2 packages: 1 caution (fastapi-jwt-shield), 1 verified"))
    }

    @Test("packages that check out get no note")
    func verifiedIsQuiet() async {
        let (reviewed, trace) = await review("```toml\n[dependencies]\nserde = \"1\"\n```")
        #expect(reviewed.packageNote == nil)
        #expect(trace.outcome(for: .packageCheck) == .noOp(reason: "1 package: 1 verified"))
    }

    @Test("an answer with no install command records why nothing ran")
    func noPackagesIsANoOp() async {
        let (reviewed, trace) = await review("Use a session object and reuse connections.")
        #expect(reviewed.packageNote == nil)
        #expect(trace.outcome(for: .packageCheck)
            == .noOp(reason: "packages: no install commands or manifests in the answer"))
    }

    @Test("a registry that cannot be reached is a failed stage, not a clean answer")
    func unreachableRegistryFails() async {
        let (reviewed, trace) = await review("`cargo add serde`",
                                             registry: StaticRegistry(snapshot, offline: [.crates: "timed out"]))
        #expect(reviewed.packageNote == nil)
        #expect(trace.outcome(for: .packageCheck) == .failed(message: "1 package: 1 not checked (serde)"))
    }

    @Test("without a registry the stage says so")
    func noRegistryIsSkipped() async {
        let (reviewed, trace) = await review("`pip install reqeusts`", registry: nil)
        #expect(reviewed.packageNote == nil)
        #expect(trace.outcome(for: .packageCheck) == .skipped(reason: "no package registry is configured"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        let pipeline = PostModelPipeline(
            guardrail: GuardrailPipeline(policy: GuardrailPolicy()),
            packages: PackageVetter(registry: StaticRegistry(snapshot))
        )
        var trace = PipelineTrace()
        let result = await pipeline.checkPackages(withheld, now: october29, trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .packageCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }
}
