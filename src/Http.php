<?php

/** Thin cURL wrapper — the only HTTP client the app uses. */
final class Http
{
    /**
     * @param array<string, mixed> $opts headers: string[], json: mixed, form: array,
     *        multipart: array (values may be CURLFile), timeout: int, connect_timeout: int
     * @return array{status: int, body: string, json: mixed, error: ?string}
     */
    public static function request(string $method, string $url, array $opts = []): array
    {
        $ch = curl_init($url);
        if ($ch === false) {
            return ['status' => 0, 'body' => '', 'json' => null, 'error' => 'could not initialise curl'];
        }
        $headers = $opts['headers'] ?? [];
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_MAXREDIRS => 5,
            CURLOPT_CONNECTTIMEOUT => $opts['connect_timeout'] ?? 10,
            CURLOPT_TIMEOUT => $opts['timeout'] ?? 30,
        ]);
        if (array_key_exists('json', $opts) && $opts['json'] !== null) {
            $headers[] = 'Content-Type: application/json';
            curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($opts['json'], JSON_UNESCAPED_UNICODE));
        } elseif (!empty($opts['form'])) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($opts['form']));
        } elseif (!empty($opts['multipart'])) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, $opts['multipart']);
        }
        if (strtoupper($method) !== 'GET') {
            curl_setopt($ch, CURLOPT_CUSTOMREQUEST, strtoupper($method));
        }
        if ($headers !== []) {
            curl_setopt($ch, CURLOPT_HTTPHEADER, $headers);
        }

        $body = curl_exec($ch);
        $errno = curl_errno($ch);
        $error = $errno !== 0 ? curl_error($ch) : null;
        $status = intval(curl_getinfo($ch, CURLINFO_RESPONSE_CODE));
        curl_close($ch);

        if ($body === false) {
            $body = '';
        }
        return ['status' => $status, 'body' => $body, 'json' => json_decode($body, true), 'error' => $error];
    }
}
