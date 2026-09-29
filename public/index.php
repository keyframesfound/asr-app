<?php

declare(strict_types=1);

/**
 * Lesson Transcriber — PHP front controller.
 *
 * Serves the UI and the same JSON API the old Python app exposed:
 *   POST /api/upload        save + forward audio to the SenseVoice sidecar
 *   GET  /api/jobs/{id}     mirrored transcription progress
 *   POST /api/summary       OpenRouter summary
 *   POST /api/quiz          OpenRouter quiz questions
 *   POST /api/forms         create a Google Form quiz (OAuth via popup)
 *   POST /api/docx          Word download of transcript/summary
 *   GET  /                  UI (or the Google OAuth callback when ?code/?error present)
 *   GET  /static/*          static assets
 */

require dirname(__DIR__) . '/src/Env.php';
require dirname(__DIR__) . '/src/Http.php';
require dirname(__DIR__) . '/src/Api.php';
require dirname(__DIR__) . '/src/Llm.php';
require dirname(__DIR__) . '/src/GForms.php';
require dirname(__DIR__) . '/src/Docx.php';
require dirname(__DIR__) . '/src/Jobs.php';

Env::load(dirname(__DIR__) . '/.env');

set_exception_handler(function (Throwable $e): void {
    $uri = $_SERVER['REQUEST_URI'] ?? '';
    if (str_starts_with($uri, '/api')) {
        Api::error(500, 'Server error: ' . $e->getMessage());
    }
    http_response_code(500);
    header('Content-Type: text/plain; charset=utf-8');
    echo 'Server error: ' . htmlspecialchars($e->getMessage(), ENT_QUOTES, 'UTF-8');
});

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$path = rtrim($path, '/');
if ($path === '') {
    $path = '/';
}

/* ---------- static assets ---------- */

if (str_starts_with($path, '/static/')) {
    serve_static(substr($path, strlen('/static/')));
}

/* ---------- UI / OAuth callback ---------- */

if ($path === '/' && $method === 'GET') {
    session_start(); // the OAuth state maps live in the PHP session
    if (isset($_GET['code']) || isset($_GET['error'])) {
        header('Content-Type: text/html; charset=utf-8');
        echo GForms::oauthCallbackHtml(
            strval($_GET['code'] ?? ''),
            strval($_GET['state'] ?? ''),
            strval($_GET['error'] ?? '')
        );
        exit;
    }
    header('Content-Type: text/html; charset=utf-8');
    readfile(__DIR__ . '/static/index.html');
    exit;
}

/* ---------- API ---------- */

if (str_starts_with($path, '/api/')) {
    // LLM and sidecar calls can run for minutes; the default 30s cap would kill them.
    @set_time_limit(0);
}

if ($path === '/api/upload' && $method === 'POST') {
    handle_upload();
}

if (preg_match('#^/api/jobs/([a-f0-9]{12})$#', $path, $m) === 1 && $method === 'GET') {
    handle_job_status($m[1]);
}

if ($path === '/api/summary' && $method === 'POST') {
    $body = read_json_body();
    $transcript = strval($body['transcript'] ?? '');
    if (text_len(trim($transcript)) < 20) {
        Api::error(400, 'Transcript is empty or too short to summarise.');
    }
    try {
        $summary = Llm::summarize($transcript, strval($body['lang'] ?? 'zh-HK'));
    } catch (RuntimeException $exc) {
        Api::error(400, $exc->getMessage());
    }
    Api::json(['summary' => $summary]);
}

if ($path === '/api/quiz' && $method === 'POST') {
    $body = read_json_body();
    $transcript = strval($body['transcript'] ?? '');
    if (text_len(trim($transcript)) < 20) {
        Api::error(400, 'Transcript is empty or too short to quiz on.');
    }
    try {
        $questions = Llm::makeQuiz($transcript, strval($body['lang'] ?? 'zh-HK'), intval($body['count'] ?? 10));
    } catch (RuntimeException $exc) {
        Api::error(400, $exc->getMessage());
    }
    $rawTitle = strval($body['title'] ?? '') !== '' ? strval($body['title']) : 'Lesson';
    $description = 'Auto-generated quiz with ' . count($questions) . ' questions based on the lesson '
        . "recording '" . (strval($body['title'] ?? '') !== '' ? strval($body['title']) : 'lesson') . "'. 1 point each.";
    Api::json([
        'title' => splitext($rawTitle)[0] . ' — Quiz',
        'description' => $description,
        'questions' => $questions,
        'count' => count($questions),
    ]);
}

if ($path === '/api/forms' && $method === 'POST') {
    session_start();
    handle_forms(read_json_body());
}

if ($path === '/api/docx' && $method === 'POST') {
    handle_docx(read_json_body());
}

Api::error(404, 'Not found.');

/* ---------- handlers ---------- */

