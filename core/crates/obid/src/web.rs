//! The web app (`apps/web`) as obid serves it: its built files on obid's own loopback address
//! (docs/runner-api.md, "obid only: the web app").
//!
//! The API takes nothing but the token: the page sends `Authorization: Bearer <token>` on every
//! call, the event stream included, from the browser's session storage, which is the page's own
//! (another port on 127.0.0.1 is another origin and can't read it). No cookie reaches `/v1`.
//!
//! The page's own files hold no data, but #492 keeps them behind the token too, and a browser
//! can't send a header when it opens a page. So `GET /app/…` without the token answers `401` with
//! a small sign-in form; the token pasted there goes to `POST /app/sign-in`, which opens a session
//! for the page's files: a random value in a cookie (`Path=/app`), whose SHA-256 obid keeps in
//! memory until the browser signs out or obid stops. The form's own script keeps the token in the
//! page's session storage on the way, so the page has it for the API.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};

use axum::extract::rejection::FormRejection;
use axum::extract::{Form, Path as UrlPath, State};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, Uri, header};
use axum::response::{IntoResponse, Response};
use base64::Engine as _;

use crate::api::{ApiError, Shared};

/// The page's session cookie.
pub const COOKIE: &str = "obid-page";
/// Where the sign-in form goes, and where the page signs out. The gate lets both through without
/// the token: the one checks the token it is sent, the other only ends a session.
pub const SIGN_IN: &str = "/app/sign-in";
pub const SIGN_OUT: &str = "/app/sign-out";
/// The most sessions obid keeps: signing in once more ends the oldest.
const MOST: usize = 64;

/// The browsers signed in to the page's files: the SHA-256 of each session cookie's value, oldest
/// first. In memory only, so obid stopping ends them all (the page then signs in again by itself,
/// from the token it keeps). A session opens nothing but `GET` of the page's files.
#[derive(Default)]
pub struct Sessions(Mutex<VecDeque<[u8; 32]>>);

impl Sessions {
    /// A new session: its cookie value, 32 random bytes in hex.
    pub fn open(&self) -> Option<String> {
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes).ok()?;
        let value = hex::encode(bytes);
        let mut held = self.0.lock().unwrap_or_else(|e| e.into_inner());
        held.push_back(obi_protocol::keys::sha256(&value));
        while held.len() > MOST {
            held.pop_front();
        }
        Some(value)
    }

    /// Whether `value` is an open session's.
    pub fn holds(&self, value: &str) -> bool {
        let digest = obi_protocol::keys::sha256(value);
        let held = self.0.lock().unwrap_or_else(|e| e.into_inner());
        held.iter().any(|d| same_bytes(d, &digest))
    }

    /// Ends the session `value` is, if any.
    pub fn close(&self, value: &str) {
        let digest = obi_protocol::keys::sha256(value);
        let mut held = self.0.lock().unwrap_or_else(|e| e.into_inner());
        held.retain(|d| !same_bytes(d, &digest));
    }
}

fn same_bytes(a: &[u8; 32], b: &[u8; 32]) -> bool {
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Whether `path` is the web app's: `/app` and everything under `/app/`.
pub fn is_app(path: &str) -> bool {
    path == "/app" || path.starts_with("/app/")
}

/// Whether the gate lets a request through on a loopback `Host` alone: the sign-in form being
/// sent, and signing out.
pub fn is_open(method: &Method, uri: &Uri) -> bool {
    method == Method::POST && (uri.path() == SIGN_IN || uri.path() == SIGN_OUT)
}

/// Whether a request without the token is admitted by a page session: only to read the page's
/// own files (`GET` or `HEAD` under `/app`), never anything else, `/v1` included.
pub fn admitted(method: &Method, uri: &Uri, headers: &HeaderMap, sessions: &Sessions) -> bool {
    (method == Method::GET || method == Method::HEAD)
        && is_app(uri.path())
        && cookies(headers, COOKIE)
            .iter()
            .any(|value| sessions.holds(value))
}

/// The one value of a header, or none when it's missing, repeated or not text.
fn single<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    let mut values = headers.get_all(name).iter();
    match (values.next(), values.next()) {
        (Some(value), None) => value.to_str().ok(),
        _ => None,
    }
}

