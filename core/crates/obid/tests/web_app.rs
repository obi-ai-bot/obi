//! The web app as obid serves it (docs/runner-api.md, "obid only: the web app"), asked over HTTP
//! as a browser asks: without the token the page and the API are both `401`, the page signs in
//! with a form and gets a session cookie that isn't the token, and that cookie opens the page and
//! the API only from obid's own page.

mod support;

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};
use support::*;

/// A built web app of the test's own: a page, a script, and the mascot's page.
fn web(folder: &Folder) -> std::path::PathBuf {
    let dist = folder.0.join("web");
    std::fs::create_dir_all(dist.join("assets")).unwrap();
    std::fs::create_dir_all(dist.join("oby")).unwrap();
    std::fs::write(
        dist.join("index.html"),
        "<!doctype html><title>Oby</title><div id=root></div>",
    )
    .unwrap();
    std::fs::write(dist.join("assets/app.js"), "console.log('oby')").unwrap();
    std::fs::write(
        dist.join("oby/oby.html"),
        "<!doctype html><script type=module>1</script>",
    )
    .unwrap();
    std::fs::write(folder.0.join("outside.txt"), "outside the web app").unwrap();
    dist
}

fn obid(folder: &Folder, web: Option<&Path>) -> Obid {
    let mut config = config(
        &folder.0,
        Path::new("/nonexistent/remote.git"),
        Path::new("/nonexistent/claude"),
    );
    if let Some(web) = web {
        config["web"] = json!(web);
    }
    start(&folder.0, &config, None)
}

struct Reply {
    status: u16,
    head: String,
    body: String,
}

impl Reply {
    /// A header's value, by its name in any case.
    fn header(&self, name: &str) -> Option<String> {
        self.head.lines().skip(1).find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.eq_ignore_ascii_case(name)
                .then(|| value.trim().to_owned())
        })
    }
}

