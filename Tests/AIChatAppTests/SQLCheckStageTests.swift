import Foundation
import GuardrailKit
import ProviderGatewayKit
import Testing
@testable import AIChatApp

private let question = "Which customers have no email on file?"

private func user(_ text: String) -> LLMMessage {
    LLMMessage(role: .user, content: text)
}

private func review(
    _ answer: String,
    messages: [LLMMessage] = [user(question)]
) async -> (AnswerReview, PipelineTrace) {
    let pipeline = PostModelPipeline(guardrail: GuardrailPipeline(policy: GuardrailPolicy()))
    var trace = PipelineTrace()
    let reviewed = await pipeline.review(answer: answer, sources: [], messages: messages, trace: &trace)
    return (reviewed, trace)
}

private let schema = "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, email TEXT);\n"
    + "INSERT INTO customers VALUES (1, 'Asha', 'on file'), (2, 'Ben', NULL), (3, 'Chen', NULL);\n"
private let nullFilter = "```sql\n" + schema + "SELECT name FROM customers WHERE email = NULL;\n```\n"
    + "This returns:\n\n| name |\n|---|\n| Ben |\n| Chen |"
private let noRows = "`SELECT name FROM customers WHERE email = NULL;` returns no rows, not 2 rows: Ben, Chen "
    + "(= NULL is never true; use IS NULL or IS NOT NULL)."

@Suite("SQLClaimKit - what an answer says its SQL returns, run on the data it shows")
struct SQLCheckStageTests {
    @Test("a result that does not hold gets a note with what SQLite returns and the slip, after tomlCheck")
    func wrongResultGetsANote() async throws {
        let (reviewed, trace) = await review(nullFilter)
        #expect(reviewed.publishableText == nullFilter)
        #expect(reviewed.sqlNote == "SQL check: " + noRows)
        #expect(trace.outcome(for: .sqlCheck) == .ran(detail: "1 claim checked, 0 hold, 1 wrong; " + noRows))
        let stages = trace.records.map(\.stage)
        let sql = try #require(stages.firstIndex(of: .sqlCheck))
        let toml = try #require(stages.firstIndex(of: .tomlCheck))
        #expect(sql > toml)
        var bubble = ChatBubble(role: .assistant, text: reviewed.publishableText)
        bubble.applyReview(reviewed)
        #expect(bubble.sqlNote == reviewed.sqlNote)
        #expect(bubble.reviewNotes.map(\.id).last == "sqlNote")
    }

    @Test("a result engines disagree on, with no engine named, is a second look rather than a mistake")
    func engineDependentIsACaveat() async {
        let (reviewed, trace) = await review("```sql\nSELECT 7 / 2; -- 3.5\n```")
        let caveat = "`SELECT 7 / 2;` gives 3 in SQLite, not 3.5; engines differ here (SQLite, PostgreSQL and SQL "
            + "Server divide two integers as integers, while MySQL's / returns a decimal), so name the engine the "
            + "answer is for."
        #expect(reviewed.sqlNote == "SQL check: " + caveat)
        #expect(trace.outcome(for: .sqlCheck) == .ran(detail: "1 claim checked, 0 hold, 1 to check; " + caveat))
    }

    @Test("a wrong result the chat already gave is marked as said again")
    func repeatedClaimSaysSo() async {
        let messages = [
            user(question),
            LLMMessage(role: .assistant, content: nullFilter),
            user("Are you sure?")
        ]
        let (reviewed, trace) = await review(nullFilter, messages: messages)
        #expect(reviewed.sqlNote == "SQL check: " + noRows + " An earlier answer in this chat stated the same claim.")
        #expect(trace.outcome(for: .sqlCheck)
            == .ran(detail: "1 claim checked, 0 hold, 1 wrong, 1 repeated; " + noRows))
    }

    @Test("SQL that holds, no SQL, SQL on tables the answer never shows, or another engine get no note")
    func quietWhenItHoldsOrCannotTell() async {
        let (held, heldTrace) = await review("```sql\nSELECT 7 / 2.0; -- 3.5\n```")
        #expect(held.sqlNote == nil)
        #expect(heldTrace.outcome(for: .sqlCheck) == .noOp(reason: "1 claim checked, 1 hold"))
        let (none, noneTrace) = await review("Weigh the flour rather than using cups.")
        #expect(none.sqlNote == nil)
        #expect(noneTrace.outcome(for: .sqlCheck) == .noOp(reason: "no claims about SQL"))
        let (unseen, unseenTrace) = await review("```sql\nSELECT * FROM users WHERE id = 1;\n```")
        #expect(unseen.sqlNote == nil)
        #expect(unseenTrace.outcome(for: .sqlCheck) == .noOp(reason: "no claims about SQL"))
        let (postgres, postgresTrace) = await review("```postgresql\nSELECT 7 / 2; -- 3\n```")
        #expect(postgres.sqlNote == nil)
        #expect(postgresTrace.outcome(for: .sqlCheck) == .noOp(reason: "1 claim checked, 0 hold, 1 unchecked"))
    }

    @Test("a withheld answer is not checked")
    func withheldIsSkipped() async {
        let refusal = Refusal(stage: .guardrailOutput, headline: "Withheld", explanation: "x", recovery: nil)
        let withheld = AnswerReview(
            publishableText: "", wasModified: true, groundedFraction: nil, claimCount: 0, refusal: refusal
        )
        var trace = PipelineTrace()
        let result = await PostModelPipeline.checkSQL(withheld, messages: [user(question)], trace: &trace)
        #expect(result == withheld)
        #expect(trace.outcome(for: .sqlCheck)
            == .skipped(reason: "the answer was withheld, so there is nothing to check"))
    }

    @Test("the SQL note comes last among the notes, after the TOML note")
    func reviewNotesKeepTheirOrder() {
        var bubble = ChatBubble(role: .assistant, text: "x")
        bubble.sqlNote = "s"
        bubble.tomlNote = "t"
        #expect(bubble.reviewNotes == [ReviewNote(id: "tomlNote", text: "t"), ReviewNote(id: "sqlNote", text: "s")])
    }
}