/// Every value the request's `Cookie` headers give `name`.
fn cookies<'a>(headers: &'a HeaderMap, name: &str) -> Vec<&'a str> {
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|line| line.split(';'))
        .filter_map(|pair| pair.trim().split_once('='))
        .filter(|(key, _)| *key == name)
        .map(|(_, value)| value.trim_matches('"'))
        .collect()
}

/// `GET /app`: the page is at `/app/`, so its relative links resolve.
pub async fn bare() -> Response {
    (
        StatusCode::PERMANENT_REDIRECT,
        [(header::LOCATION, "/app/")],
    )
        .into_response()
}

/// `GET /app/`: the web app's page.
pub async fn index(State(shared): State<Arc<Shared>>) -> Response {
    serve(&shared.config.web, "index.html").await
}

/// `GET /app/{*path}`: one of its files.
pub async fn file(State(shared): State<Arc<Shared>>, UrlPath(path): UrlPath<String>) -> Response {
    serve(&shared.config.web, &path).await
}

#[derive(serde::Deserialize)]
pub struct SignIn {
    token: String,
}

/// `POST /app/sign-in` (a form: `token=…`): the right token opens a page session and goes back
/// to the page; anything else is the sign-in form again, `401`, with no session.
pub async fn sign_in(
    State(shared): State<Arc<Shared>>,
    headers: HeaderMap,
    form: Result<Form<SignIn>, FormRejection>,
) -> Response {
    // Sent from another site's page: not this one's form.
    if single(&headers, "sec-fetch-site").is_some_and(|site| site != "same-origin") {
        return sign_in_page(Some("Sign in from this page."));
    }
    let given = form.map(|Form(f)| f.token).unwrap_or_default();
    if !crate::token::same(given.trim(), &shared.token) {
        return sign_in_page(Some("That isn't this obid's token."));
    }
    let Some(value) = shared.pages.open() else {
        return ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "The system has no randomness to open a session with.",
        )
        .into_response();
    };
    see_the_page(&format!(
        "{COOKIE}={value}; Path=/app; HttpOnly; SameSite=Strict"
    ))
}

/// `POST /app/sign-out`: the session this browser holds ends, its cookie goes, and the page is
/// the sign-in form again.
pub async fn sign_out(State(shared): State<Arc<Shared>>, headers: HeaderMap) -> Response {
    for value in cookies(&headers, COOKIE) {
        shared.pages.close(value);
    }
    see_the_page(&format!(
        "{COOKIE}=; Path=/app; Max-Age=0; HttpOnly; SameSite=Strict"
    ))
}

/// `303` to the page, setting `cookie`.
fn see_the_page(cookie: &str) -> Response {
    let mut response = (StatusCode::SEE_OTHER, [(header::LOCATION, "/app/")]).into_response();
    if let Ok(value) = HeaderValue::from_str(cookie) {
        response.headers_mut().insert(header::SET_COOKIE, value);
    }
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

/// The sign-in form, as the `401` a browser gets for the page without the token. It shows nothing
/// of obid's: no job, no path, no token.
pub fn sign_in_page(problem: Option<&str>) -> Response {
    let problem = problem
        .map(|p| format!("<p class=\"problem\" role=\"alert\">{}</p>", escape(p)))
        .unwrap_or_default();
    let page = SIGN_IN_PAGE
        .replace("{problem}", &problem)
        .replace("{script}", SIGN_IN_SCRIPT);
    let mut response = (StatusCode::UNAUTHORIZED, page).into_response();
    let headers = response.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/html; charset=utf-8"),
    );
    if let Ok(policy) = HeaderValue::from_str(&SIGN_IN_POLICY) {
        headers.insert(header::CONTENT_SECURITY_POLICY, policy);
    }
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    response
}

