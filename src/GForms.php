<?php

/** Google Forms API client — builds quiz forms directly in the teacher's Drive.
 *
 * Uses OAuth 2.0 with the forms.body scope. Every quiz demands its own fresh
 * Google sign-in: the browser visits Google's consent page in a popup, and the
 * exchanged token lives only long enough to create that one form before it is
 * discarded — so the next quiz has to sign in again.
 *
 * Unlike the old Python app (one long-lived process), PHP is shared-nothing per
 * request, so the pending/completed OAuth states live in the PHP session.
 * session_start() must have been called before any method here runs.
 */
final class GForms
{
    public const SCOPE = 'https://www.googleapis.com/auth/forms.body';

    private const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
    private const TOKEN_URL = 'https://oauth2.googleapis.com/token';
    private const FORMS_API = 'https://forms.googleapis.com/v1';
    private const STATE_TTL = 600; // seconds a pending sign-in round-trip stays valid
    private const FRESH_TTL = 300; // seconds a just-completed sign-in counts as proof for one form request

    private static function clientId(): string
    {
        return trim(Env::get('GOOGLE_CLIENT_ID'));
    }

    private static function clientSecret(): string
    {
        return trim(Env::get('GOOGLE_CLIENT_SECRET'));
    }

    /** Must match the "Authorized redirect URI" on the Google Cloud OAuth client exactly. */
    private static function redirectUri(): string
    {
        return Env::get('GOOGLE_REDIRECT_URI', 'http://127.0.0.1:8000/');
    }

    private static function tokenFile(): string
    {
        return dirname(__DIR__) . '/google_token.json';
    }

    public static function isConfigured(): bool
    {
        return self::clientId() !== '' && self::clientSecret() !== '';
    }

    /* ---------- OAuth round-trip ---------- */

    public static function issueState(): string
    {
        $now = time();
        foreach (['pending_states', 'completed_states'] as $map) {
            foreach (($_SESSION[$map] ?? []) as $state => $expiry) {
                if ($expiry < $now) {
                    unset($_SESSION[$map][$state]);
                }
            }
        }
        $state = rtrim(strtr(base64_encode(random_bytes(24)), '+/', '-_'), '=');
        $_SESSION['pending_states'][$state] = $now + self::STATE_TTL;
        return $state;
    }

    /** True if $state completed a Google sign-in just now (consumed on use). */
    public static function claimFreshSignin(string $state): bool
    {
        if (!isset($_SESSION['completed_states'][$state])) {
            return false;
        }
        $expiry = $_SESSION['completed_states'][$state];
        unset($_SESSION['completed_states'][$state]);
        return $expiry >= time();
    }

    public static function buildAuthUrl(string $state): string
    {
        $params = [
            'client_id' => self::clientId(),
            'redirect_uri' => self::redirectUri(),
            'response_type' => 'code',
            'scope' => self::SCOPE,
            'access_type' => 'offline', // we need a refresh token, not just the 1-hour access token
            // Re-ask for the account and the consent on every single sign-in.
            'prompt' => 'consent select_account',
            'state' => $state,
        ];
        return self::AUTH_URL . '?' . http_build_query($params);
    }

    /** Handle the redirect back from Google's consent page (rendered in the popup). */
    public static function oauthCallbackHtml(string $code, string $state, string $error): string
    {
        if ($error !== '') {
            $message = "Google sign-in failed: $error";
            $event = 'oauth-error';
        } elseif ($code === '') {
            $message = 'Google sign-in failed: no authorisation code was returned.';
            $event = 'oauth-error';
        } elseif (!self::consumeState($state)) {
            $message = 'Sign-in session expired — close this window and try again.';
            $event = 'oauth-error';
        } else {
            try {
                self::exchangeCode($code);
                // Mark this round-trip as freshly signed in, claimable by one form request.
                $_SESSION['completed_states'][$state] = time() + self::FRESH_TTL;
                $message = 'Google sign-in complete — you can close this window.';
                $event = 'oauth-done';
            } catch (RuntimeException $exc) {
                $message = "Google sign-in failed: {$exc->getMessage()}";
                $event = 'oauth-error';
            }
        }

        $message = htmlspecialchars($message, ENT_QUOTES, 'UTF-8');
        return <<<HTML
<!doctype html>
<html><body>
<p>$message</p>
<script>
  try {
    window.opener && window.opener.postMessage({ type: "$event" }, "*");
  } catch (e) {}
  setTimeout(function () { window.close(); }, 400);
</script>
</body></html>
HTML;
    }

