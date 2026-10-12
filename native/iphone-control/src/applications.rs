use std::{collections::HashMap, time::Duration};

use idevice::services::installation_proxy::InstallationProxyClient;
use plist::{Dictionary, Value};
use serde::Serialize;

use crate::{Failure, Status};

pub(super) const QUERY_TIMEOUT: Duration = Duration::from_secs(30);

// Only these fields are requested from installation_proxy. Container paths,
// entitlements, URL schemes and arbitrary app configuration are not requested.
const RETURN_ATTRIBUTES: &[&str] = &[
    "CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "ApplicationType",
    "SBAppTags", "LSBackgroundOnly", "LSUIElement", "NSExtension",
];

#[derive(Clone, Debug, PartialEq, Serialize)]
pub(super) struct InstalledApp {
    #[serde(rename = "bundleID")]
    bundle_id: String,
    name: String,
    #[serde(rename = "isSystem", skip_serializing_if = "Option::is_none")]
    is_system: Option<bool>,
}

#[derive(Clone, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub(super) enum CatalogResult {
    Pending,
    Ready { apps: Vec<InstalledApp> },
    Failed { error: Status },
}

impl CatalogResult {
    pub(super) fn from_result(result: &Result<Vec<InstalledApp>, Failure>) -> Self {
        match result {
            Ok(apps) => Self::Ready { apps: apps.clone() },
            Err(error) => Self::Failed { error: Status {
                phase: "failed", code: error.code, message: error.message,
                native: error.native.clone(), pair_verify_error: None,
            } },
        }
    }
}

pub(super) async fn query(client: &mut InstallationProxyClient) -> Result<Vec<InstalledApp>, Failure> {
    tokio::time::timeout(QUERY_TIMEOUT, lookup(client)).await
        .map_err(|_| Failure::new("applications_timeout", "30 秒内未收到本机应用列表。"))?
}

async fn lookup(client: &mut InstallationProxyClient) -> Result<Vec<InstalledApp>, Failure> {
    let entries = client.get_apps_with_attributes(
        Some("Any"), None,
        Some(RETURN_ATTRIBUTES.iter().map(|attribute| (*attribute).into()).collect()),
    ).await
        .map_err(|error| Failure::device("applications_query_failed", "无法读取本机应用列表。", error))?;
    normalize(entries)
}

fn normalize(entries: HashMap<String, Value>) -> Result<Vec<InstalledApp>, Failure> {
    let mut apps = Vec::with_capacity(entries.len());
    for (bundle_id, value) in entries {
        let metadata = value.as_dictionary().ok_or_else(|| {
            Failure::new("invalid_applications", "本机应用列表包含无效的应用信息。")
        })?;
        if bundle_id.is_empty() || bundle_id.len() > 255
            || !bundle_id.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
            || nonempty_string(metadata, "CFBundleIdentifier").is_some_and(|value| value != bundle_id)
        {
            return Err(Failure::new("invalid_applications", "本机应用列表包含无效的 Bundle ID。"));
        }
        // Do not infer launchability from bundle prefixes, background modes,
        // or missing metadata. Only explicit hidden/helper/extension markers
        // exclude an entry from the user-facing catalog.
        let hidden = metadata.get("SBAppTags").and_then(Value::as_array)
            .is_some_and(|tags| tags.iter().any(|tag| tag.as_string() == Some("hidden")));
        let background_only = metadata.get("LSBackgroundOnly").and_then(Value::as_boolean) == Some(true);
        let ui_element = metadata.get("LSUIElement").and_then(Value::as_boolean) == Some(true);
        let extension = metadata.get("NSExtension").and_then(Value::as_dictionary).is_some();
        if hidden || background_only || ui_element || extension { continue; }

        let name = nonempty_string(metadata, "CFBundleDisplayName")
            .or_else(|| nonempty_string(metadata, "CFBundleName"))
            .unwrap_or(&bundle_id).to_owned();
        let is_system = match metadata.get("ApplicationType").and_then(Value::as_string) {
            Some("System") => Some(true),
            Some("User") => Some(false),
            _ => None,
        };
        apps.push(InstalledApp { bundle_id, name, is_system });
    }
    apps.sort_by(|left, right| left.name.cmp(&right.name).then(left.bundle_id.cmp(&right.bundle_id)));
    Ok(apps)
}

