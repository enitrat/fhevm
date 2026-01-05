use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use sqlx::types::time::PrimitiveDateTime;
use std::sync::Arc;

use super::server::ApiState;
use super::types::{
    CiphertextResponse, CoprocessorHealthResponse, ErrorDetail, ErrorResponse,
    VerifyInputRequest, VerifyInputResponse,
};

pub async fn verify_input(
    State(state): State<Arc<ApiState>>,
    Json(request): Json<VerifyInputRequest>,
) -> impl IntoResponse {
    let request_id_bytes = match hex::decode(request.request_id.trim_start_matches("0x")) {
        Ok(bytes) => bytes,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrorResponse {
                    error: ErrorDetail {
                        code: "INVALID_REQUEST_ID".to_string(),
                        message: "Request ID must be a valid hex string".to_string(),
                        retry_after: None,
                    },
                }),
            )
                .into_response();
        }
    };

    let commitment_bytes = match hex::decode(request.commitment.trim_start_matches("0x")) {
        Ok(bytes) => bytes,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrorResponse {
                    error: ErrorDetail {
                        code: "INVALID_COMMITMENT".to_string(),
                        message: "Commitment must be a valid hex string".to_string(),
                        retry_after: None,
                    },
                }),
            )
                .into_response();
        }
    };

    let registered_event: Option<(Vec<u8>, Option<PrimitiveDateTime>)> = sqlx::query_as(
        r#"SELECT commitment, created_at 
           FROM verify_proofs 
           WHERE request_id = $1"#,
    )
    .bind(&request_id_bytes)
    .fetch_optional(&state.db_pool)
    .await
    .ok()
    .flatten();

    let Some((db_commitment, _created_at)) = registered_event else {
        return (
            StatusCode::OK,
            Json(VerifyInputResponse::rejected(
                request.request_id,
                "Request not observed on-chain".to_string(),
                "REQUEST_NOT_FOUND".to_string(),
            )),
        )
            .into_response();
    };

    if db_commitment != commitment_bytes {
        return (
            StatusCode::OK,
            Json(VerifyInputResponse::rejected(
                request.request_id,
                "Payload hash does not match on-chain commitment".to_string(),
                "COMMITMENT_MISMATCH".to_string(),
            )),
        )
            .into_response();
    }

    let verified_result: Option<(bool, Option<Vec<u8>>, Option<PrimitiveDateTime>)> =
        sqlx::query_as(
            r#"SELECT verified, handles, verified_at 
               FROM verify_proofs 
               WHERE request_id = $1"#,
        )
        .bind(&request_id_bytes)
        .fetch_optional(&state.db_pool)
        .await
        .ok()
        .flatten();

    match verified_result {
        Some((true, Some(handles_bytes), Some(verified_at))) => {
            let handles = parse_handles_from_bytes(&handles_bytes);
            let timestamp = verified_at.assume_utc().unix_timestamp() as u64;
            (
                StatusCode::OK,
                Json(VerifyInputResponse::verified(
                    request.request_id,
                    handles,
                    "0x".to_string(),
                    state.signer_address.clone(),
                    timestamp,
                )),
            )
                .into_response()
        }
        Some((false, _, _)) => (
            StatusCode::OK,
            Json(VerifyInputResponse::rejected(
                request.request_id,
                "ZKPoK verification failed".to_string(),
                "ZKPOK_INVALID".to_string(),
            )),
        )
            .into_response(),
        _ => (
            StatusCode::OK,
            Json(VerifyInputResponse::pending(request.request_id)),
        )
            .into_response(),
    }
}

fn parse_handles_from_bytes(handles_bytes: &[u8]) -> Vec<String> {
    handles_bytes
        .chunks(32)
        .map(|chunk| format!("0x{}", hex::encode(chunk)))
        .collect()
}

pub async fn get_ciphertext(
    State(state): State<Arc<ApiState>>,
    Path(handle): Path<String>,
) -> impl IntoResponse {
    let handle_bytes = match hex::decode(handle.trim_start_matches("0x")) {
        Ok(bytes) => bytes,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ErrorResponse {
                    error: ErrorDetail {
                        code: "INVALID_HANDLE".to_string(),
                        message: "Handle must be a valid hex string".to_string(),
                        retry_after: None,
                    },
                }),
            )
                .into_response();
        }
    };

    let ciphertext_result: Option<(
        Vec<u8>,
        Option<Vec<u8>>,
        Option<PrimitiveDateTime>,
    )> = sqlx::query_as(
        r#"SELECT cd.ciphertext128, cd.ciphertext, cd.created_at
           FROM ciphertext_digest cd
           WHERE cd.handle = $1
           LIMIT 1"#,
    )
    .bind(&handle_bytes)
    .fetch_optional(&state.db_pool)
    .await
    .ok()
    .flatten();

    match ciphertext_result {
        Some((sns_ct, digest, created_at)) => {
            let timestamp = created_at
                .map(|dt| dt.assume_utc().unix_timestamp() as u64)
                .unwrap_or(0);

            let sns_ciphertext = hex::encode(&sns_ct);
            let sns_digest = digest.map(|d| hex::encode(&d)).unwrap_or_default();

            (
                StatusCode::OK,
                Json(CiphertextResponse::found(
                    handle,
                    1,
                    format!("0x{}", sns_ciphertext),
                    format!("0x{}", sns_digest),
                    timestamp,
                    "0x".to_string(),
                    state.signer_address.clone(),
                )),
            )
                .into_response()
        }
        None => (
            StatusCode::OK,
            Json(CiphertextResponse::not_found(
                handle,
                "Ciphertext not stored by this coprocessor".to_string(),
            )),
        )
            .into_response(),
    }
}

pub async fn health(State(state): State<Arc<ApiState>>) -> impl IntoResponse {
    let uptime = state.start_time.elapsed().as_secs();

    let stored_ciphertexts: i64 = sqlx::query_scalar(r#"SELECT COUNT(*) FROM ciphertext_digest"#)
        .fetch_one(&state.db_pool)
        .await
        .unwrap_or(0);

    let pending_verifications: i64 = sqlx::query_scalar(
        r#"SELECT COUNT(*) FROM verify_proofs WHERE verified IS NULL"#,
    )
    .fetch_one(&state.db_pool)
    .await
    .unwrap_or(0);

    let last_block: i64 =
        sqlx::query_scalar(r#"SELECT COALESCE(MAX(block_number), 0) FROM verify_proofs"#)
            .fetch_one(&state.db_pool)
            .await
            .unwrap_or(0);

    Json(CoprocessorHealthResponse {
        status: "healthy".to_string(),
        version: "2.0.0".to_string(),
        signer_address: state.signer_address.clone(),
        uptime,
        last_block_processed: last_block as u64,
        stored_ciphertexts: stored_ciphertexts as u64,
        pending_verifications: pending_verifications as u64,
    })
}