/// The sign-in form's policy: its one script, by its hash, and nothing else.
static SIGN_IN_POLICY: LazyLock<String> = LazyLock::new(|| {
    let hash = base64::engine::general_purpose::STANDARD
        .encode(obi_protocol::keys::sha256(SIGN_IN_SCRIPT));
    format!(
        "default-src 'none'; script-src 'sha256-{hash}'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
    )
});

/// The sign-in form's script: it keeps the token in the page's session storage as the form goes,
/// so the page has it for the API. When obid answers the form again with a problem, it forgets
/// it; when it comes back to the form holding one (obid restarted and its sessions ended), it
/// sends it once by itself.
const SIGN_IN_SCRIPT: &str = "
const form = document.querySelector('form'), input = form.querySelector('input');
const KEY = 'oby.token', SENT = 'oby.signInSent';
if (document.querySelector('.problem')) sessionStorage.removeItem(KEY);
else {
  const kept = sessionStorage.getItem(KEY), sent = Number(sessionStorage.getItem(SENT) || 0);
  if (kept && Date.now() - sent > 10000) { sessionStorage.setItem(SENT, String(Date.now())); input.value = kept; form.submit(); }
}
form.addEventListener('submit', () => sessionStorage.setItem(KEY, input.value.trim()));
";

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

