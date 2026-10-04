import Foundation

/// OpenRouter chat client for the AI summary and quiz generation.
///
/// Direct port of src/Llm.php — same endpoint, same prompts, same validation,
/// so the Mac app produces the same summaries and quizzes as the web app.
public struct OpenRouterClient: Sendable {
    public static let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private let apiKey: String
    private let model: String

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespaces)
        self.model = model.trimmingCharacters(in: .whitespaces)
    }

    /// Language rules copied verbatim from the PHP prompts.
    static func languageRule(_ lang: OutputLanguage) -> String {
        switch lang {
        case .zhHK:
            return "Traditional Chinese as used in Hong Kong (香港繁體). Use Traditional "
                + "characters and HK written conventions; keep English technical terms in "
                + "English where that is natural for a HK classroom."
        case .zhCN:
            return "Simplified Chinese (简体中文)."
        case .en:
            return "English."
        }
    }

    /// The AI Summary button: a lesson summary or meeting minutes, per the
    /// Settings default, at the chosen detail level.
    public func summarize(transcript: String, lang: OutputLanguage,
                          length: SummaryLength = .standard,
                          style: SummaryStyle = .lesson) async throws -> String {
        let langRule = Self.languageRule(lang)
        switch style {
        case .lesson:
            return try await summarizeLesson(transcript, langRule: langRule, length: length)
        case .minutes:
            return try await summarizeMinutes(transcript, langRule: langRule, length: length)
        }
    }

    private func summarizeLesson(_ transcript: String, langRule: String,
                                 length: SummaryLength) async throws -> String {
        let intro = "You are an experienced teaching assistant who summarises session transcripts "
            + "for teachers. Write everything in \(langRule)\n"
        let body: String
        switch length {
        case .brief:
            body = "Produce a concise Markdown summary with these sections:\n"
                + "## Overview — 1-2 sentences on what the session covered\n"
                + "## Key Points — at most 5 short bullets\n"
                + "## Key Terms — at most 3 essential terms, one line each (omit the section if none)\n"
                + "## Follow-ups — a single line listing homework/reminders, if any\n"
                + "Omit ## Examples. Keep the whole summary under 150 words. "
                + "Use only facts from the transcript; never invent content."
        case .standard:
            body = "Produce a Markdown summary with exactly these sections:\n"
                + "## Overview — 2-3 sentences on what the session covered\n"
                + "## Key Points — the main teaching points, as bullets\n"
                + "## Key Terms — important terms/vocabulary with a one-line definition each\n"
                + "## Examples — examples or worked problems that came up, briefly\n"
                + "## Follow-ups — homework, reminders or next steps, if any were mentioned "
                + "(omit the section if there were none)\n"
                + "Use only facts from the transcript; never invent content."
        case .inDepth:
            body = "Produce a thorough, detailed Markdown summary with these sections:\n"
                + "## Overview — 3-5 sentences on what the session covered\n"
                + "## Key Points — 6-10 bullets, each with a short explanation\n"
                + "## Key Terms — every important term/vocabulary item with a clear one-to-two-line definition\n"
                + "## Examples — describe each example or worked problem and what it demonstrates\n"
                + "## Follow-ups — all homework, reminders or next steps, including any deadlines mentioned\n"
                + "Where the transcript shows a calculation or process, lay out its steps. "
                + "Use only facts from the transcript; never invent content."
        }
        return try await chat(
            messages: [.init(role: "system", content: intro + body),
                       .init(role: "user", content: "Session transcript:\n\n\(transcript)")],
            maxTokens: 4000
        )
    }

    /// Meeting minutes: decisions and action items instead of teaching points.
    private func summarizeMinutes(_ transcript: String, langRule: String,
                                  length: SummaryLength) async throws -> String {
        let intro = "You are a professional secretary who writes minutes from session transcripts. "
            + "Write everything in \(langRule)\n"
        let body: String
        switch length {
        case .brief:
            body = "Produce a concise Markdown meeting minute with these sections:\n"
                + "## Overview — 1-2 sentences on what the meeting was about and its outcome\n"
                + "## Decisions — the key decisions made, as bullets (omit the section if none)\n"
                + "## Action Items — task — owner — deadline, one line each (omit the section if none)\n"
                + "Keep the whole minute under 150 words. "
                + "Use only facts from the transcript; never invent content."
        case .standard:
            body = "Produce a Markdown meeting minute with exactly these sections:\n"
                + "## Overview — 2-3 sentences on the meeting's purpose and outcome\n"
                + "## Topics Discussed — the main points raised, as bullets\n"
                + "## Decisions — what was agreed, as bullets (omit the section if none)\n"
                + "## Action Items — task, owner and deadline where mentioned "
                + "(omit the section if none)\n"
                + "Name participants only if the transcript identifies them. "
                + "Use only facts from the transcript; never invent content."
        case .inDepth:
            body = "Produce a thorough, detailed Markdown meeting minute with these sections:\n"
                + "## Overview — 3-5 sentences on the meeting's purpose, scope and outcome\n"
                + "## Topics Discussed — each topic with a short account of what was said\n"
                + "## Decisions — each decision with its rationale, as bullets\n"
                + "## Action Items — every task mentioned, with owner and deadline where stated\n"
                + "## Open Questions — items left unresolved or deferred (omit the section if none)\n"
                + "Where the transcript shows numbers, budgets or schedules, record them exactly. "
                + "Name participants only if the transcript identifies them. "
                + "Use only facts from the transcript; never invent content."
        }
        return try await chat(
            messages: [.init(role: "system", content: intro + body),
                       .init(role: "user", content: "Session transcript:\n\n\(transcript)")],
            maxTokens: 4000
        )
    }

    public func makeQuiz(transcript: String, lang: OutputLanguage, count: Int) async throws -> [QuizQuestion] {
        let count = max(1, min(count, 20))
        let langRule = Self.languageRule(lang)
        let system = "You are a teacher who writes multiple-choice quizzes from session transcripts. "
            + "Write all questions, options and explanations in \(langRule)\n"
            + "Create exactly \(count) multiple-choice questions that test understanding of "
            + "the session content. Questions must be answerable from the transcript alone, "
            + "with mixed difficulty and plausible distractors.\n"
            + "Output STRICT JSON only — no markdown fences, no commentary. Format: an array "
            + "of objects {\"question\": string, \"options\": [exactly 4 strings], "
            + "\"answer\": integer 0-3 (index of the correct option), \"explanation\": 1-2 "
            + "sentence explanation of why the answer is correct}"
        let raw = try await chat(
            messages: [.init(role: "system", content: system),
                       .init(role: "user", content: "Session transcript:\n\n\(transcript)")],
            maxTokens: 8000
        )
        return try Self.parseQuiz(raw)
    }

    // MARK: - Chat transport

    struct Message: Codable, Sendable {
        var role: String
        var content: String
    }

    private struct RequestBody: Codable {
        var model: String
        var messages: [Message]
        var max_tokens: Int
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message?
        }
        var choices: [Choice]?
    }

    private func chat(messages: [Message], maxTokens: Int) async throws -> String {
        guard !apiKey.isEmpty else {
            throw LLMError("OpenRouter API key is missing — add it in Settings (⌘,).")
        }
        var request = URLRequest(url: Self.url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // LLM calls can run for minutes on long transcripts.
        request.timeoutInterval = 300
        request.httpBody = try JSONEncoder().encode(
            RequestBody(model: model, messages: messages, max_tokens: maxTokens))

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError("Could not reach OpenRouter: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError("Could not reach OpenRouter.")
        }
        switch http.statusCode {
        case 401:
            throw LLMError("OpenRouter rejected the API key (401). Check the key in Settings.")
        case 402:
            throw LLMError("OpenRouter account is out of credits (402).")
        case 400...499:
            throw LLMError("OpenRouter error (\(http.statusCode)): \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
        default:
            break
        }
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let content = body.choices?.first?.message?.content else {
            throw LLMError("OpenRouter returned an unexpected response.")
        }
        return content
    }

    struct LLMError: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    // MARK: - Quiz JSON validation (port of Llm::parseQuiz)

    static func parseQuiz(_ raw: String) throws -> [QuizQuestion] {
        // Tolerate fenced/narrated output: take the outermost [...] span.
        let payload: Substring
        if let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), end > start {
            payload = raw[start...end]
        } else {
            payload = raw[...]
        }
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let items = decoded as? [Any] else {
            throw LLMError("The model did not return valid quiz JSON. Try again, or switch the model in Settings.")
        }

        var questions: [QuizQuestion] = []
        for item in items {
            guard let item = item as? [String: Any],
                  let question = item["question"] as? String, !question.trimmingCharacters(in: .whitespaces).isEmpty,
                  let options = item["options"] as? [Any], options.count == 4,
                  options.allSatisfy({ ($0 as? String)?.trimmingCharacters(in: .whitespaces).isEmpty == false }),
                  let answer = item["answer"] as? Int, (0...3).contains(answer) else {
                continue
            }
            let explanation = (item["explanation"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            questions.append(QuizQuestion(
                question: question.trimmingCharacters(in: .whitespaces),
                options: options.map { ($0 as! String).trimmingCharacters(in: .whitespaces) },
                answer: answer,
                explanation: explanation))
        }
        guard questions.count >= 3 else {
            throw LLMError("The model returned too few valid questions. Try again.")
        }
        return questions
    }
}