    private static function consumeState(string $state): bool
    {
        if (!isset($_SESSION['pending_states'][$state])) {
            return false;
        }
        $expiry = $_SESSION['pending_states'][$state];
        unset($_SESSION['pending_states'][$state]);
        return $expiry >= time();
    }

    private static function exchangeCode(string $code): void
    {
        $res = Http::request('POST', self::TOKEN_URL, [
            'form' => [
                'client_id' => self::clientId(),
                'client_secret' => self::clientSecret(),
                'code' => $code,
                'grant_type' => 'authorization_code',
                'redirect_uri' => self::redirectUri(),
            ],
            'timeout' => 30,
        ]);
        if ($res['status'] !== 200) {
            $detail = is_array($res['json']) && !empty($res['json']['error_description'])
                ? strval($res['json']['error_description'])
                : $res['body'];
            throw new RuntimeException("token exchange failed ({$res['status']}): $detail");
        }
        $data = is_array($res['json']) ? $res['json'] : [];
        if (empty($data['access_token'])) {
            throw new RuntimeException('token exchange returned no access token');
        }
        $previous = self::loadToken() ?? [];
        self::saveToken([
            'access_token' => $data['access_token'],
            'refresh_token' => isset($data['refresh_token']) ? $data['refresh_token'] : ($previous['refresh_token'] ?? ''),
            'expires_at' => time() + intval($data['expires_in'] ?? 3600),
        ]);
    }

    /* ---------- token cache ---------- */

    /** @return array<string, mixed>|null */
    private static function loadToken(): ?array
    {
        $raw = @file_get_contents(self::tokenFile());
        if ($raw === false) {
            return null;
        }
        $token = json_decode($raw, true);
        return is_array($token) ? $token : null;
    }

    /** @param array<string, mixed> $token */
    private static function saveToken(array $token): void
    {
        file_put_contents(self::tokenFile(), json_encode($token), LOCK_EX);
        @chmod(self::tokenFile(), 0600);
    }

    public static function forgetToken(): void
    {
        @unlink(self::tokenFile());
    }

    private static function bearer(): string
    {
        $token = self::loadToken();
        if ($token === null || empty($token['access_token'])) {
            throw new NotSignedInException('no Google sign-in yet');
        }
        if (intval($token['expires_at'] ?? 0) - 60 < time()) {
            $token = self::refresh($token);
        }
        return strval($token['access_token']);
    }

    /** @param array<string, mixed> $token @return array<string, mixed> */
    private static function refresh(array $token): array
    {
        $res = Http::request('POST', self::TOKEN_URL, [
            'form' => [
                'client_id' => self::clientId(),
                'client_secret' => self::clientSecret(),
                'refresh_token' => strval($token['refresh_token'] ?? ''),
                'grant_type' => 'refresh_token',
            ],
            'timeout' => 30,
        ]);
        if ($res['status'] !== 200) {
            self::forgetToken();
            throw new NotSignedInException('sign-in has expired, please sign in again');
        }
        $data = is_array($res['json']) ? $res['json'] : [];
        if (empty($data['access_token'])) {
            self::forgetToken();
            throw new NotSignedInException('sign-in has expired, please sign in again');
        }
        $token['access_token'] = $data['access_token'];
        $token['expires_at'] = time() + intval($data['expires_in'] ?? 3600);
        self::saveToken($token);
        return $token;
    }

    /* ---------- form creation ---------- */

