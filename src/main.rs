use actix_web::{post, App, HttpServer, HttpResponse, Responder};
use reqwest::Client;
use serde_json::{from_str, Value};
use std::collections::HashMap;
use std::time::{Instant, Duration as TimeDuration};
use embryo::{Embryo, EmbryoList};

#[post("/query")]
async fn query_handler(body: String) -> impl Responder {
    let embryo_list = generate_embryo_list(body).await;
    let response = EmbryoList { embryo_list };
    HttpResponse::Ok().json(response)
}

async fn generate_embryo_list(json_search: String) -> Vec<Embryo> {
    let client = Client::new();

    let search: HashMap<String,String> = from_str(&json_search).expect("Can't parse JSON");
    let value = match search.get("value") {
        Some(v) => v,
        None => "",
    };
    let config_map = embryo::read_emergence_conf().unwrap_or_default();
    let ollama_url = match config_map.get("ollama").and_then(|ollama| ollama.get("url")) {
        Some(url) => url.clone(),
        None => "http://localhost:11434/v1/completions".to_string(),
    };
    let ollama_model = match config_map.get("ollama").and_then(|ollama| ollama.get("model")) {
        Some(model) => model.clone(),
        None => "phi3".to_string(),
    };


    let request_body = serde_json::json!({
        "model": ollama_model,
        "prompt": value,
        "temperature": 0.7,
        "max_tokens": 100
    });

    let response = client.post(ollama_url)
        .header("Content-Type", "application/json")
        .json(&request_body)
        .send()
        .await;

    match response {
        Ok(response) => {
            if let Ok(body) = response.text().await {
                return extract_links_from_results(body, json_search);
            }
        }
        Err(e) => eprintln!("Error fetching search results: {:?}", e),
    }

    Vec::new()
}

fn extract_links_from_results(json_data: String, json_search: String) -> Vec<Embryo> {
    let mut embryo_list = Vec::new();
    let em_search: HashMap<String, String> = from_str(&json_search).expect("Erreur lors de la désérialisation JSON");
    let timeout_secs: u64 = match em_search.get("timeout") {
        Some(t) => t.parse().expect("Can't parse as u64"),
        None => 10,
    };
    let parsed_json: Value = serde_json::from_str(&json_data).unwrap();

    if let Some(choices) = parsed_json.get("choices").and_then(|v| v.as_array()) {
        let start_time = Instant::now();
        let timeout = TimeDuration::from_secs(timeout_secs);

        for choice in choices {
            if start_time.elapsed() >= timeout {
                return embryo_list;
            }
            let text = choice["text"].as_str().unwrap_or("");
            let mut embryo_properties = HashMap::new();
            embryo_properties.insert("url".to_string(), "ollama_test".to_string());
            embryo_properties.insert("resume".to_string(), text.to_string());
            println!("{:?}", embryo_properties);
            let embryo = Embryo {
                properties: embryo_properties,
            };
            embryo_list.push(embryo);
        }
    }

    embryo_list
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    match em_filter::find_port().await {
        Some(port) => {
            let filter_url = format!("http://localhost:{}/query", port);
            println!("Filter registered: {}", filter_url);
            em_filter::register_filter(&filter_url).await;
            HttpServer::new(|| App::new().service(query_handler))
                .bind(format!("127.0.0.1:{}", port))?.run().await?;
        },
        None => {
            println!("Can't start");
        },
    }
    Ok(())
}

