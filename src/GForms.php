<?php

/** Google sign-in + Forms API client — builds quiz forms in the teacher's Drive.
 *
 * Sign-in is once per browser session: the browser visits Google's consent page
 * in a popup, and the exchanged token (with its refresh token) lives in the PHP
 * session until the teacher signs out or the browser session ends. Every AI
 * endpoint checks GForms::isSignedIn() before it will run.
 *
 * Unlike the old Python app (one long-lived process), PHP is shared-nothing per
 * request, so the token and the pending OAuth states live in the PHP session.
 * session_start() must have been called before any method here runs, and the
 * session must still be open wherever a token may be written back (refresh).
 */
final class GForms
{
    public const SCOPE = 'https://www.googleapis.com/auth/forms.body'
        . ' https://www.googleapis.com/auth/userinfo.email'
        . ' https://www.googleapis.com/auth/userinfo.profile';

    private const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
    private const TOKEN_URL = 'https://oauth2.googleapis.com/token';
    private const USERINFO_URL = 'https://www.googleapis.com/oauth2/v3/userinfo';
    private const FORMS_API = 'https://forms.googleapis.com/v1';
    private const STATE_TTL = 600; // seconds a pending sign-in round-trip stays valid
    private const REFRESH_AHEAD = 300; // refresh the access token this many seconds before it lapses

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

    public static function isConfigured(): bool
    {
        return self::clientId() !== '' && self::clientSecret() !== '';
    }

    /* ---------- session sign-in state ---------- */

    /** True when the browser session holds a usable Google token. */
    public static function isSignedIn(): bool
    {
        $token = $_SESSION['google_token'] ?? null;
        if (!is_array($token) || empty($token['access_token'])) {
            return false;
        }
        if (intval($token['expires_at'] ?? 0) - self::REFRESH_AHEAD >= time()) {
            return true;
        }
        return trim(strval($token['refresh_token'] ?? '')) !== '';
    }

    public static function signedInEmail(): string
    {
        $token = $_SESSION['google_token'] ?? null;
        return is_array($token) ? strval($token['email'] ?? '') : '';
    }

    public static function signOut(): void
    {
        unset($_SESSION['google_token']);
    }

    /* ---------- OAuth round-trip ---------- */

    public static function issueState(): string
    {
        $now = time();
        foreach (($_SESSION['pending_states'] ?? []) as $state => $expiry) {
            if ($expiry < $now) {
                unset($_SESSION['pending_states'][$state]);
            }
        }
        $state = rtrim(strtr(base64_encode(random_bytes(24)), '+/', '-_'), '=');
        $_SESSION['pending_states'][$state] = $now + self::STATE_TTL;
        return $state;
    }

    public static function buildAuthUrl(string $state): string
    {
        $params = [
            'client_id' => self::clientId(),
            'redirect_uri' => self::redirectUri(),
            'response_type' => 'code',
            'scope' => self::SCOPE,
            'access_type' => 'offline', // we need a refresh token, not just the 1-hour access token
            // Re-ask for the account and the consent on every sign-in so a
            // refresh token is always granted, even for returning accounts.
            'prompt' => 'consent select_account',
            'state' => $state,
        ];
        return self::AUTH_URL . '?' . http_build_query($params);
    }

    /** Handle the redirect back from Google's consent page (rendered in the popup).
     *
     * Completes the sign-in into the session and returns the message to show.
     * @return array{ok: bool, message: string, email: string, event: string}
     */
    public static function handleCallback(string $code, string $state, string $error): array
    {
        if ($error !== '') {
            return ['ok' => false, 'message' => "Google sign-in failed: $error", 'email' => '', 'event' => 'google-auth-error'];
        }
        if ($code === '') {
            return ['ok' => false, 'message' => 'Google sign-in failed: no authorisation code was returned.', 'email' => '', 'event' => 'google-auth-error'];
        }
        if (!self::consumeState($state)) {
            return ['ok' => false, 'message' => 'Sign-in session expired — close this window and try again.', 'email' => '', 'event' => 'google-auth-error'];
        }
        try {
            $token = self::exchangeCode($code);
        } catch (RuntimeException $exc) {
            return ['ok' => false, 'message' => 'Google sign-in failed: ' . $exc->getMessage(), 'email' => '', 'event' => 'google-auth-error'];
        }
        $_SESSION['google_token'] = $token;
        $email = strval($token['email'] ?? '');
        $message = $email !== ''
            ? "Signed in as $email — you can close this window."
            : 'Google sign-in complete — you can close this window.';
        return ['ok' => true, 'message' => $message, 'email' => $email, 'event' => 'google-auth-done'];
    }

