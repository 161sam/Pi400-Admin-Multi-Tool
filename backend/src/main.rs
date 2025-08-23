use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, net::SocketAddr, sync::Arc, time::Duration};
use tokio::{process::Command, sync::RwLock, time::timeout};
use tower_http::cors::{Any, CorsLayer};
use tracing::{error, info};

#[derive(Clone)]
struct AppState {
    allowed: Arc<RwLock<HashSet<String>>>,
}

#[derive(Deserialize)]
struct ServiceReq { name: String }

#[derive(Deserialize)]
struct NatReq { uplink: Option<String> } // eth0|wlan0

#[derive(Serialize)]
struct ApiResp<T> { ok: bool, data: Option<T>, error: Option<String> }

#[derive(Serialize)]
struct TextOut { text: String }

fn ok<T: Serialize>(data: T) -> impl IntoResponse {
    (StatusCode::OK, Json(ApiResp { ok: true, data: Some(data), error: None }))
}
fn err(status: StatusCode, msg: impl ToString) -> impl IntoResponse {
    (status, Json(ApiResp::<()> { ok: false, data: None, error: Some(msg.to_string()) }))
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("info").init();

    let allowed = [
        "pi400-hid",
        "target-ssh",
        "target-serial-tcp",
        "kiosk",
        "admin-backend",
    ]
    .into_iter()
    .map(|s| s.to_string())
    .collect::<HashSet<_>>();

    let state = AppState { allowed: Arc::new(RwLock::new(allowed)) };

    let cors = CorsLayer::new().allow_origin(Any).allow_methods(Any).allow_headers(Any);

    let app = Router::new()
        .route("/api/health", get(health))
        .route("/api/status/services", get(status_services))
        .route("/api/status/net", get(status_net))
        .route("/api/logs", get(tail_logs))
        .route("/api/target/ip", get(target_ip))
        .route("/api/nat/:action", post(nat_toggle)) // on|off
        .route("/api/usb/ensure", post(usb_ensure))
        .route("/api/svc/:action", post(service_action)) // start|stop|restart
        .with_state(state)
        .layer(cors);

    let addr: SocketAddr = "127.0.0.1:5000".parse().unwrap();
    info!("admin-backend listening on {}", addr);
    axum::Server::bind(&addr).serve(app.into_make_service()).await?;
    Ok(())
}

async fn health() -> impl IntoResponse { ok(TextOut { text: "ok".into() }) }

async fn run_cmd(args: &[&str]) -> anyhow::Result<String> {
    let (bin, rest) = args.split_first().expect("non-empty");
    let out = timeout(
        Duration::from_secs(8),
        Command::new(bin).args(rest).output(),
    )
    .await
    .map_err(|_| anyhow::anyhow!("timeout running {}", args.join(" ")))??;

    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).to_string())
    } else {
        Err(anyhow::anyhow!(String::from_utf8_lossy(&out.stderr).to_string()))
    }
}

async fn service_action(
    State(state): State<AppState>,
    Path(action): Path<String>,
    Json(req): Json<ServiceReq>,
) -> impl IntoResponse {
    let action = action.as_str();
    if !matches!(action, "start" | "stop" | "restart") {
        return err(StatusCode::BAD_REQUEST, "invalid action");
    }
    let allowed = state.allowed.read().await;
    if !allowed.contains(&req.name) {
        return err(StatusCode::FORBIDDEN, format!("service '{}' not allowed", req.name));
    }
    match run_cmd(&["/bin/systemctl", action, &req.name]).await {
        Ok(s) => ok(TextOut { text: s }),
        Err(e) => err(StatusCode::BAD_REQUEST, e.to_string()),
    }
}

async fn status_services(State(state): State<AppState>) -> impl IntoResponse {
    let names: Vec<_> = state.allowed.read().await.iter().cloned().collect();
    let mut args = vec!["/bin/systemctl", "status", "--no-pager"];
    for n in names { args.push(Box::leak(n.into_boxed_str())); }
    match run_cmd(&args).await { Ok(s) => ok(TextOut { text: s }), Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()) }
}

async fn status_net() -> impl IntoResponse {
    let joined = vec![
        vec!["/sbin/ip", "-br", "a"],
        vec!["/sbin/ip", "r"],
        vec!["/usr/bin/networkctl", "status", "usb0"],
    ];
    let mut out = String::new();
    for cmd in joined { match run_cmd(&cmd.iter().map(|s| *s).collect::<Vec<_>>()).await { Ok(s) => { out.push_str("$ "); out.push_str(&cmd.join(" ")); out.push_str("\n"); out.push_str(&s); out.push_str("\n"); }, Err(e) => { out.push_str(&format!("$ {}\n(error: {})\n\n", cmd.join(" "), e)); } } }
    ok(TextOut { text: out })
}

async fn tail_logs() -> impl IntoResponse {
    match run_cmd(&["/bin/journalctl","-u","pi400-hid","-u","target-ssh","-u","target-serial-tcp","--no-pager","-n","200"]).await {
        Ok(s) => ok(TextOut { text: s }),
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()),
    }
}

async fn target_ip() -> impl IntoResponse {
    match run_cmd(&["/usr/local/sbin/target-ip"]).await { Ok(s) => ok(TextOut { text: s }), Err(e) => err(StatusCode::BAD_REQUEST, e.to_string()) }
}

async fn nat_toggle(Path(action): Path<String>, Json(req): Json<NatReq>) -> impl IntoResponse {
    if action != "on" && action != "off" { return err(StatusCode::BAD_REQUEST, "use on|off"); }
    let uplink = req.uplink.as_deref().unwrap_or("eth0");
    match run_cmd(&["/usr/local/sbin/nat-toggle.sh", &action, uplink]).await { Ok(s) => ok(TextOut { text: s }), Err(e) => err(StatusCode::BAD_REQUEST, e.to_string()) }
}

async fn usb_ensure() -> impl IntoResponse {
    match run_cmd(&["/usr/local/sbin/pi400-composite.sh"]).await { Ok(s) => ok(TextOut { text: s }), Err(e) => err(StatusCode::BAD_REQUEST, e.to_string()) }
}
