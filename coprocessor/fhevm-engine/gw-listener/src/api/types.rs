use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VerifyInputStatus {
    Verified,
    Pending,
    Rejected,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct VerifyInputRequest {
    #[serde(rename = "requestId")]
    pub request_id: String,
    #[serde(rename = "ciphertextWithZkpok")]
    pub ciphertext_with_zkpok: String,
    #[serde(rename = "contractChainId")]
    pub contract_chain_id: u64,
    #[serde(rename = "contractAddress")]
    pub contract_address: String,
    #[serde(rename = "userAddress")]
    pub user_address: String,
    pub commitment: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct VerifyInputResponse {
    pub status: VerifyInputStatus,
    #[serde(rename = "requestId")]
    pub request_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub handles: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
    #[serde(rename = "signerAddress", skip_serializing_if = "Option::is_none")]
    pub signer_address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(rename = "errorCode", skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
}

impl VerifyInputResponse {
    pub fn verified(
        request_id: String,
        handles: Vec<String>,
        signature: String,
        signer_address: String,
        timestamp: u64,
    ) -> Self {
        Self {
            status: VerifyInputStatus::Verified,
            request_id,
            handles: Some(handles),
            signature: Some(signature),
            signer_address: Some(signer_address),
            timestamp: Some(timestamp),
            reason: None,
            error_code: None,
        }
    }

    pub fn pending(request_id: String) -> Self {
        Self {
            status: VerifyInputStatus::Pending,
            request_id,
            handles: None,
            signature: None,
            signer_address: None,
            timestamp: None,
            reason: None,
            error_code: None,
        }
    }

    pub fn rejected(request_id: String, reason: String, error_code: String) -> Self {
        Self {
            status: VerifyInputStatus::Rejected,
            request_id,
            handles: None,
            signature: None,
            signer_address: None,
            timestamp: None,
            reason: Some(reason),
            error_code: Some(error_code),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CiphertextStatus {
    Found,
    NotFound,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CiphertextResponse {
    pub status: CiphertextStatus,
    pub handle: String,
    #[serde(rename = "keyId", skip_serializing_if = "Option::is_none")]
    pub key_id: Option<u64>,
    #[serde(rename = "snsCiphertext", skip_serializing_if = "Option::is_none")]
    pub sns_ciphertext: Option<String>,
    #[serde(rename = "snsCiphertextDigest", skip_serializing_if = "Option::is_none")]
    pub sns_ciphertext_digest: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
    #[serde(rename = "signerAddress", skip_serializing_if = "Option::is_none")]
    pub signer_address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl CiphertextResponse {
    pub fn found(
        handle: String,
        key_id: u64,
        sns_ciphertext: String,
        sns_ciphertext_digest: String,
        timestamp: u64,
        signature: String,
        signer_address: String,
    ) -> Self {
        Self {
            status: CiphertextStatus::Found,
            handle,
            key_id: Some(key_id),
            sns_ciphertext: Some(sns_ciphertext),
            sns_ciphertext_digest: Some(sns_ciphertext_digest),
            timestamp: Some(timestamp),
            signature: Some(signature),
            signer_address: Some(signer_address),
            reason: None,
        }
    }

    pub fn not_found(handle: String, reason: String) -> Self {
        Self {
            status: CiphertextStatus::NotFound,
            handle,
            key_id: None,
            sns_ciphertext: None,
            sns_ciphertext_digest: None,
            timestamp: None,
            signature: None,
            signer_address: None,
            reason: Some(reason),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CoprocessorHealthResponse {
    pub status: String,
    pub version: String,
    #[serde(rename = "signerAddress")]
    pub signer_address: String,
    pub uptime: u64,
    #[serde(rename = "lastBlockProcessed")]
    pub last_block_processed: u64,
    #[serde(rename = "storedCiphertexts")]
    pub stored_ciphertexts: u64,
    #[serde(rename = "pendingVerifications")]
    pub pending_verifications: u64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ErrorResponse {
    pub error: ErrorDetail,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ErrorDetail {
    pub code: String,
    pub message: String,
    #[serde(rename = "retryAfter", skip_serializing_if = "Option::is_none")]
    pub retry_after: Option<u64>,
}