    /** Rendered inside the popup; posts the outcome to the opener, then closes. */
    public static function callbackHtml(array $result): string
    {
        $message = htmlspecialchars($result['message'], ENT_QUOTES, 'UTF-8');
        $event = $result['event'];
        $email = htmlspecialchars($result['email'], ENT_QUOTES, 'UTF-8');
        return <<<HTML
<!doctype html>
<html><body>
<p>$message</p>
<script>
  try {
    window.opener && window.opener.postMessage({ type: "$event", email: "$email" }, "*");
  } catch (e) {}
  setTimeout(function () { window.close(); }, 800);
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

    /** @return array<string, mixed> */
    private static function exchangeCode(string $code): array
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
        return [
            'access_token' => $data['access_token'],
            'refresh_token' => strval($data['refresh_token'] ?? ''),
            'expires_at' => time() + intval($data['expires_in'] ?? 3600),
            'email' => self::fetchEmail(strval($data['access_token'])),
        ];
    }

    /** Best effort — an empty email just means the UI shows a generic signed-in state. */
    private static function fetchEmail(string $accessToken): string
    {
        $res = Http::request('GET', self::USERINFO_URL, [
            'headers' => ["Authorization: Bearer $accessToken"],
            'timeout' => 15,
        ]);
        $email = is_array($res['json']) ? strval($res['json']['email'] ?? '') : '';
        return filter_var($email, FILTER_VALIDATE_EMAIL) ? $email : '';
    }

    /* ---------- token upkeep ---------- */

    /** Refresh the session's access token if it lapses soon. Call with the session
     * open so the renewed token is persisted. */
    public static function ensureFreshToken(): void
    {
        $token = $_SESSION['google_token'] ?? null;
        if (!is_array($token) || empty($token['access_token'])) {
            throw new NotSignedInException('no Google sign-in yet');
        }
        if (intval($token['expires_at'] ?? 0) - self::REFRESH_AHEAD >= time()) {
            return;
        }
        $refresh = trim(strval($token['refresh_token'] ?? ''));
        if ($refresh === '') {
            self::signOut();
            throw new NotSignedInException('your Google session has expired — sign in again');
        }
        $res = Http::request('POST', self::TOKEN_URL, [
            'form' => [
                'client_id' => self::clientId(),
                'client_secret' => self::clientSecret(),
                'refresh_token' => $refresh,
                'grant_type' => 'refresh_token',
            ],
            'timeout' => 30,
        ]);
        $data = is_array($res['json']) ? $res['json'] : [];
        if ($res['status'] !== 200 || empty($data['access_token'])) {
            self::signOut();
            throw new NotSignedInException('your Google session has expired — sign in again');
        }
        $_SESSION['google_token'] = [
            'access_token' => strval($data['access_token']),
            'refresh_token' => $refresh,
            'expires_at' => time() + intval($data['expires_in'] ?? 3600),
            'email' => strval($token['email'] ?? ''),
        ];
    }

    /** The in-memory session token — ensureFreshToken() must have run first. */
    private static function bearer(): string
    {
        $token = is_array($_SESSION['google_token'] ?? null) ? $_SESSION['google_token'] : [];
        if (empty($token['access_token']) || intval($token['expires_at'] ?? 0) - 60 < time()) {
            throw new NotSignedInException('your Google session has expired — sign in again');
        }
        return strval($token['access_token']);
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

/** No usable Google sign-in — the browser must visit the consent URL first. */
class NotSignedInException extends RuntimeException
{
}
