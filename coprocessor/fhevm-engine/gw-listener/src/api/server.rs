use axum::{routing::get, routing::post, Router};
use sqlx::{Pool, Postgres};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;
use tracing::{error, info};

use super::handlers::{get_ciphertext, health, verify_input};

#[derive(Clone)]
pub struct ApiState {
    pub db_pool: Pool<Postgres>,
    pub signer_address: String,
    pub start_time: Instant,
}

impl ApiState {
    pub fn new(db_pool: Pool<Postgres>, signer_address: String) -> Self {
        Self {
            db_pool,
            signer_address,
            start_time: Instant::now(),
        }
    }
}

pub struct GatewayV2ApiServer {
    state: Arc<ApiState>,
    addr: SocketAddr,
    cancel_token: CancellationToken,
}

impl GatewayV2ApiServer {
    pub fn new(
        db_pool: Pool<Postgres>,
        signer_address: String,
        addr: SocketAddr,
        cancel_token: CancellationToken,
    ) -> Self {
        let state = Arc::new(ApiState::new(db_pool, signer_address));

        Self {
            state,
            addr,
            cancel_token,
        }
    }

    pub async fn start(self) -> anyhow::Result<()> {
        let app = Router::new()
            .route("/v1/verify-input", post(verify_input))
            .route("/v1/ciphertext/{handle}", get(get_ciphertext))
            .route("/v1/health", get(health))
            .with_state(self.state);

        info!(address = %self.addr, "Starting Gateway V2 API server");

        let cancel_token = self.cancel_token.clone();
        let shutdown = async move {
            cancel_token.cancelled().await;
        };

        let listener = TcpListener::bind(self.addr).await?;
        let server =
            axum::serve(listener, app.into_make_service()).with_graceful_shutdown(shutdown);

        if let Err(err) = server.await {
            error!(error = %err, "Gateway V2 API server error");
            return Err(anyhow::anyhow!("Gateway V2 API server error: {}", err));
        }

        Ok(())
    }
}

pub fn start_gateway_v2_api_server(
    db_pool: Pool<Postgres>,
    signer_address: String,
    addr: SocketAddr,
    cancel_token: CancellationToken,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let server = GatewayV2ApiServer::new(db_pool, signer_address, addr, cancel_token);
        if let Err(e) = server.start().await {
            error!("Gateway V2 API server failed: {}", e);
        }
    })
}