    /** Create a quiz-mode form; returns {form_id, form_url, edit_url}.
     *
     * @param array<int, array<string, mixed>> $questions
     * @return array{form_id: string, form_url: string, edit_url: string}
     */
    public static function createQuizForm(string $title, string $description, array $questions): array
    {
        $headers = ['Authorization: Bearer ' . self::bearer()];
        $res = Http::request('POST', self::FORMS_API . '/forms', [
            'headers' => $headers,
            'json' => ['info' => ['title' => $title !== '' ? $title : 'Lesson Quiz']],
            'timeout' => 60,
        ]);
        $form = self::check($res);
        $formId = strval($form['formId'] ?? '');
        if ($formId === '') {
            throw new RuntimeException('Google Forms API returned no form id.');
        }

        // Quiz mode must be on before graded items exist.
        $res = Http::request('POST', self::FORMS_API . "/forms/$formId:batchUpdate", [
            'headers' => $headers,
            'json' => [
                'requests' => [
                    [
                        'updateFormInfo' => [
                            'info' => ['description' => $description],
                            'updateMask' => 'description',
                        ],
                    ],
                    [
                        'updateSettings' => [
                            'settings' => [
                                'quizSettings' => ['isQuiz' => true],
                                'emailCollectionType' => 'DO_NOT_COLLECT',
                            ],
                            'updateMask' => 'quizSettings,emailCollectionType',
                        ],
                    ],
                ],
            ],
            'timeout' => 60,
        ]);
        self::check($res);

        $requests = [];
        foreach (array_values($questions) as $i => $question) {
            $requests[] = ['createItem' => ['item' => self::questionItem($question), 'location' => ['index' => $i]]];
        }
        $res = Http::request('POST', self::FORMS_API . "/forms/$formId:batchUpdate", [
            'headers' => $headers,
            'json' => ['requests' => $requests],
            'timeout' => 120,
        ]);
        self::check($res);

        return [
            'form_id' => $formId,
            'form_url' => strval($form['responderUri'] ?? ''),
            'edit_url' => "https://docs.google.com/forms/d/$formId/edit",
        ];
    }

    /** @param array{status: int, body: string, json: mixed, error: ?string} $res @return array<string, mixed> */
    private static function check(array $res): array
    {
        if ($res['error'] !== null) {
            throw new RuntimeException("could not reach the Google Forms API: {$res['error']}");
        }
        if ($res['status'] >= 400) {
            $message = is_array($res['json']) && !empty($res['json']['error']['message'])
                ? strval($res['json']['error']['message'])
                : $res['body'];
            throw new RuntimeException("Google Forms API error ({$res['status']}): $message");
        }
        return is_array($res['json']) ? $res['json'] : [];
    }

    /** @param array<string, mixed> $q @return array<string, mixed> */
    private static function questionItem(array $q): array
    {
        $options = $q['options'] ?? null;
        $answer = $q['answer'] ?? null;
        if (!is_array($options) || !is_int($answer) || !isset($options[$answer]) || !is_string($options[$answer])) {
            throw new RuntimeException('A quiz question was malformed (missing options or answer).');
        }
        $grading = [
            'pointValue' => 1,
            'correctAnswers' => ['answers' => [['value' => $options[$answer]]]],
        ];
        $explanation = is_scalar($q['explanation'] ?? '') ? trim(strval($q['explanation'] ?? '')) : '';
        if ($explanation !== '') {
            $grading['whenWrong'] = ['text' => $explanation];
        }
        return [
            'title' => is_string($q['question'] ?? null) ? $q['question'] : '',
            'questionItem' => [
                'question' => [
                    'required' => true,
                    'choiceQuestion' => [
                        'type' => 'RADIO',
                        'options' => array_map(fn($option) => ['value' => $option], $options),
                    ],
                    'grading' => $grading,
                ],
            ],
        ];
    }
}

/** No usable Google token — the browser must visit the consent URL first. */
class NotSignedInException extends RuntimeException
{
}
