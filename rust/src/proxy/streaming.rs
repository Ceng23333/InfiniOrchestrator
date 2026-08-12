//! Streaming support for SSE and chunked responses

use axum::{
    body::Body,
    http::{HeaderName, HeaderValue, StatusCode},
    response::Response,
};
use futures::Stream;
use reqwest::Response as ReqwestResponse;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use tracing::info;

use crate::metrics::{
    now_secs, parse_usage_tokens, sse_chunk_has_token, GatewayMetrics, RequestMetricsHandle,
};

/// Handle streaming response from upstream service, recording gateway metrics.
pub async fn handle_streaming_response(
    upstream_response: ReqwestResponse,
    status: StatusCode,
    response_headers: Vec<(String, String)>,
    method: &str,
    path: &str,
    service_name: &str,
    metrics: Arc<GatewayMetrics>,
    req_metrics: RequestMetricsHandle,
) -> Response {
    let mut response_builder = Response::builder().status(status);

    for (name_str, value_str) in response_headers {
        if let Ok(header_name) = HeaderName::from_bytes(name_str.as_bytes()) {
            if let Ok(header_value) = HeaderValue::from_str(&value_str) {
                response_builder = response_builder.header(header_name, header_value);
            }
        }
    }

    let upstream = upstream_response.bytes_stream();
    let status_label = if status.is_success() { "ok" } else { "error" }.to_string();
    let metered = MeteredByteStream {
        inner: Box::pin(upstream),
        metrics,
        handle: req_metrics,
        status_label,
        prompt_tokens: 0,
        completion_tokens: 0,
        finished: false,
    };

    let body = Body::from_stream(metered);

    let response = match response_builder.body(body) {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("Failed to build streaming response: {}", e);
            return Response::builder()
                .status(StatusCode::INTERNAL_SERVER_ERROR)
                .body(Body::from("Internal server error"))
                .unwrap();
        }
    };

    info!(
        "Proxied (stream) {} {} -> {} ({})",
        method, path, service_name, status
    );
    response
}

struct MeteredByteStream<S> {
    inner: Pin<Box<S>>,
    metrics: Arc<GatewayMetrics>,
    handle: RequestMetricsHandle,
    status_label: String,
    prompt_tokens: u64,
    completion_tokens: u64,
    finished: bool,
}

impl<S> MeteredByteStream<S> {
    fn finalize(&mut self) {
        if self.finished {
            return;
        }
        self.finished = true;
        self.metrics.record_request_finish(
            &self.status_label,
            &self.handle.server_id,
            self.handle.arrival_secs,
            now_secs(),
            self.handle.first_token_secs,
            self.prompt_tokens,
            self.completion_tokens,
        );
    }
}

impl<S> Drop for MeteredByteStream<S> {
    fn drop(&mut self) {
        self.finalize();
    }
}

impl<S, E> Stream for MeteredByteStream<S>
where
    S: Stream<Item = Result<bytes::Bytes, E>>,
    E: std::fmt::Display,
{
    type Item = Result<axum::body::Bytes, std::io::Error>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();
        match this.inner.as_mut().poll_next(cx) {
            Poll::Ready(Some(Ok(bytes))) => {
                if sse_chunk_has_token(&bytes) {
                    this.handle.on_token(&this.metrics);
                }
                let text = String::from_utf8_lossy(&bytes);
                if text.contains("\"usage\"") {
                    let (p, c) = parse_usage_tokens(&text);
                    if p > 0 {
                        this.prompt_tokens = p;
                    }
                    if c > 0 {
                        this.completion_tokens = c;
                    }
                }
                Poll::Ready(Some(Ok(axum::body::Bytes::from(bytes.to_vec()))))
            }
            Poll::Ready(Some(Err(e))) => {
                this.status_label = "error".to_string();
                this.finalize();
                Poll::Ready(Some(Err(std::io::Error::other(format!("Stream error: {e}")))))
            }
            Poll::Ready(None) => {
                this.finalize();
                Poll::Ready(None)
            }
            Poll::Pending => Poll::Pending,
        }
    }
}
