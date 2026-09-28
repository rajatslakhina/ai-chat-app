/// Two tool-path packages this app links but cannot give an honest job yet, and why.
///
/// Both stages are recorded on every path a tool round trip can take, so Diagnostics shows them
/// as explained skips rather than as unreached packages. The reasons are structural facts about
/// this app, not about a particular turn, which is why they are constants.
enum StructuralToolSkips {
    /// `ToolCallSchedulerKit` decides which of one turn's parallel tool calls may run at once.
    /// This app never sees more than one: ProviderGatewayKit's `Outcome.toolCall` carries a
    /// single request, and `OpenRouterProvider` maps only the first of the `tool_calls` the model
    /// returned. A one-call batch has nothing to schedule, so running the scheduler over it would
    /// be a call for the sake of the Diagnostics row. The real fix sits upstream (a plural tool
    /// outcome in the gateway), and until it lands any extra parallel call is dropped before this
    /// stage could see it.
    static let schedulingReason =
        "the gateway surfaces at most one tool call per hop; a one-call batch has nothing to schedule"

    /// `ScopeDriftKit` measures how far a session's granted scopes have moved from the agent's
    /// manifest. This app's manifest is fixed at two read-only tools (calculator, current time)
    /// and there is no path by which anything gets elevated, so there is nothing that could drift.
    static let scopeDriftReason =
        "fixed two-tool manifest with no elevation path; this session's scope cannot drift"

    static var records: [StageRecord] {
        [
            StageRecord(stage: .scopeDrift, outcome: .skipped(reason: scopeDriftReason), durationMs: 0),
            StageRecord(
                stage: .toolCallScheduling, outcome: .skipped(reason: schedulingReason), durationMs: 0
            )
        ]
    }
}