/// One request as written, `Host: 127.0.0.1` and `Connection: close` added.
fn raw(obid: &Obid, method: &str, target: &str, headers: &[(&str, &str)], body: &str) -> Reply {
    let mut stream = TcpStream::connect(("127.0.0.1", obid.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    let mut text = format!("{method} {target} HTTP/1.1\r\nConnection: close\r\n");
    if !headers.iter().any(|(k, _)| k.eq_ignore_ascii_case("host")) {
        text.push_str("Host: 127.0.0.1\r\n");
    }
    for (key, value) in headers {
        text.push_str(&format!("{key}: {value}\r\n"));
    }
    text.push_str(&format!("Content-Length: {}\r\n\r\n{body}", body.len()));
    stream.write_all(text.as_bytes()).unwrap();
    let mut answer = Vec::new();
    stream.read_to_end(&mut answer).unwrap();
    let answer = String::from_utf8_lossy(&answer).into_owned();
    let (head, body) = answer.split_once("\r\n\r\n").unwrap_or((&answer, ""));
    let status = head
        .split(' ')
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    Reply {
        status,
        head: head.to_owned(),
        body: body.to_owned(),
    }
}

/// The session cookie the sign-in form gives, as `obid-session=<value>`.
fn sign_in(obid: &Obid) -> String {
    let reply = raw(
        obid,
        "POST",
        "/app/sign-in",
        &[
            ("Content-Type", "application/x-www-form-urlencoded"),
            ("Sec-Fetch-Site", "same-origin"),
        ],
        &format!("token={TOKEN}%0A"),
    );
    assert_eq!(reply.status, 303, "{}", reply.head);
    assert_eq!(reply.header("location").as_deref(), Some("/app/"));
    let cookie = reply.header("set-cookie").expect("a session cookie");
    for part in ["Path=/", "HttpOnly", "SameSite=Strict", "Max-Age=2592000"] {
        assert!(cookie.contains(part), "{part} in {cookie}");
    }
    assert!(
        !cookie.contains(TOKEN),
        "the cookie holds the token: {cookie}"
    );
    cookie.split(';').next().unwrap().to_owned()
}

#[test]
fn without_the_token_the_page_and_the_api_are_401() {
    let folder = Folder::new("web-401");
    let dist = web(&folder);
    let obid = obid(&folder, Some(&dist));

    // The API, as before: JSON, 401.
    let api = raw(&obid, "GET", "/v1/status", &[], "");
    assert_eq!(api.status, 401);
    assert!(api.body.contains("API token"), "{}", api.body);

    // The page: 401 too, the sign-in form, and nothing of the app.
    for target in ["/app/", "/app", "/app/assets/app.js", "/app/oby/oby.html"] {
        let page = raw(&obid, "GET", target, &[("Sec-Fetch-Site", "none")], "");
        assert_eq!(page.status, 401, "{target}");
        assert!(
            page.header("content-type")
                .unwrap()
                .starts_with("text/html"),
            "{target}"
        );
        assert!(
            page.body.contains("action=\"/app/sign-in\""),
            "{target}: {}",
            page.body
        );
        assert!(
            !page.body.contains("<div id=root>") && !page.body.contains("console.log"),
            "{target}"
        );
        assert!(
            page.header("content-security-policy")
                .unwrap()
                .contains("default-src 'none'")
        );
    }
    // A wrong token in the form: still 401, and no cookie.
    let wrong = raw(
        &obid,
        "POST",
        "/app/sign-in",
        &[
            ("Content-Type", "application/x-www-form-urlencoded"),
            ("Sec-Fetch-Site", "same-origin"),
        ],
        "token=not-the-token-but-long-enough-0123456789abcdef",
    );
    assert_eq!(wrong.status, 401);
    assert!(wrong.header("set-cookie").is_none());
    assert!(
        wrong.body.contains("isn't this obid's token"),
        "{}",
        wrong.body
    );
    // No form at all.
    let empty = raw(
        &obid,
        "POST",
        "/app/sign-in",
        &[("Sec-Fetch-Site", "same-origin")],
        "",
    );
    assert_eq!(empty.status, 401);
    assert!(empty.header("set-cookie").is_none());
    // The right token sent from another site's page: refused all the same.
    let elsewhere = raw(
        &obid,
        "POST",
        "/app/sign-in",
        &[
            ("Content-Type", "application/x-www-form-urlencoded"),
            ("Sec-Fetch-Site", "cross-site"),
        ],
        &format!("token={TOKEN}"),
    );
    assert_eq!(elsewhere.status, 401);
    assert!(elsewhere.header("set-cookie").is_none());
    // Not on a loopback name: 403, as every request.
    let rebound = raw(&obid, "GET", "/app/", &[("Host", "evil.example:7777")], "");
    assert_eq!(rebound.status, 403);
    let rebound = raw(
        &obid,
        "POST",
        "/app/sign-in",
        &[
            ("Host", "evil.example"),
            ("Content-Type", "application/x-www-form-urlencoded"),
        ],
        &format!("token={TOKEN}"),
    );
    assert_eq!(rebound.status, 403);
    assert!(rebound.header("set-cookie").is_none());
}

#[test]
fn the_token_opens_the_page() {
    let folder = Folder::new("web-bearer");
    let dist = web(&folder);
    let obid = obid(&folder, Some(&dist));
    let bearer = format!("Bearer {TOKEN}");
    let page = raw(&obid, "GET", "/app/", &[("Authorization", &bearer)], "");
    assert_eq!(page.status, 200, "{}", page.body);
    assert!(page.body.contains("<div id=root>"));
    assert_eq!(
        page.header("content-type").as_deref(),
        Some("text/html; charset=utf-8")
    );
    let policy = page.header("content-security-policy").unwrap();
    assert!(policy.contains("script-src 'self';"), "{policy}");
    assert!(policy.contains("frame-ancestors 'self'"), "{policy}");
    assert_eq!(
        page.header("x-content-type-options").as_deref(),
        Some("nosniff")
    );

    let script = raw(
        &obid,
        "GET",
        "/app/assets/app.js",
        &[("Authorization", &bearer)],
        "",
    );
    assert_eq!(script.status, 200);
    assert_eq!(
        script.header("content-type").as_deref(),
        Some("text/javascript; charset=utf-8")
    );
    // The mascot runs its own inline scripts: its page alone may.
    let mascot = raw(
        &obid,
        "GET",
        "/app/oby/oby.html",
        &[("Authorization", &bearer)],
        "",
    );
    assert_eq!(mascot.status, 200);
    assert!(
        mascot
            .header("content-security-policy")
            .unwrap()
            .contains("'unsafe-inline'")
    );
    let bare = raw(&obid, "GET", "/app", &[("Authorization", &bearer)], "");
    assert_eq!(bare.status, 308);
    assert_eq!(bare.header("location").as_deref(), Some("/app/"));

    // Nothing outside the built app, however it's named.
    for target in [
        "/app/../outside.txt",
        "/app/%2e%2e/outside.txt",
        "/app/..%2foutside.txt",
        "/app/assets/%2e%2e/%2e%2e/outside.txt",
        "/app/.%2e/api-token",
        "/app/missing.js",
        "/app/assets",
    ] {
        let reply = raw(&obid, "GET", target, &[("Authorization", &bearer)], "");
        assert!(
            reply.status == 404 || reply.status == 400,
            "{target}: {}",
            reply.head
        );
        assert!(
            !reply.body.contains("outside the web app") && !reply.body.contains(TOKEN),
            "{target}"
        );
    }
}

#[test]
fn the_cookie_opens_the_page_and_the_api_only_from_obids_own_page() {
    let folder = Folder::new("web-cookie");
    let dist = web(&folder);
    let obid = obid(&folder, Some(&dist));
    let cookie = sign_in(&obid);

    let from = |site: &str| -> Vec<(&str, String)> {
        let mut h = vec![("Cookie", cookie.clone())];
        if !site.is_empty() {
            h.push(("Sec-Fetch-Site", site.to_owned()));
        }
        h
    };
    let ask = |method: &str, target: &str, site: &str| {
        let h = from(site);
        let h: Vec<(&str, &str)> = h.iter().map(|(k, v)| (*k, v.as_str())).collect();
        raw(&obid, method, target, &h, "")
    };

    // obid's own page: the page, its files, the API, the event stream's answer.
    assert_eq!(ask("GET", "/app/", "same-origin").status, 200);
    assert_eq!(ask("GET", "/app/assets/app.js", "same-origin").status, 200);
    let status = ask("GET", "/v1/status", "same-origin");
    assert_eq!(status.status, 200, "{}", status.body);
    let status: Value = serde_json::from_str(&status.body).unwrap();
    assert_eq!(status["runner"]["engine"], "obid");
    assert_eq!(ask("GET", "/v1/jobs", "same-origin").status, 200);
    assert_eq!(ask("GET", "/v1/inbox", "same-origin").status, 200);
    assert_eq!(ask("GET", "/v1/conversation", "same-origin").status, 200);
    assert_eq!(ask("POST", "/v1/stop-all", "same-origin").status, 200);
    // The address typed into the browser: the page opens; the API doesn't.
    assert_eq!(ask("GET", "/app/", "none").status, 200);
    assert_eq!(ask("GET", "/v1/status", "none").status, 401);
    // Another site, another server on 127.0.0.1, or no browser at all: 401, the page included.
    for site in ["cross-site", "same-site", ""] {
        assert_eq!(ask("GET", "/v1/status", site).status, 401, "{site:?}");
        assert_eq!(ask("POST", "/v1/stop-all", site).status, 401, "{site:?}");
        assert_eq!(ask("GET", "/app/", site).status, 401, "{site:?}");
    }
    // The token itself as the cookie isn't a session.
    let raw_token = raw(
        &obid,
        "GET",
        "/v1/status",
        &[
            ("Cookie", &format!("obid-session={TOKEN}")),
            ("Sec-Fetch-Site", "same-origin"),
        ],
        "",
    );
    assert_eq!(raw_token.status, 401);

    // Signing out forgets it.
    let out = ask("POST", "/app/sign-out", "same-origin");
    assert_eq!(out.status, 303);
    assert!(out.header("set-cookie").unwrap().contains("Max-Age=0"));
    // Signing out needs the session too: another site can't sign the page out.
    assert_eq!(ask("POST", "/app/sign-out", "cross-site").status, 401);

    // The session's value never reaches obid's log.
    let value = cookie.split_once('=').unwrap().1;
    assert!(!obid.log().contains(value));
    assert!(!obid.log().contains(TOKEN));
}

#[test]
fn a_web_app_not_built_says_so_behind_the_token() {
    let folder = Folder::new("web-missing");
    let obid = obid(&folder, Some(&folder.0.join("no-such-dist")));
    let without = raw(&obid, "GET", "/app/", &[], "");
    assert_eq!(without.status, 401);
    let with = raw(
        &obid,
        "GET",
        "/app/",
        &[("Authorization", &format!("Bearer {TOKEN}"))],
        "",
    );
    assert_eq!(with.status, 404);
    assert!(with.body.contains("isn't built"), "{}", with.body);
}
