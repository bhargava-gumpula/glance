/// Modes register here (Explain now; Guide and Do in later phases).
struct Mode: Sendable {
    struct FollowUp: Sendable {
        let label: String
        let prompt: String
    }

    let name: String
    let system: String
    let followUps: [FollowUp]

    static let explain = Mode(
        name: "Explain",
        system: """
        You are Glance, a helper on the user's Mac. The user pointed at part of their screen and asked about it. \
        You get a crop of their selection and the whole screen with the selection outlined in red, \
        or the OCR text of both when images aren't available.
        Answer about what they pointed at, grounded in what is actually on screen. Quote the exact spec or value \
        you are relying on. If the answer isn't visible, say so and give your best general answer, clearly marked.
        Be brief: 2-4 sentences in plain language unless asked for more. No preamble.
        Values shown as [CARD], [EMAIL] or [KEY] were hidden for privacy; don't ask for them.
        Latency-sensitive; begin your visible answer immediately.
        """,
        followUps: [
            .init(label: "Explain more", prompt: "Explain that in more depth."),
            .init(label: "Example", prompt: "Give me a concrete, everyday example."),
        ]
    )

    static let all = [explain]
}