function handle_upload(): void
{
    $file = $_FILES['file'] ?? null;
    if (!is_array($file) || intval($file['error'] ?? UPLOAD_ERR_NO_FILE) !== UPLOAD_ERR_OK) {
        $code = is_array($file) ? intval($file['error'] ?? UPLOAD_ERR_NO_FILE) : UPLOAD_ERR_NO_FILE;
        Api::error(400, $code === UPLOAD_ERR_INI_SIZE
            ? 'The file is larger than the server allows — raise upload_max_filesize/post_max_size in PHP.'
            : 'No file was uploaded.');
    }
    $filename = strval($file['name'] ?? '') !== '' ? strval($file['name']) : 'audio';
    $ext = strtolower(pathinfo($filename, PATHINFO_EXTENSION));
    if (!in_array($ext, Jobs::ALLOWED_EXTS, true)) {
        Api::error(400, "Unsupported file type '.$ext'. Use MP3, WAV, M4A, AAC, OGG, FLAC or MP4.");
    }

    $lang = strval($_POST['lang'] ?? 'auto');
    if (!in_array($lang, ['auto', 'yue', 'zh', 'en'], true)) {
        $lang = Jobs::defaultLanguage();
    }

    $jobId = bin2hex(random_bytes(6));
    $dest = Jobs::uploadsDir() . "/$jobId.$ext";
    if (!move_uploaded_file(strval($file['tmp_name']), $dest)) {
        Api::error(500, 'Could not store the uploaded file (check the uploads/ folder is writable).');
    }

    $serviceId = Jobs::forwardToService($dest, $filename, $lang);
    if ($serviceId === null) {
        @unlink($dest);
        Api::error(503, 'The transcription service is not reachable at ' . Jobs::serviceUrl()
            . ' — start asr-service first (see README).');
    }

    Jobs::save($jobId, [
        'id' => $jobId,
        'service_id' => $serviceId,
        'filename' => $filename,
        'created' => time(),
        'transcript_saved' => false,
        'last' => null,
    ]);
    Api::json(['job_id' => $jobId, 'filename' => $filename]);
}

function handle_job_status(string $jobId): void
{
    $job = Jobs::load($jobId);
    if ($job === null) {
        Api::error(404, 'Unknown job id.');
    }
    Api::json(Jobs::pollService($jobId, $job));
}

/** @param array<string, mixed> $body */
function handle_forms(array $body): void
{
    if (!GForms::isConfigured()) {
        Api::error(400, 'Google sign-in is not set up yet: add GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET '
            . 'to .env (see README).');
    }
    $questions = is_array($body['questions'] ?? null) ? $body['questions'] : [];
    if ($questions === []) {
        Api::error(400, 'No quiz questions to send to Google Forms.');
    }
    // Every quiz needs its own sign-in: without a just-completed sign-in proof,
    // throw away any cached token and start a fresh OAuth round-trip.
    $challenge = function (): void {
        $state = GForms::issueState();
        Api::json(['auth_url' => GForms::buildAuthUrl($state), 'auth_state' => $state], 401);
    };
    if (!GForms::claimFreshSignin(strval($body['auth_state'] ?? ''))) {
        GForms::forgetToken();
        $challenge();
    }
    try {
        $created = GForms::createQuizForm(
            strval($body['title'] ?? '') !== '' ? strval($body['title']) : 'Lesson Quiz',
            strval($body['description'] ?? ''),
            $questions
        );
    } catch (NotSignedInException) {
        $challenge();
    } catch (RuntimeException $exc) {
        Api::error(400, $exc->getMessage());
    }
    GForms::forgetToken(); // the next quiz must sign in again
    Api::json($created + ['count' => count($questions)]);
}

/** @param array<string, mixed> $body */
function handle_docx(array $body): void
{
    $kind = strval($body['kind'] ?? '');
    if (!in_array($kind, ['transcript', 'summary'], true)) {
        Api::error(400, "kind must be 'transcript' or 'summary'.");
    }
    $text = strval($body['text'] ?? '');
    if (trim($text) === '') {
        Api::error(400, 'Nothing to export yet.');
    }
    $title = strval($body['title'] ?? '');
    $data = Docx::build($kind, $text, $title);

    $base = trim(preg_replace('/[^\p{Xan}_\- ]+/u', '', splitext($title !== '' ? $title : 'lesson')[0]) ?? '');
    if ($base === '') {
        $base = 'lesson';
    }
    $ascii = trim(preg_replace('/[^A-Za-z0-9_\- ]+/', '', $base) ?? '');
    if ($ascii === '') {
        $ascii = 'lesson';
    }
    header('Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document');
    header("Content-Disposition: attachment; filename=\"$ascii-$kind.docx\"; filename*=UTF-8''"
        . rawurlencode("$base-$kind.docx"));
    header('Content-Length: ' . strlen($data));
    echo $data;
    exit;
}

/* ---------- helpers ---------- */

function serve_static(string $requested): void
{
    $file = basename($requested); // basename keeps ../ inside static/
    $full = __DIR__ . '/static/' . $file;
    if ($file === '' || !is_file($full)) {
        http_response_code(404);
        header('Content-Type: text/plain; charset=utf-8');
        echo 'Not found.';
        exit;
    }
    $mimes = [
        'css' => 'text/css; charset=utf-8',
        'js' => 'application/javascript; charset=utf-8',
        'html' => 'text/html; charset=utf-8',
        'png' => 'image/png',
        'svg' => 'image/svg+xml',
        'ico' => 'image/x-icon',
    ];
    $ext = strtolower(pathinfo($file, PATHINFO_EXTENSION));
    $mime = $mimes[$ext] ?? 'application/octet-stream';
    header('Content-Type: ' . $mime);
    header('Content-Length: ' . strval(filesize($full)));
    readfile($full);
    exit;
}

/** @return array<string, mixed> */
function read_json_body(): array
{
    $raw = file_get_contents('php://input');
    $data = json_decode($raw === false ? '' : $raw, true);
    return is_array($data) ? $data : [];
}

/** PHP port of Python's os.path.splitext. @return array{string, string} */
function splitext(string $name): array
{
    $pos = strrpos($name, '.');
    if ($pos === false || $pos === 0) {
        return [$name, ''];
    }
    return [substr($name, 0, $pos), substr($name, $pos)];
}

/** Character count (Unicode-aware when mbstring is available). */
function text_len(string $text): int
{
    return function_exists('mb_strlen') ? mb_strlen($text) : strlen($text);
}
