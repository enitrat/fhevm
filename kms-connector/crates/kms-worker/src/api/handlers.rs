use actix_web::{
    http::StatusCode,
    web::{Data, Path},
    HttpResponse,
};
use alloy::hex;
use sqlx::types::chrono;

use super::server::ApiState;
use super::types::{AnchorBlock, ErrorDetail, ErrorResponse, HealthResponse, ShareResponse};

const DEFAULT_TTL_SECONDS: u64 = 3600;

pub async fn get_share(state: Data<ApiState>, path: Path<String>) -> HttpResponse {
    let request_id = path.into_inner();
    let request_id_bytes = match hex::decode(request_id.trim_start_matches("0x")) {
        Ok(bytes) => bytes,
        Err(_) => {
            return HttpResponse::build(StatusCode::BAD_REQUEST).json(ErrorResponse {
                error: ErrorDetail {
                    code: "INVALID_REQUEST_ID".to_string(),
                    message: "Request ID must be a valid hex string".to_string(),
                    retry_after: None,
                },
            });
        }
    };

    let public_response: Option<(Vec<u8>, Vec<u8>, Option<chrono::NaiveDateTime>)> =
        sqlx::query_as(
            r#"SELECT decrypted_result, signature, created_at 
               FROM public_decryption_responses 
               WHERE decryption_id = $1"#,
        )
        .bind(&request_id_bytes)
        .fetch_optional(&state.db_pool)
        .await
        .ok()
        .flatten();

    if let Some((decrypted_result, signature, created_at)) = public_response {
        let timestamp = created_at
            .map(|dt| dt.and_utc().timestamp() as u64)
            .unwrap_or(0);
        return HttpResponse::Ok().json(ShareResponse::ready_public(
            request_id.clone(),
            hex::encode(&decrypted_result),
            hex::encode(&signature),
            state.signer_address.clone(),
            AnchorBlock {
                number: 0,
                hash: "0x0".to_string(),
            },
            timestamp,
            DEFAULT_TTL_SECONDS,
        ));
    }

    let user_response: Option<(Vec<u8>, Vec<u8>, Option<chrono::NaiveDateTime>)> = sqlx::query_as(
        r#"SELECT user_decrypted_shares, signature, created_at 
           FROM user_decryption_responses 
           WHERE decryption_id = $1"#,
    )
    .bind(&request_id_bytes)
    .fetch_optional(&state.db_pool)
    .await
    .ok()
    .flatten();

    if let Some((user_decrypted_shares, signature, created_at)) = user_response {
        let timestamp = created_at
            .map(|dt| dt.and_utc().timestamp() as u64)
            .unwrap_or(0);
        return HttpResponse::Ok().json(ShareResponse::ready_user(
            request_id.clone(),
            0,
            hex::encode(&user_decrypted_shares),
            hex::encode(&signature),
            state.signer_address.clone(),
            AnchorBlock {
                number: 0,
                hash: "0x0".to_string(),
            },
            timestamp,
            DEFAULT_TTL_SECONDS,
        ));
    }

    let pending_event: Option<Option<chrono::NaiveDateTime>> = sqlx::query_scalar(
        r#"SELECT created_at 
           FROM gateway_events 
           WHERE request_id = $1 AND status = 'pending'"#,
    )
    .bind(&request_id_bytes)
    .fetch_optional(&state.db_pool)
    .await
    .ok()
    .flatten();

    if let Some(created_at) = pending_event {
        let observed_at = created_at
            .map(|dt| dt.and_utc().timestamp() as u64)
            .unwrap_or(0);
        return HttpResponse::Ok().json(ShareResponse::pending(
            request_id,
            observed_at,
            observed_at + 10,
        ));
    }

    HttpResponse::Ok().json(ShareResponse::not_found(
        request_id,
        "Request not observed or expired".to_string(),
    ))
}

pub async fn health(state: Data<ApiState>) -> HttpResponse {
    let uptime = state.start_time.elapsed().as_secs();

    let pending_count: i64 = sqlx::query_scalar(
        r#"SELECT COUNT(*) FROM gateway_events WHERE status = 'pending'"#,
    )
    .fetch_one(&state.db_pool)
    .await
    .unwrap_or(0);

    let last_block: i64 = sqlx::query_scalar(
        r#"SELECT COALESCE(MAX(block_number), 0) FROM gateway_events"#,
    )
    .fetch_one(&state.db_pool)
    .await
    .unwrap_or(0);

    HttpResponse::Ok().json(HealthResponse {
        status: "healthy".to_string(),
        version: "2.0.0".to_string(),
        signer_address: state.signer_address.clone(),
        uptime,
        last_block_processed: last_block as u64,
        pending_requests: pending_count as u64,
    })
}
