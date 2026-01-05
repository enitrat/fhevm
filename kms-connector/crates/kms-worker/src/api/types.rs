use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShareStatus {
    Ready,
    Pending,
    NotFound,
    Rejected,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RequestType {
    UserDecryption,
    PublicDecryption,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AnchorBlock {
    pub number: u64,
    pub hash: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ShareResponse {
    pub status: ShareStatus,
    pub request_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_type: Option<RequestType>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub share_index: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub encrypted_share: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub decrypted_value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signer_address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub anchor_block: Option<AnchorBlock>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ttl: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub observed_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimated_ready_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
}

impl ShareResponse {
    pub fn ready_user(
        request_id: String,
        share_index: u64,
        encrypted_share: String,
        signature: String,
        signer_address: String,
        anchor_block: AnchorBlock,
        timestamp: u64,
        ttl: u64,
    ) -> Self {
        Self {
            status: ShareStatus::Ready,
            request_id,
            request_type: Some(RequestType::UserDecryption),
            share_index: Some(share_index),
            encrypted_share: Some(encrypted_share),
            decrypted_value: None,
            signature: Some(signature),
            signer_address: Some(signer_address),
            anchor_block: Some(anchor_block),
            timestamp: Some(timestamp),
            ttl: Some(ttl),
            observed_at: None,
            estimated_ready_at: None,
            reason: None,
            error_code: None,
        }
    }

    pub fn ready_public(
        request_id: String,
        decrypted_value: String,
        signature: String,
        signer_address: String,
        anchor_block: AnchorBlock,
        timestamp: u64,
        ttl: u64,
    ) -> Self {
        Self {
            status: ShareStatus::Ready,
            request_id,
            request_type: Some(RequestType::PublicDecryption),
            share_index: None,
            encrypted_share: None,
            decrypted_value: Some(decrypted_value),
            signature: Some(signature),
            signer_address: Some(signer_address),
            anchor_block: Some(anchor_block),
            timestamp: Some(timestamp),
            ttl: Some(ttl),
            observed_at: None,
            estimated_ready_at: None,
            reason: None,
            error_code: None,
        }
    }

    pub fn pending(request_id: String, observed_at: u64, estimated_ready_at: u64) -> Self {
        Self {
            status: ShareStatus::Pending,
            request_id,
            request_type: None,
            share_index: None,
            encrypted_share: None,
            decrypted_value: None,
            signature: None,
            signer_address: None,
            anchor_block: None,
            timestamp: None,
            ttl: None,
            observed_at: Some(observed_at),
            estimated_ready_at: Some(estimated_ready_at),
            reason: None,
            error_code: None,
        }
    }

    pub fn not_found(request_id: String, reason: String) -> Self {
        Self {
            status: ShareStatus::NotFound,
            request_id,
            request_type: None,
            share_index: None,
            encrypted_share: None,
            decrypted_value: None,
            signature: None,
            signer_address: None,
            anchor_block: None,
            timestamp: None,
            ttl: None,
            observed_at: None,
            estimated_ready_at: None,
            reason: Some(reason),
            error_code: None,
        }
    }

    pub fn rejected(request_id: String, reason: String, error_code: String) -> Self {
        Self {
            status: ShareStatus::Rejected,
            request_id,
            request_type: None,
            share_index: None,
            encrypted_share: None,
            decrypted_value: None,
            signature: None,
            signer_address: None,
            anchor_block: None,
            timestamp: None,
            ttl: None,
            observed_at: None,
            estimated_ready_at: None,
            reason: Some(reason),
            error_code: Some(error_code),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct HealthResponse {
    pub status: String,
    pub version: String,
    pub signer_address: String,
    pub uptime: u64,
    pub last_block_processed: u64,
    pub pending_requests: u64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ErrorResponse {
    pub error: ErrorDetail,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ErrorDetail {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_after: Option<u64>,
}
