<?php

/** Transcription job store + proxy to the SenseVoice sidecar service.
 *
 * The heavy lifting (ffmpeg, VAD, SenseVoice) happens in the Python sidecar
 * (asr-service/); PHP owns the browser-facing job lifecycle. Each job is a
 * small JSON file under jobs/ so state survives PHP's per-request model, and
 * the sidecar's last known status is mirrored into it for /api/jobs polling.
 */
final class Jobs
{
    public const ALLOWED_EXTS = ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac', 'mp4'];

    private static function root(): string
    {
        return dirname(__DIR__);
    }

    public static function uploadsDir(): string
    {
        return self::ensureDir(self::root() . '/uploads');
    }

    private static function jobsDir(): string
    {
        return self::ensureDir(self::root() . '/jobs');
    }

    private static function transcriptsDir(): string
    {
        return self::ensureDir(self::root() . '/transcripts');
    }

    private static function ensureDir(string $dir): string
    {
        if (!is_dir($dir)) {
            @mkdir($dir, 0775, true);
        }
        return $dir;
    }

    public static function serviceUrl(): string
    {
        return rtrim(Env::get('ASR_SERVICE_URL', 'http://127.0.0.1:8100'), '/');
    }

    public static function defaultLanguage(): string
    {
        return Env::get('ASR_LANGUAGE', 'auto');
    }

    /**
     * Forward an uploaded file to the sidecar and return its job id.
     * @return string|null null when the sidecar is unreachable or rejects the file
     */
    public static function forwardToService(string $path, string $filename, string $lang): ?string
    {
        $res = Http::request('POST', self::serviceUrl() . '/api/upload', [
            'multipart' => [
                'file' => new CURLFile($path, '', $filename),
                'lang' => $lang,
            ],
            'connect_timeout' => 5,
            'timeout' => 600,
        ]);
        if ($res['error'] !== null || $res['status'] >= 400) {
            return null;
        }
        $jobId = $res['json']['job_id'] ?? null;
        return is_string($jobId) && $jobId !== '' ? $jobId : null;
    }

    /** @param array<string, mixed> $job */
    public static function save(string $jobId, array $job): void
    {
        file_put_contents(
            self::jobsDir() . "/$jobId.json",
            json_encode($job, JSON_UNESCAPED_UNICODE),
            LOCK_EX
        );
    }

    /** @return array<string, mixed>|null */
    public static function load(string $jobId): ?array
    {
        $raw = @file_get_contents(self::jobsDir() . "/$jobId.json");
        if ($raw === false) {
            return null;
        }
        $job = json_decode($raw, true);
        return is_array($job) ? $job : null;
    }

    /**
     * Fetch the live status from the sidecar and mirror it into the job file.
     * Falls back to the last mirrored state when the sidecar has lost the job.
     * @param array<string, mixed> $job
     * @return array<string, mixed> the browser-facing job status
     */
    public static function pollService(string $jobId, array $job): array
    {
        $res = Http::request('GET', self::serviceUrl() . '/api/jobs/' . urlencode(strval($job['service_id'] ?? '')), [
            'connect_timeout' => 3,
            'timeout' => 15,
        ]);

        if ($res['error'] !== null || $res['status'] === 404) {
            $last = is_array($job['last'] ?? null) ? $job['last'] : null;
            if ($last !== null && in_array($last['status'] ?? '', ['done', 'error'], true)) {
                return $last;
            }
            return [
                'status' => 'error',
                'progress' => 0,
                'stage' => 'Failed',
                'indeterminate' => false,
                'error' => $res['error'] !== null
                    ? 'The transcription service is not reachable at ' . self::serviceUrl()
                        . ' — is asr-service running?'
                    : 'The transcription service restarted and lost this job. Please upload the file again.',
                'filename' => strval($job['filename'] ?? ''),
                'segments' => [],
            ];
        }
        if ($res['status'] >= 400 || !is_array($res['json'])) {
            return [
                'status' => 'error',
                'progress' => 0,
                'stage' => 'Failed',
                'indeterminate' => false,
                'error' => "Transcription service error ({$res['status']}).",
                'filename' => strval($job['filename'] ?? ''),
                'segments' => [],
            ];
        }

        $status = $res['json'];
        $job['last'] = $status;
        if (($status['status'] ?? '') === 'done' && empty($job['transcript_saved'])) {
            self::writeTranscriptFile(
                $jobId,
                strval($job['filename'] ?? 'lesson'),
                is_array($status['segments'] ?? null) ? $status['segments'] : []
            );
            $job['transcript_saved'] = true;
        }
        self::save($jobId, $job);
        return $status;
    }

    /** @param array<int, mixed> $segments */
    private static function writeTranscriptFile(string $jobId, string $filename, array $segments): void
    {
        $lines = ["# $filename", ''];
        foreach ($segments as $seg) {
            if (!is_array($seg)) {
                continue;
            }
            $start = is_numeric($seg['start'] ?? null) ? floatval($seg['start']) : 0.0;
            $text = is_string($seg['text'] ?? null) ? $seg['text'] : '';
            $lines[] = '[' . self::fmtTs($start) . "] $text";
        }
        file_put_contents(
            self::transcriptsDir() . "/$jobId.txt",
            implode("\n", $lines) . "\n",
            LOCK_EX
        );
    }

    private static function fmtTs(float $seconds): string
    {
        $total = intval($seconds);
        $m = intdiv($total, 60);
        $s = $total % 60;
        $h = intdiv($m, 60);
        $m = $m % 60;
        return $h > 0
            ? sprintf('%d:%02d:%02d', $h, $m, $s)
            : sprintf('%02d:%02d', $m, $s);
    }
}
