//! The web app as obid serves it (docs/runner-api.md, "obid only: the web app"), asked over HTTP
//! as a browser asks, and as anything else on the machine could: without the token the page and
//! the API are both `401`; the page signs in with a form and gets a random session for its own
//! files; that session, however it's sent and whatever headers come with it, opens nothing under
//! `/v1`, which takes only the token; and signing out ends it.

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

/// Signs in with the form: the answer, and the session it gives as `name=value`.
fn sign_in(obid: &Obid) -> (Reply, String) {
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
    let cookie = reply.header("set-cookie").expect("a page session");
    let pair = cookie.split(';').next().unwrap().to_owned();
    (reply, pair)
}

/// What obid answers without the token: every method the API has, on a few of its routes.
const API: [(&str, &str, &str); 11] = [
    ("GET", "/v1/status", ""),
    ("GET", "/v1/events", ""),
    ("GET", "/v1/jobs", ""),
    ("GET", "/v1/conversation", ""),
    ("GET", "/v1/obid/plugins", ""),
    ("POST", "/v1/stop-all", ""),
    ("POST", "/v1/plans", "{\"said\": \"stop everything\"}"),
    ("PUT", "/v1/settings/permissions", "{\"mode\": \"bypass\"}"),
    ("PUT", "/v1/settings/jobs", "{\"maxRunning\": 1}"),
    ("DELETE", "/v1/permissions/rules/r1", ""),
    ("POST", "/v1/inbox/i1/answer", "{\"done\": true}"),
];

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

    // The API's answers aren't kept by the browser, and aren't read as anything but what they say.
    let status = raw(
        &obid,
        "GET",
        "/v1/status",
        &[("Authorization", &bearer)],
        "",
    );
    assert_eq!(status.status, 200);
    assert_eq!(status.header("cache-control").as_deref(), Some("no-store"));
    assert_eq!(
        status.header("x-content-type-options").as_deref(),
        Some("nosniff")
    );
    let refused = raw(&obid, "GET", "/v1/status", &[], "");
    assert_eq!(refused.header("cache-control").as_deref(), Some("no-store"));

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
fn signing_in_opens_a_random_session_for_the_pages_files() {
    let folder = Folder::new("web-sign-in");
    let dist = web(&folder);
    let obid = obid(&folder, Some(&dist));
    let (reply, cookie) = sign_in(&obid);
    assert_eq!(reply.header("location").as_deref(), Some("/app/"));
    let set = reply.header("set-cookie").unwrap();
    for part in ["Path=/app;", "HttpOnly", "SameSite=Strict"] {
        assert!(set.contains(part), "{part} in {set}");
    }
    // It ends with the browser's session, and holds nothing derived from the token: each sign-in
    // opens a session of its own, at random.
    assert!(
        !set.contains("Max-Age") && !set.contains("Expires"),
        "{set}"
    );
    assert!(!set.contains(TOKEN), "the cookie holds the token: {set}");
    let (_, again) = sign_in(&obid);
    assert_ne!(cookie, again);
    // It opens the page's own files, which hold no data.
    for target in ["/app/", "/app/assets/app.js", "/app/oby/oby.html"] {
        let reply = raw(&obid, "GET", target, &[("Cookie", &cookie)], "");
        assert_eq!(reply.status, 200, "{target}");
    }
    // Neither the token nor a session's value reaches obid's log.
    let log = obid.log();
    assert!(!log.contains(TOKEN));
    for c in [&cookie, &again] {
        assert!(!log.contains(c.split_once('=').unwrap().1));
    }
}

#[test]
fn a_page_session_opens_nothing_under_v1_whatever_headers_come_with_it() {
    let folder = Folder::new("web-no-api");
    let dist = web(&folder);
    let obid = obid(&folder, Some(&dist));
    let (_, cookie) = sign_in(&obid);

    // Not with the cookie alone, and not with the headers a browser would add, which anything else
    // on the machine (a local server that got the cookie) can send too.
    let forged: [&[(&str, &str)]; 4] = [
        &[("Cookie", &cookie)],
        &[("Cookie", &cookie), ("Sec-Fetch-Site", "same-origin")],
        &[
            ("Cookie", &cookie),
            ("Sec-Fetch-Site", "same-origin"),
            ("Origin", "http://127.0.0.1:7811"),
            ("Sec-Fetch-Mode", "cors"),
        ],
        &[("Cookie", &cookie), ("Sec-Fetch-Site", "none")],
    ];
    for headers in forged {
        for (method, target, body) in API {
            let mut h = headers.to_vec();
            if !body.is_empty() {
                h.push(("Content-Type", "application/json"));
            }
            let reply = raw(&obid, method, target, &h, body);
            assert_eq!(
                reply.status, 401,
                "{method} {target} with {headers:?}: {}",
                reply.head
            );
        }
    }
    // What those calls would have changed is as it was.
    let bearer = format!("Bearer {TOKEN}");
    let jobs = raw(
        &obid,
        "GET",
        "/v1/settings/jobs",
        &[("Authorization", &bearer)],
        "",
    );
    assert!(!jobs.body.contains("\"maxRunning\":1"), "{}", jobs.body);

    // The API takes the token: the same reads get past the gate with it.
    for (method, target, body) in API {
        if target == "/v1/events" || method != "GET" {
            continue;
        }
        let reply = raw(&obid, method, target, &[("Authorization", &bearer)], body);
        assert_eq!(reply.status, 200, "{method} {target}: {}", reply.head);
    }
}

#[test]
fn signing_out_ends_the_session() {
    let folder = Folder::new("web-sign-out");
    let dist = web(&folder);
    let obid = obid(&folder, Some(&dist));
    let (_, cookie) = sign_in(&obid);
    let (_, other) = sign_in(&obid);
    // As a browser opens the page from a typed address, and signs out from it.
    const TYPED: (&str, &str) = ("Sec-Fetch-Site", "none");
    assert_eq!(
        raw(&obid, "GET", "/app/", &[("Cookie", &cookie), TYPED], "").status,
        200
    );
    // The cookie a browser holds, or anything that copied it, opens nothing once signed out; the
    // other session is untouched.
    let out = raw(
        &obid,
        "POST",
        "/app/sign-out",
        &[("Cookie", &cookie), ("Sec-Fetch-Site", "same-origin")],
        "",
    );
    assert_eq!(out.status, 303);
    assert!(out.header("set-cookie").unwrap().contains("Max-Age=0"));
    assert_eq!(
        raw(&obid, "GET", "/app/", &[("Cookie", &cookie), TYPED], "").status,
        401
    );
    assert_eq!(
        raw(&obid, "GET", "/app/", &[("Cookie", &other), TYPED], "").status,
        200
    );
    // Signing out with no session (another site's page asking, say) ends nothing else.
    let elsewhere = raw(
        &obid,
        "POST",
        "/app/sign-out",
        &[("Sec-Fetch-Site", "cross-site")],
        "",
    );
    assert_eq!(elsewhere.status, 303);
    assert_eq!(
        raw(&obid, "GET", "/app/", &[("Cookie", &other), TYPED], "").status,
        200
    );
}

#[test]
fn a_session_ends_when_obid_stops() {
    let folder = Folder::new("web-restart");
    let dist = web(&folder);
    let mut first = obid(&folder, Some(&dist));
    let (_, cookie) = sign_in(&first);
    assert_eq!(
        raw(&first, "GET", "/app/", &[("Cookie", &cookie)], "").status,
        200
    );
    first.stop();
    let second = obid(&folder, Some(&dist));
    assert_eq!(
        raw(&second, "GET", "/app/", &[("Cookie", &cookie)], "").status,
        401
    );
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