const SIGN_IN_PAGE: &str = r#"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Oby</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #0d0d0e; color: #f1f1ee;
         font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
  main { width: min(380px, calc(100vw - 32px)); }
  h1 { font-size: 22px; font-weight: 600; margin: 0 0 8px; }
  p { color: #a6a6a1; margin: 0 0 20px; }
  code { color: #f1f1ee; }
  form { display: flex; gap: 8px; }
  input { flex: 1; min-width: 0; padding: 9px 12px; border-radius: 10px; border: 1px solid #2c2c2f; background: #18181a;
          color: inherit; font: inherit; }
  button { padding: 9px 16px; border: 0; border-radius: 10px; background: #f1f1ee; color: #0d0d0e; font: inherit; font-weight: 600; }
  .problem { color: #ff8a73; margin: 12px 0 0; }
</style>
</head>
<body>
<main>
<h1>Sign in to Oby</h1>
<p>This Oby answers only with its API token. Paste the token from the <code>api-token</code> file in obid's home.</p>
<form method="post" action="/app/sign-in">
<input type="password" name="token" aria-label="API token" autocomplete="off" spellcheck="false" autofocus required>
<button type="submit">Sign in</button>
</form>
{problem}
</main>
<script>{script}</script>
</body>
</html>
"#;

/// A file of the built web app under `root`, or `404`. Only plain names inside `root`: no `..`,
/// no hidden files, nothing a link leads out of `root` to.
async fn serve(root: &Path, relative: &str) -> Response {
    if !root.join("index.html").is_file() {
        return ApiError::new(
            StatusCode::NOT_FOUND,
            "The web app isn't built: run npm ci and npm run build in apps/web, or set web in obid's configuration.",
        )
        .into_response();
    }
    let Some(path) = inside(root, relative) else {
        return no_file();
    };
    let bytes = match tokio::fs::read(&path).await {
        Ok(bytes) => bytes,
        Err(_) => return no_file(),
    };
    let mut response = (StatusCode::OK, bytes).into_response();
    let headers = response.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(type_of(&path)),
    );
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    if type_of(&path).starts_with("text/html") {
        // The mascot's page (character/oby.html, copied in as oby/) runs its own inline scripts;
        // the app's pages run only their bundled files.
        let policy = if relative.starts_with("oby/") {
            "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'; object-src 'none'"
        } else {
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; frame-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'self'; object-src 'none'"
        };
        headers.insert(
            header::CONTENT_SECURITY_POLICY,
            HeaderValue::from_static(policy),
        );
    }
    response
}

fn no_file() -> Response {
    ApiError::new(StatusCode::NOT_FOUND, "There's no such file.").into_response()
}

/// `relative` under `root`, when it names a file there by plain names only.
fn inside(root: &Path, relative: &str) -> Option<PathBuf> {
    let plain = |part: &str| {
        !part.is_empty() && !part.starts_with('.') && !part.contains(['\\', '\0', ':'])
    };
    if !relative.split('/').all(plain) {
        return None;
    }
    let root = root.canonicalize().ok()?;
    let path = root.join(relative).canonicalize().ok()?;
    (path.starts_with(&root) && path.is_file()).then_some(path)
}

/// The media type for a file, by its extension.
fn type_of(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" | "map" => "application/json",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "ico" => "image/x-icon",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "txt" => "text/plain; charset=utf-8",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn headers(pairs: &[(&'static str, &str)]) -> HeaderMap {
        let mut map = HeaderMap::new();
        for (name, value) in pairs {
            map.append(*name, HeaderValue::from_str(value).unwrap());
        }
        map
    }

    #[test]
    fn sessions_are_random_and_end() {
        let sessions = Sessions::default();
        let one = sessions.open().unwrap();
        let two = sessions.open().unwrap();
        assert_eq!(one.len(), 64);
        assert_ne!(one, two);
        assert!(sessions.holds(&one) && sessions.holds(&two));
        assert!(!sessions.holds(&TOKEN.replace('0', "1")));
        sessions.close(&one);
        assert!(!sessions.holds(&one));
        assert!(sessions.holds(&two));
        // Signing in once more than it keeps ends the oldest.
        let first = sessions.open().unwrap();
        for _ in 0..MOST {
            sessions.open().unwrap();
        }
        assert!(!sessions.holds(&first));
    }

    #[test]
    fn a_session_opens_only_the_pages_files() {
        let sessions = Sessions::default();
        let value = sessions.open().unwrap();
        let cookie = format!("theme=dark; {COOKIE}={value}");
        // Whatever the browser says about where the request came from: a non-browser can say it too.
        for site in ["same-origin", "none", "cross-site", ""] {
            let h = headers(&[("cookie", &cookie), ("sec-fetch-site", site)]);
            for (method, path) in [
                (Method::GET, "/app/"),
                (Method::GET, "/app/assets/x.js"),
                (Method::HEAD, "/app/"),
            ] {
                assert!(
                    admitted(&method, &path.parse().unwrap(), &h, &sessions),
                    "{method} {path} {site:?}"
                );
            }
            for (method, path) in [
                (Method::GET, "/v1/status"),
                (Method::GET, "/v1/events"),
                (Method::POST, "/v1/stop-all"),
                (Method::PUT, "/v1/settings/permissions"),
                (Method::POST, "/v1/plans"),
                (Method::DELETE, "/v1/permissions/rules/x"),
                (Method::POST, "/app/"),
                (Method::GET, "/application"),
                (Method::GET, "/"),
            ] {
                assert!(
                    !admitted(&method, &path.parse().unwrap(), &h, &sessions),
                    "{method} {path} {site:?}"
                );
            }
        }
        // A cookie no session holds, the token as the cookie, no cookie.
        let page: Uri = "/app/".parse().unwrap();
        for cookie in [
            format!("{COOKIE}={}", "0".repeat(64)),
            format!("{COOKIE}={TOKEN}"),
        ] {
            assert!(!admitted(
                &Method::GET,
                &page,
                &headers(&[("cookie", &cookie)]),
                &sessions
            ));
        }
        assert!(!admitted(&Method::GET, &page, &HeaderMap::new(), &sessions));
        sessions.close(&value);
        assert!(!admitted(
            &Method::GET,
            &page,
            &headers(&[("cookie", &cookie)]),
            &sessions
        ));
    }

    #[test]
    fn only_signing_in_and_out_pass_without_the_token() {
        assert!(is_open(&Method::POST, &"/app/sign-in".parse().unwrap()));
        assert!(is_open(&Method::POST, &"/app/sign-out".parse().unwrap()));
        for (method, path) in [
            (Method::GET, "/app/sign-in"),
            (Method::GET, "/app/"),
            (Method::POST, "/v1/plans"),
            (Method::POST, "/app/sign-in/x"),
        ] {
            assert!(!is_open(&method, &path.parse().unwrap()), "{method} {path}");
        }
    }

    #[test]
    fn cookies_are_read_from_every_header() {
        let map = headers(&[
            ("cookie", "a=1; obid-page=x"),
            ("cookie", "obid-page=\"y\""),
        ]);
        assert_eq!(cookies(&map, COOKIE), vec!["x", "y"]);
        assert!(cookies(&map, "b").is_empty());
    }

    #[test]
    fn only_plain_names_inside_the_root() {
        let root = std::env::temp_dir().join(format!("obid-web-unit-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("dist/assets")).unwrap();
        std::fs::write(root.join("dist/index.html"), "page").unwrap();
        std::fs::write(root.join("dist/assets/app.js"), "js").unwrap();
        std::fs::write(root.join("dist/.hidden"), "no").unwrap();
        std::fs::write(root.join("secret"), "no").unwrap();
        let dist = root.join("dist");
        assert!(inside(&dist, "index.html").is_some());
        assert!(inside(&dist, "assets/app.js").is_some());
        for wrong in [
            "",
            "assets",
            "assets/",
            "../secret",
            "assets/../../secret",
            ".hidden",
            "./index.html",
            "assets//app.js",
            "assets\\app.js",
            "/etc/passwd",
            "C:/x",
            "missing.js",
        ] {
            assert!(inside(&dist, wrong).is_none(), "{wrong:?}");
        }
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(root.join("secret"), dist.join("out.txt")).unwrap();
            assert!(inside(&dist, "out.txt").is_none(), "a link out of the root");
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn media_types() {
        assert_eq!(
            type_of(Path::new("a/index.html")),
            "text/html; charset=utf-8"
        );
        assert_eq!(
            type_of(Path::new("assets/x.js")),
            "text/javascript; charset=utf-8"
        );
        assert_eq!(
            type_of(Path::new("assets/x.css")),
            "text/css; charset=utf-8"
        );
        assert_eq!(type_of(Path::new("x.unknown")), "application/octet-stream");
    }

    #[test]
    fn the_sign_in_page_says_nothing_of_obid_and_runs_only_its_script() {
        let page = SIGN_IN_PAGE
            .replace("{problem}", "")
            .replace("{script}", SIGN_IN_SCRIPT);
        assert!(page.contains("action=\"/app/sign-in\""));
        assert!(page.contains("name=\"token\""));
        assert_eq!(page.matches("<script").count(), 1);
        assert!(page.contains(&format!("<script>{SIGN_IN_SCRIPT}</script>")));
        // The policy names exactly that script, by its hash, and allows no other.
        let hash = base64::engine::general_purpose::STANDARD
            .encode(obi_protocol::keys::sha256(SIGN_IN_SCRIPT));
        assert!(
            SIGN_IN_POLICY.contains(&format!("script-src 'sha256-{hash}';")),
            "{}",
            *SIGN_IN_POLICY
        );
        assert!(SIGN_IN_POLICY.starts_with("default-src 'none';"));
        assert!(!SIGN_IN_POLICY.contains("script-src 'unsafe-inline'"));
        assert_eq!(
            escape("<b>\"x\" & y</b>"),
            "&lt;b&gt;&quot;x&quot; &amp; y&lt;/b&gt;"
        );
    }
}
