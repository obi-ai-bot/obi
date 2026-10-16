//! The web app (`apps/web`) as obid serves it: its built files on obid's own loopback address,
//! behind the same token as the API (docs/runner-api.md, "obid only: the web app").
//!
//! A browser can't put the token in an `Authorization` header when it opens a page, so the page
//! signs in once. `GET /app/` without the token answers `401` with a small sign-in form; the token
//! pasted there goes to `POST /app/sign-in`, and obid answers with a session cookie. The cookie
//! holds a SHA-256 of the token, never the token, and obid takes it only from its own page
//! (`Sec-Fetch-Site: same-origin`, or `none` when the person typed the page's address): another
//! web site, or another server on 127.0.0.1, can't use it even though the browser has it.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use axum::extract::rejection::FormRejection;
use axum::extract::{Form, Path as UrlPath, State};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, Uri, header};
use axum::response::{IntoResponse, Response};

use crate::api::{ApiError, Shared};

/// The session cookie's name.
pub const COOKIE: &str = "obid-session";
/// Where the sign-in form goes. The gate lets it through without the token: it checks the token
/// it is given itself.
pub const SIGN_IN: &str = "/app/sign-in";
/// How long a browser stays signed in: 30 days, as long as a paired device's token lasts.
const MAX_AGE: u32 = 30 * 24 * 60 * 60;

/// The session cookie's value for `token`: what a signed-in browser holds instead of the token.
/// It changes when the token does, so a new token signs every browser out.
pub fn session(token: &str) -> String {
    hex::encode(obi_protocol::keys::sha256(format!(
        "obid web session\n{token}"
    )))
}

/// Whether `path` is the web app's: `/app` and everything under `/app/`.
pub fn is_app(path: &str) -> bool {
    path == "/app" || path.starts_with("/app/")
}

/// Whether a request is the sign-in form being sent.
pub fn is_sign_in(method: &Method, uri: &Uri) -> bool {
    method == Method::POST && uri.path() == SIGN_IN
}

/// Whether a request that carries no API token is admitted by the session cookie: the right
/// cookie, from obid's own page. That's `Sec-Fetch-Site: same-origin` for anything, or `none` (an
/// address typed into the browser, or a bookmark) for opening the page itself. A request without
/// `Sec-Fetch-Site` isn't a browser's, and sends the token instead.
pub fn admitted(method: &Method, uri: &Uri, headers: &HeaderMap, token: &str) -> bool {
    let own_page = match single(headers, "sec-fetch-site") {
        Some("same-origin") => true,
        Some("none") => is_app(uri.path()) && (method == Method::GET || method == Method::HEAD),
        _ => false,
    };
    let expected = session(token);
    own_page
        && cookies(headers, COOKIE)
            .iter()
            .any(|given| crate::token::same(given, &expected))
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

/// `POST /app/sign-in` (a form: `token=…`): the right token signs this browser in for 30 days and
/// goes back to the page; anything else is the sign-in form again, `401`.
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
    let cookie = format!(
        "{COOKIE}={}; Path=/; Max-Age={MAX_AGE}; HttpOnly; SameSite=Strict",
        session(&shared.token)
    );
    see_the_page(&cookie)
}

/// `POST /app/sign-out`: this browser forgets its session and is back at the sign-in form.
pub async fn sign_out() -> Response {
    see_the_page(&format!(
        "{COOKIE}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"
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
    let page = SIGN_IN_PAGE.replace("{problem}", &problem);
    let mut response = (StatusCode::UNAUTHORIZED, page).into_response();
    let headers = response.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/html; charset=utf-8"),
    );
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
        ),
    );
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
    fn the_session_is_not_the_token() {
        let value = session(TOKEN);
        assert_eq!(value.len(), 64);
        assert_ne!(value, TOKEN);
        assert!(!value.contains(TOKEN));
        assert_eq!(value, session(TOKEN));
        assert_ne!(value, session(&TOKEN.replace('0', "1")));
    }

    #[test]
    fn the_cookie_is_taken_only_from_obids_own_page() {
        let cookie = format!("theme=dark; {COOKIE}={}", session(TOKEN));
        let get = Method::GET;
        let status: Uri = "/v1/status".parse().unwrap();
        let page: Uri = "/app/".parse().unwrap();
        let from = |site: &str| headers(&[("cookie", &cookie), ("sec-fetch-site", site)]);
        assert!(admitted(&get, &status, &from("same-origin"), TOKEN));
        assert!(admitted(
            &Method::POST,
            &status,
            &from("same-origin"),
            TOKEN
        ));
        assert!(admitted(&get, &page, &from("same-origin"), TOKEN));
        // Typed into the browser: the page opens, the API doesn't.
        assert!(admitted(&get, &page, &from("none"), TOKEN));
        assert!(!admitted(&get, &status, &from("none"), TOKEN));
        assert!(!admitted(&Method::POST, &page, &from("none"), TOKEN));
        // Another site, or another server on 127.0.0.1 (same site, another origin).
        for site in ["cross-site", "same-site", "", "Same-Origin"] {
            assert!(!admitted(&get, &status, &from(site), TOKEN), "{site}");
            assert!(!admitted(&get, &page, &from(site), TOKEN), "{site}");
        }
        // No Sec-Fetch-Site: not a browser, which sends the token instead.
        assert!(!admitted(
            &get,
            &page,
            &headers(&[("cookie", &cookie)]),
            TOKEN
        ));
        // Two Sec-Fetch-Site headers: neither is believed.
        let twice = headers(&[
            ("cookie", &cookie),
            ("sec-fetch-site", "same-origin"),
            ("sec-fetch-site", "cross-site"),
        ]);
        assert!(!admitted(&get, &status, &twice, TOKEN));
        // The wrong cookie, the token itself as the cookie, no cookie.
        let wrong = headers(&[
            (
                "cookie",
                &format!("{COOKIE}={}", session("another token, quite long enough")),
            ),
            ("sec-fetch-site", "same-origin"),
        ]);
        assert!(!admitted(&get, &status, &wrong, TOKEN));
        let raw = headers(&[
            ("cookie", &format!("{COOKIE}={TOKEN}")),
            ("sec-fetch-site", "same-origin"),
        ]);
        assert!(!admitted(&get, &status, &raw, TOKEN));
        assert!(!admitted(
            &get,
            &status,
            &headers(&[("sec-fetch-site", "same-origin")]),
            TOKEN
        ));
    }

    #[test]
    fn cookies_are_read_from_every_header() {
        let map = headers(&[
            ("cookie", "a=1; obid-session=x"),
            ("cookie", "obid-session=\"y\""),
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
    fn the_sign_in_page_says_nothing_of_obid() {
        let page = SIGN_IN_PAGE.replace("{problem}", "");
        assert!(page.contains("action=\"/app/sign-in\""));
        assert!(page.contains("name=\"token\""));
        assert!(!page.contains("<script"));
        assert_eq!(
            escape("<b>\"x\" & y</b>"),
            "&lt;b&gt;&quot;x&quot; &amp; y&lt;/b&gt;"
        );
    }
}