fn nonempty_string<'a>(metadata: &'a Dictionary, key: &str) -> Option<&'a str> {
    metadata.get(key).and_then(Value::as_string).map(str::trim).filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use idevice::Idevice;
    use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};

    macro_rules! plist {
        ($($json:tt)*) => { plist::to_value(&serde_json::json!($($json)*)).unwrap() };
    }

    async fn fixture_request(server: &mut DuplexStream) -> Dictionary {
        let length = server.read_u32().await.unwrap();
        let mut payload = vec![0; length as usize];
        server.read_exact(&mut payload).await.unwrap();
        Value::from_reader(std::io::Cursor::new(payload)).unwrap().into_dictionary().unwrap()
    }

    async fn fixture_reply(server: &mut DuplexStream, response: Value) {
        let mut payload = Vec::new();
        response.to_writer_xml(&mut payload).unwrap();
        server.write_u32(payload.len() as u32).await.unwrap();
        server.write_all(&payload).await.unwrap();
    }

    #[tokio::test]
    async fn lookup_requests_only_catalog_attributes_and_never_launches() {
        let (client, server) = tokio::io::duplex(16_384);
        let mut client = InstallationProxyClient::new(Idevice::new(Box::new(client), "test"));
        let server = tokio::spawn(async move {
            let mut server = server;
            let request = fixture_request(&mut server).await;
            assert_eq!(request["Command"].as_string(), Some("Lookup"));
            let options = request["ClientOptions"].as_dictionary().unwrap();
            assert_eq!(options["ApplicationType"].as_string(), Some("Any"));
            assert!(!options.contains_key("BundleIDs"));
            let attributes = options["ReturnAttributes"].as_array().unwrap();
            assert_eq!(attributes, &RETURN_ATTRIBUTES.iter().map(|key| Value::String((*key).into())).collect::<Vec<_>>());
            fixture_reply(&mut server, plist!({"LookupResult": {
                "app.test": {"CFBundleDisplayName": "Test App", "ApplicationType": "User", "Path": "private-path"}
            }})).await;
            let mut extra = [0u8; 1];
            assert_eq!(server.read(&mut extra).await.unwrap(), 0, "catalog must not send an activation request");
        });
        let apps = query(&mut client).await.unwrap_or_else(|_| panic!("fixture lookup should succeed"));
        assert_eq!(apps, vec![InstalledApp { bundle_id: "app.test".into(), name: "Test App".into(), is_system: Some(false) }]);
        assert!(!serde_json::to_string(&apps).unwrap().contains("private-path"));
        drop(client);
        server.await.unwrap();
    }

    #[test]
    fn catalog_uses_names_and_explicit_markers_without_guessing_prefixes() {
        let entries = plist!({
            "com.apple.visible": {"CFBundleDisplayName": "Visible", "ApplicationType": "System"},
            "app.audio": {"CFBundleDisplayName": "  ", "CFBundleName": "Audio", "UIBackgroundModes": ["audio"]},
            "app.unnamed": {},
            "app.hidden": {"SBAppTags": ["hidden"]},
            "app.background": {"LSBackgroundOnly": true},
            "app.helper": {"LSUIElement": true},
            "app.extension": {"NSExtension": {"NSExtensionPointIdentifier": "test"}},
        });
        let apps = normalize(entries.into_dictionary().unwrap().into_iter().collect())
            .unwrap_or_else(|_| panic!("valid metadata"));
        assert_eq!(apps.len(), 3);
        assert_eq!(apps[0].name, "Audio");
        assert_eq!(apps[0].is_system, None);
        assert_eq!(apps[1].bundle_id, "com.apple.visible");
        assert_eq!(apps[1].is_system, Some(true));
        assert_eq!(apps[2].name, "app.unnamed");
    }

    #[tokio::test]
    async fn rejected_or_malformed_lookup_is_not_a_successful_empty_list() {
        for response in [
            plist!({"Error": "private-service-message", "LookupResult": {}}),
            plist!({"Status": "Complete"}),
            plist!({"LookupResult": {"app.test": "not-a-dictionary"}}),
            plist!({"LookupResult": {"app.test": {"CFBundleIdentifier": "other.app"}}}),
        ] {
            let (client, server) = tokio::io::duplex(16_384);
            let mut client = InstallationProxyClient::new(Idevice::new(Box::new(client), "test"));
            let server = tokio::spawn(async move {
                let mut server = server;
                fixture_request(&mut server).await;
                fixture_reply(&mut server, response).await;
            });
            let result = query(&mut client).await;
            assert!(result.is_err());
            assert!(!serde_json::to_string(&CatalogResult::from_result(&result)).unwrap().contains("private-service-message"));
            server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn legacy_lookup_keeps_full_attributes_and_requested_bundle_ids() {
        let (client, mut server) = tokio::io::duplex(16_384);
        let mut client = InstallationProxyClient::new(Idevice::new(Box::new(client), "test"));
        let server = tokio::spawn(async move {
            let request = fixture_request(&mut server).await;
            let options = request["ClientOptions"].as_dictionary().unwrap();
            assert_eq!(options["ApplicationType"].as_string(), Some("Any"));
            assert_eq!(options["BundleIDs"].as_array().unwrap(), &vec![Value::String("app.runner".into())]);
            assert!(!options.contains_key("ReturnAttributes"));
            fixture_reply(&mut server, plist!({"LookupResult": {"app.runner": {"Path": "/Applications/Runner.app"}}})).await;
        });
        let result = client.get_apps(None, Some(vec!["app.runner".into()])).await.unwrap();
        assert_eq!(result["app.runner"].as_dictionary().unwrap()["Path"].as_string(), Some("/Applications/Runner.app"));
        server.await.unwrap();
    }

    #[tokio::test]
    async fn catalog_failure_does_not_fail_the_control_session_or_look_successfully_empty() {
        use std::sync::Mutex;
        let session = crate::Session {
            status: Mutex::new(Status::new("discovering", "discovering", "")),
            started: tokio::sync::Notify::new(), pairing_result: Mutex::new(None),
            applications: Mutex::new(CatalogResult::Pending),
        };
        let (client, mut server) = tokio::io::duplex(16_384);
        let mut client = InstallationProxyClient::new(Idevice::new(Box::new(client), "test"));
        let server = tokio::spawn(async move {
            fixture_request(&mut server).await;
            fixture_reply(&mut server, plist!({"Error": "private-catalog-failure"})).await;
        });
        assert!(crate::cache_applications(&session, &mut client).await.is_err());
        assert_eq!(session.status.lock().unwrap().phase, "discovering");
        session.stage("starting", "");
        assert_eq!(session.status.lock().unwrap().phase, "starting");
        let catalog = serde_json::to_value(&*session.applications.lock().unwrap()).unwrap();
        assert_eq!(catalog["state"], "failed");
        assert_eq!(catalog["error"]["code"], "applications_query_failed");
        assert!(catalog.get("apps").is_none());
        assert!(!catalog.to_string().contains("private-catalog-failure"));
        server.await.unwrap();
    }
}
