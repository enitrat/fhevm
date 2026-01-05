//! HTTP API server for Gateway V2 using actix-web.

use actix_web::web::Data;
use sqlx::{Pool, Postgres};
use std::net::SocketAddr;
use std::time::Instant;
use tokio::{select, task::JoinHandle};
use tokio_util::sync::CancellationToken;
use tracing::{error, info};

use super::handlers::{get_share, health};

/// Number of workers for the API server.
const API_SERVER_WORKERS: usize = 2;

/// Shared state for the API server.
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

/// Starts the Gateway V2 API server for exposing decryption shares via HTTP.
///
/// This server provides endpoints for the Relayer to poll for decryption shares
/// instead of waiting for on-chain response transactions.
pub fn start_api_server(
    endpoint: SocketAddr,
    state: ApiState,
    cancel_token: CancellationToken,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let api_server = match actix_web::HttpServer::new(move || {
            actix_web::App::new()
                .app_data(Data::new(state.clone()))
                .route("/v1/share/{request_id}", actix_web::web::get().to(get_share))
                .route("/v1/health", actix_web::web::get().to(health))
        })
        .bind(&endpoint)
        {
            Ok(server) => server,
            Err(e) => return error!("Failed to bind API server to {endpoint}: {e}"),
        };
        info!("Gateway V2 API server listening at: {endpoint}");

        select! {
            res = api_server.workers(API_SERVER_WORKERS).run() => if let Err(e) = res {
                error!("API server stopped on error: {e}");
            },
            _ = cancel_token.cancelled() => info!("API server successfully stopped")
        }
    })
}
