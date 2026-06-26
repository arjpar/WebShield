use std::collections::HashSet;

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::resources::Resource;

const DEFAULT_CONTENT_BLOCKER_RULE_LIMIT: usize = 150_000;
const DEFAULT_RESOURCES_JSON: &str =
    include_str!("../../../vendor/adblock-rust/data/brave/brave-resources.json");
const SERIALIZED_ENGINE_PAIR_MAGIC: &[u8] = b"WSAE2\0";

#[cxx::bridge(namespace = "adblock_ffi")]
mod ffi {
    struct ContentBlockerResult {
        json: String,
        truncated: bool,
        unsupported_rules: u64,
    }

    struct NetworkRequestResult {
        matched: bool,
        important: bool,
        redirect: String,
        rewritten_url: String,
        exception: String,
        filter: String,
        csp_directives: String,
    }

    extern "Rust" {
        type Engine;

        fn new_engine(filter_set: String) -> Box<Engine>;
        fn new_engine_from_serialized(serialized: Vec<u8>) -> Box<Engine>;
        fn content_blocker_rules(filter_set: String, rule_limit: u64) -> ContentBlockerResult;
        fn default_resources_json() -> String;
        fn engine_serialize(engine: &Engine) -> Vec<u8>;
        fn engine_use_resources(engine: &mut Engine, resources_json: String);
        fn engine_cosmetic_resources(engine: &Engine, url: String, is_top_frame: bool) -> String;
        fn engine_check_network_request(
            engine: &Engine,
            url: String,
            source_url: String,
            request_type: String,
        ) -> NetworkRequestResult;
        fn engine_stylesheet_for_cosmetic_rules(
            engine: &Engine,
            classes: Vec<String>,
            ids: Vec<String>,
            exceptions_json: String,
        ) -> String;
        fn engine_selectors_for_cosmetic_rules(
            engine: &Engine,
            classes: Vec<String>,
            ids: Vec<String>,
            exceptions_json: String,
        ) -> Vec<String>;
    }
}

pub struct Engine {
    inner: adblock::Engine,
    subframe_inner: adblock::Engine,
}

fn filter_set_from_list(filter_set: &str) -> FilterSet {
    let mut set = FilterSet::new(true);
    set.add_filter_list(filter_set, ParseOptions::default());
    set
}

fn runtime_filter_set_from_list(filter_set: &str) -> FilterSet {
    let mut set = FilterSet::new(true);
    let normalized = normalize_frame_scoped_scriptlets_for_subframes(filter_set);
    set.add_filter_list(&normalized, ParseOptions::default());
    set
}

fn normalize_frame_scoped_scriptlets_for_subframes(filter_set: &str) -> String {
    let mut output = String::with_capacity(filter_set.len());
    for line in filter_set.lines() {
        if let Some(normalized) = normalize_frame_scoped_scriptlet_for_subframes(line) {
            output.push_str(&normalized);
        } else {
            output.push_str(line);
        }
        output.push('\n');
    }
    output
}

fn normalize_frame_scoped_scriptlet_for_subframes(line: &str) -> Option<String> {
    let marker = "##+js(";
    let marker_index = line.find(marker)?;
    if !line.ends_with(')') {
        return None;
    }
    let locations = &line[..marker_index];
    if !locations.contains(">>") {
        return None;
    }

    let mut stripped_locations = Vec::new();
    for location in locations.split(',') {
        let stripped = location.strip_suffix(">>")?;
        if stripped.is_empty() {
            return None;
        }
        stripped_locations.push(stripped);
    }

    let args_start = marker_index + marker.len();
    let args = &line[args_start..line.len() - 1];
    Some(format!(
        "{}{}{})",
        stripped_locations.join(","),
        marker,
        args
    ))
}

fn engine_from_filter_set(filter_set: FilterSet) -> adblock::Engine {
    adblock::Engine::from_filter_set(filter_set, true)
}

fn engine_from_serialized_bytes(serialized: &[u8]) -> adblock::Engine {
    let mut inner = adblock::Engine::default();
    let _ = inner.deserialize(&serialized.to_vec());
    inner
}

fn push_len_prefixed_bytes(output: &mut Vec<u8>, bytes: &[u8]) {
    output.extend_from_slice(&(bytes.len() as u64).to_le_bytes());
    output.extend_from_slice(bytes);
}

fn read_len_prefixed_slice<'a>(input: &'a [u8], cursor: &mut usize) -> Option<&'a [u8]> {
    let len_end = cursor.checked_add(8)?;
    let len_bytes: [u8; 8] = input.get(*cursor..len_end)?.try_into().ok()?;
    let len = u64::from_le_bytes(len_bytes) as usize;
    *cursor = len_end;
    let data_end = cursor.checked_add(len)?;
    let data = input.get(*cursor..data_end)?;
    *cursor = data_end;
    Some(data)
}

fn split_serialized_engine_pair(serialized: &[u8]) -> Option<(&[u8], &[u8])> {
    if !serialized.starts_with(SERIALIZED_ENGINE_PAIR_MAGIC) {
        return None;
    }

    let mut cursor = SERIALIZED_ENGINE_PAIR_MAGIC.len();
    let top = read_len_prefixed_slice(serialized, &mut cursor)?;
    let subframe = read_len_prefixed_slice(serialized, &mut cursor)?;
    if cursor != serialized.len() {
        return None;
    }
    Some((top, subframe))
}

