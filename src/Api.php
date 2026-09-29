<?php

/** JSON response helpers. Errors use the {"detail": ...} shape the frontend expects. */
final class Api
{
    /** @param mixed $data */
    public static function json($data, int $status = 200): void
    {
        http_response_code($status);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode($data, JSON_UNESCAPED_UNICODE);
        exit;
    }

    public static function error(int $status, string $detail): void
    {
        self::json(['detail' => $detail], $status);
    }
}
