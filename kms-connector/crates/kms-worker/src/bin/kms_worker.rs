use kms_worker::{
    api::{start_api_server, ApiState},
    core::{Config, KmsWorker},
    monitoring::health::HealthStatus,
};

use connector_utils::{
    cli::{Cli, Subcommands},
    config::DeserializeConfig,
    monitoring::{
        health::query_healthcheck_endpoint, otlp::init_otlp_setup, server::start_monitoring_server,
    },
    signal::install_signal_handlers,
    tasks::set_task_limit,
};
use std::process::ExitCode;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info};

#[tokio::main]
async fn main() -> ExitCode {
    if let Err(err) = run().await {
        error!("{err}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

async fn run() -> anyhow::Result<()> {
    let subcommand = Cli::new("KmsWorker").parse();
    match subcommand {
        Subcommands::Validate { config } => {
            Config::from_env_and_file(Some(config))?;
        }
        Subcommands::Health { endpoint } => {
            query_healthcheck_endpoint::<HealthStatus>(endpoint).await?;
        }
        Subcommands::Start { config } => {
            let config = Config::from_env_and_file(config.as_ref())?;
            debug!("{config:?}");
            init_otlp_setup(config.service_name.clone())?;

            let cancel_token = CancellationToken::new();
            set_task_limit(config.task_limit);
            install_signal_handlers(cancel_token.clone())?;
            let monitoring_endpoint = config.monitoring_endpoint;
            let api_endpoint = config.api_endpoint;
            let signer_address = config.signer_address.clone().unwrap_or_default();

            info!("Starting KmsWorker");
            let (kms_worker, state) = KmsWorker::from_config(config).await?;
            start_monitoring_server(monitoring_endpoint, state.clone(), cancel_token.clone());

            let api_state = ApiState::new(state.db_pool().clone(), signer_address);
            start_api_server(api_endpoint, api_state, cancel_token.clone());

            kms_worker.start(cancel_token).await;
        }
    }
    Ok(())
}