fn new_engine(filter_set: String) -> Box<Engine> {
    Box::new(Engine {
        inner: engine_from_filter_set(filter_set_from_list(&filter_set)),
        subframe_inner: engine_from_filter_set(runtime_filter_set_from_list(&filter_set)),
    })
}

fn new_engine_from_serialized(serialized: Vec<u8>) -> Box<Engine> {
    if let Some((top, subframe)) = split_serialized_engine_pair(&serialized) {
        return Box::new(Engine {
            inner: engine_from_serialized_bytes(top),
            subframe_inner: engine_from_serialized_bytes(subframe),
        });
    }

    let inner = engine_from_serialized_bytes(&serialized);
    let subframe_inner = engine_from_serialized_bytes(&serialized);
    Box::new(Engine {
        inner,
        subframe_inner,
    })
}

fn content_blocker_rules(filter_set: String, rule_limit: u64) -> ffi::ContentBlockerResult {
    let (mut rules, stats) =
        match filter_set_from_list(&filter_set).into_content_blocking_with_stats() {
            Ok((rules, _filters_used, stats)) => (rules, stats),
            Err(()) => {
                return ffi::ContentBlockerResult {
                    json: "[]".to_string(),
                    truncated: false,
                    unsupported_rules: 0,
                };
            }
        };

    let requested_limit = usize::try_from(rule_limit)
        .ok()
        .filter(|limit| *limit > 0)
        .unwrap_or(DEFAULT_CONTENT_BLOCKER_RULE_LIMIT);
    let truncated = rules.len() > requested_limit;
    if truncated {
        rules.truncate(requested_limit);
    }

    ffi::ContentBlockerResult {
        json: serde_json::to_string(&rules).unwrap_or_else(|_| "[]".to_string()),
        truncated,
        unsupported_rules: stats.unsupported_rule_count as u64,
    }
}

fn default_resources_json() -> String {
    DEFAULT_RESOURCES_JSON.to_string()
}

fn engine_serialize(engine: &Engine) -> Vec<u8> {
    let top = engine.inner.serialize();
    let subframe = engine.subframe_inner.serialize();
    let mut output =
        Vec::with_capacity(SERIALIZED_ENGINE_PAIR_MAGIC.len() + 16 + top.len() + subframe.len());
    output.extend_from_slice(SERIALIZED_ENGINE_PAIR_MAGIC);
    push_len_prefixed_bytes(&mut output, &top);
    push_len_prefixed_bytes(&mut output, &subframe);
    output
}

fn engine_use_resources(engine: &mut Engine, resources_json: String) {
    if let Ok(resources) = serde_json::from_str::<Vec<Resource>>(&resources_json) {
        engine.inner.use_resources(resources.clone());
        engine.subframe_inner.use_resources(resources);
        return;
    }

    if let Ok(resource) = serde_json::from_str::<Resource>(&resources_json) {
        engine.inner.use_resources([resource.clone()]);
        engine.subframe_inner.use_resources([resource]);
    }
}

fn engine_cosmetic_resources(engine: &Engine, url: String, is_top_frame: bool) -> String {
    let inner = if is_top_frame {
        &engine.inner
    } else {
        &engine.subframe_inner
    };
    serde_json::to_string(&inner.url_cosmetic_resources(&url)).unwrap_or_else(|_| "{}".to_string())
}

fn empty_network_request_result() -> ffi::NetworkRequestResult {
    ffi::NetworkRequestResult {
        matched: false,
        important: false,
        redirect: String::new(),
        rewritten_url: String::new(),
        exception: String::new(),
        filter: String::new(),
        csp_directives: String::new(),
    }
}

fn engine_check_network_request(
    engine: &Engine,
    url: String,
    source_url: String,
    request_type: String,
) -> ffi::NetworkRequestResult {
    let request = match Request::new(&url, &source_url, &request_type) {
        Ok(request) => request,
        Err(_) => return empty_network_request_result(),
    };

    let result = engine.inner.check_network_request(&request);
    let csp_directives = engine
        .inner
        .get_csp_directives(&request)
        .unwrap_or_default();

    ffi::NetworkRequestResult {
        matched: result.matched,
        important: result.important,
        redirect: result.redirect.unwrap_or_default(),
        rewritten_url: result.rewritten_url.unwrap_or_default(),
        exception: result.exception.unwrap_or_default(),
        filter: result.filter.unwrap_or_default(),
        csp_directives,
    }
}

fn parse_exceptions(json: &str) -> HashSet<String> {
    if let Ok(exceptions) = serde_json::from_str::<HashSet<String>>(json) {
        return exceptions;
    }

    serde_json::from_str::<serde_json::Value>(json)
        .ok()
        .and_then(|value| value.get("exceptions").cloned())
        .and_then(|value| serde_json::from_value::<HashSet<String>>(value).ok())
        .unwrap_or_default()
}

fn engine_stylesheet_for_cosmetic_rules(
    engine: &Engine,
    classes: Vec<String>,
    ids: Vec<String>,
    exceptions_json: String,
) -> String {
    engine_selectors_for_cosmetic_rules(engine, classes, ids, exceptions_json)
        .into_iter()
        .map(|selector| format!("{selector} {{ display: none !important; }}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn engine_selectors_for_cosmetic_rules(
    engine: &Engine,
    classes: Vec<String>,
    ids: Vec<String>,
    exceptions_json: String,
) -> Vec<String> {
    let exceptions = parse_exceptions(&exceptions_json);
    engine
        .inner
        .hidden_class_id_selectors(classes, ids, &exceptions)
        .into_iter()
        .collect()
}
