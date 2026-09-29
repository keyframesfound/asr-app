<?php

/** OpenRouter chat client for the AI summary and quiz generation.
 *
 * The API key stays server-side (.env) — the browser only ever sees the result.
 */
final class Llm
{
    private const OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions';

    private const LANG_INSTRUCTIONS = [
        'zh-HK' => 'Traditional Chinese as used in Hong Kong (香港繁體). Use Traditional '
            . 'characters and HK written conventions; keep English technical terms in '
            . 'English where that is natural for a HK classroom.',
        'zh-CN' => 'Simplified Chinese (简体中文).',
        'en' => 'English.',
    ];

    public static function summarize(string $transcript, string $lang): string
    {
        $langRule = self::LANG_INSTRUCTIONS[$lang] ?? self::LANG_INSTRUCTIONS['zh-HK'];
        $system = "You are an experienced teaching assistant who summarises lesson transcripts "
            . "for teachers. Write everything in $langRule\n"
            . "Produce a Markdown summary with exactly these sections:\n"
            . "## Overview — 2-3 sentences on what the lesson covered\n"
            . "## Key Points — the main teaching points, as bullets\n"
            . "## Key Terms — important terms/vocabulary with a one-line definition each\n"
            . "## Examples — examples or worked problems that came up, briefly\n"
            . "## Follow-ups — homework, reminders or next steps, if any were mentioned "
            . "(omit the section if there were none)\n"
            . "Use only facts from the transcript; never invent content.";
        return self::chat(
            [
                ['role' => 'system', 'content' => $system],
                ['role' => 'user', 'content' => "Lesson transcript:\n\n$transcript"],
            ],
            4000
        );
    }

    /** @return array<int, array<string, mixed>> */
    public static function makeQuiz(string $transcript, string $lang, int $count): array
    {
        $count = max(1, min($count, 20));
        $langRule = self::LANG_INSTRUCTIONS[$lang] ?? self::LANG_INSTRUCTIONS['zh-HK'];
        $system = 'You are a teacher who writes multiple-choice quizzes from lesson transcripts. '
            . "Write all questions, options and explanations in $langRule\n"
            . "Create exactly $count multiple-choice questions that test understanding of "
            . "the lesson content. Questions must be answerable from the transcript alone, "
            . "with mixed difficulty and plausible distractors.\n"
            . 'Output STRICT JSON only — no markdown fences, no commentary. Format: an array '
            . 'of objects {"question": string, "options": [exactly 4 strings], '
            . '"answer": integer 0-3 (index of the correct option), "explanation": 1-2 '
            . 'sentence explanation of why the answer is correct}';
        $raw = self::chat(
            [
                ['role' => 'system', 'content' => $system],
                ['role' => 'user', 'content' => "Lesson transcript:\n\n$transcript"],
            ],
            8000
        );
        return self::parseQuiz($raw);
    }

    /** @param array<int, array<string, string>> $messages */
    private static function chat(array $messages, int $maxTokens): string
    {
        $key = trim(Env::get('OPENROUTER_API_KEY'));
        if ($key === '') {
            throw new RuntimeException('OpenRouter API key is missing — put OPENROUTER_API_KEY in your .env file.');
        }
        $res = Http::request('POST', self::OPENROUTER_URL, [
            'headers' => ["Authorization: Bearer $key"],
            'json' => [
                'model' => Env::get('OPENROUTER_MODEL', 'deepseek/deepseek-chat'),
                'messages' => $messages,
                'max_tokens' => $maxTokens,
            ],
            'timeout' => 300,
        ]);
        if ($res['error'] !== null) {
            throw new RuntimeException("could not reach OpenRouter: {$res['error']}");
        }
        if ($res['status'] === 401) {
            throw new RuntimeException('OpenRouter rejected the API key (401). Check OPENROUTER_API_KEY in .env.');
        }
        if ($res['status'] === 402) {
            throw new RuntimeException('OpenRouter account is out of credits (402).');
        }
        if ($res['status'] >= 400) {
            throw new RuntimeException("OpenRouter error ({$res['status']}): " . substr($res['body'], 0, 300));
        }
        $content = $res['json']['choices'][0]['message']['content'] ?? null;
        if (!is_string($content)) {
            throw new RuntimeException('OpenRouter returned an unexpected response.');
        }
        return $content;
    }

    /** @return array<int, array<string, mixed>> */
    private static function parseQuiz(string $raw): array
    {
        $start = strpos($raw, '[');
        $end = strrpos($raw, ']');
        $payload = ($start !== false && $end !== false && $end > $start)
            ? substr($raw, $start, $end - $start + 1)
            : $raw;
        $data = json_decode($payload, true);
        if (!is_array($data)) {
            throw new RuntimeException(
                'The model did not return valid quiz JSON. Try again, or switch '
                . 'OPENROUTER_MODEL in .env.'
            );
        }
        if (array_values($data) !== $data) {
            throw new RuntimeException('Unexpected quiz format from the model.');
        }

        $questions = [];
        foreach ($data as $item) {
            if (!is_array($item)) {
                continue;
            }
            $question = $item['question'] ?? null;
            $options = $item['options'] ?? null;
            $answer = $item['answer'] ?? null;
            if (
                !is_string($question) || trim($question) === ''
                || !is_array($options) || count($options) !== 4
                || count(array_filter($options, fn($o) => is_string($o) && trim($o) !== '')) !== 4
                || !is_int($answer) || $answer < 0 || $answer > 3
            ) {
                continue;
            }
            $explanation = $item['explanation'] ?? '';
            $questions[] = [
                'question' => trim($question),
                'options' => array_map(fn($o) => trim($o), $options),
                'answer' => $answer,
                'explanation' => is_scalar($explanation) ? trim(strval($explanation)) : '',
            ];
        }
        if (count($questions) < 3) {
            throw new RuntimeException('The model returned too few valid questions. Try again.');
        }
        return $questions;
    }
}
