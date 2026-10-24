//! The GitHub login from the Mac (docs/runner-api.md, "obid only: GitHub's sign-in"), on the real
//! obid binary with a stand-in gh: `GET /v1/github` says whether gh is signed in and as whom;
//! `POST /v1/github/sign-in` runs gh's own device sign-in and passes on only its code and GitHub's
//! device page; gh never gets to change the person's own git settings.

mod support;

use std::path::Path;

use serde_json::json;
use support::*;

/// A stand-in gh: signed in once `$HOME/signed` is there; its sign-in prints a code and waits for
/// `$HOME/approve`, as the real one waits for the person on GitHub's page, and gives up once obid
/// or the test's folder is gone, so a test that ends leaves none behind.
const GH: &str = r#"#!/bin/sh
case "$1 $2" in
  "auth status")
    if [ -f "$HOME/signed" ]; then
      echo '{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"octo-cat","tokenSource":"keyring"}]}}'
    else
      echo '{"hosts":{}}'
    fi ;;
  "auth login")
    echo $$ > "$HOME/gh-pid"
    if [ -f "$HOME/slow" ]; then sleep 3; fi
    printf '%s\n' "$*" > "$HOME/login-args"
    printf '%s\n' "$GIT_CONFIG_GLOBAL" > "$HOME/git-config-global"
    echo '! One-time code (AB12-CD34) copied to clipboard' >&2
    echo 'Open this URL to continue in your web browser: https://github.com/login/device' >&2
    echo 'gho_NEVER_PASSED_ON' >&2
    while [ ! -f "$HOME/approve" ]; do
      kill -0 "$PPID" 2>/dev/null && [ -d "$HOME" ] || exit 1
      sleep 0.1
    done
    touch "$HOME/signed" ;;
  *) exit 1 ;;
esac
"#;

fn stand_in_gh(folder: &Path) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let bin = folder.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(bin.join("gh"), GH).unwrap();
    std::fs::set_permissions(bin.join("gh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    bin
}

#[test]
fn signs_in_with_ghs_own_device_sign_in() {
    let folder = Folder::new("github-sign-in");
    let remote = folder.0.join("remote.git");
    let config = config(&folder.0, &remote, &stub_agent());
    let bin = stand_in_gh(&folder.0);
    let obid = start(&folder.0, &config, Some(&bin));
    let home = folder.0.join("env-home");

    let before = call(&obid, "GET", "/v1/github", None);
    assert_eq!(before.status, 200, "{}", before.text);
    assert_eq!(
        before.body,
        json!({"gh": true, "signedIn": false, "user": null, "signIn": null})
    );

    let started = call(&obid, "POST", "/v1/github/sign-in", None);
    assert_eq!(started.status, 200, "{}", started.text);
    assert_eq!(started.body["url"], "https://github.com/login/device");
    assert_eq!(started.body["userCode"], "AB12-CD34");
    assert!(started.body["expiresAt"].is_string());
    assert!(!started.text.contains("gho_"), "{}", started.text);
    // Asked again, the same sign-in.
    let again = call(&obid, "POST", "/v1/github/sign-in", None);
    assert_eq!(again.body["userCode"], "AB12-CD34");
    let under_way = call(&obid, "GET", "/v1/github", None);
    assert_eq!(under_way.body["signIn"]["userCode"], "AB12-CD34");

    // gh's own login for github.com, with https for git, its page opened by the app.
    let args = std::fs::read_to_string(home.join("login-args")).unwrap();
    assert_eq!(
        args.trim(),
        "auth login --hostname github.com --git-protocol https --web --skip-ssh-key"
    );
    // git's global settings, which gh may write, are a file of the sign-in's own.
    let global = std::fs::read_to_string(home.join("git-config-global")).unwrap();
    assert!(
        global
            .trim()
            .starts_with(&*folder.0.join("home/tmp").to_string_lossy()),
        "{global}"
    );

    std::fs::write(home.join("approve"), "").unwrap();
    let signed = within(20, "gh to say it's signed in", || {
        let now = call(&obid, "GET", "/v1/github", None);
        (now.body["signedIn"] == true).then_some(now.body)
    });
    assert_eq!(
        signed,
        json!({"gh": true, "signedIn": true, "user": "octo-cat", "signIn": null})
    );
    assert!(!obid.log().contains("gho_"));
}

#[test]
fn a_sign_in_can_be_ended() {
    let folder = Folder::new("github-sign-in-end");
    let remote = folder.0.join("remote.git");
    let config = config(&folder.0, &remote, &stub_agent());
    let bin = stand_in_gh(&folder.0);
    let obid = start(&folder.0, &config, Some(&bin));
    let started = call(&obid, "POST", "/v1/github/sign-in", None);
    assert_eq!(started.status, 200, "{}", started.text);
    let ended = call(&obid, "DELETE", "/v1/github/sign-in", None);
    assert_eq!(ended.status, 204, "{}", ended.text);
    let after = call(&obid, "GET", "/v1/github", None);
    assert_eq!(after.body["signIn"], json!(null));
    assert_eq!(after.body["signedIn"], false);
}

/// While gh is slow to print its code, obid answers GET /v1/github at once (no lock held while gh
/// starts), a second POST says the sign-in is starting, and the first gets the code.
#[test]
fn a_starting_sign_in_holds_nothing_up() {
    let folder = Folder::new("github-sign-in-slow");
    let remote = folder.0.join("remote.git");
    let config = config(&folder.0, &remote, &stub_agent());
    let bin = stand_in_gh(&folder.0);
    let obid = start(&folder.0, &config, Some(&bin));
    std::fs::write(folder.0.join("env-home/slow"), "").unwrap();
    std::thread::scope(|scope| {
        let first = scope.spawn(|| call(&obid, "POST", "/v1/github/sign-in", None));
        std::thread::sleep(std::time::Duration::from_millis(800));
        let asked = std::time::Instant::now();
        let status = call(&obid, "GET", "/v1/github", None);
        assert_eq!(status.status, 200, "{}", status.text);
        assert!(
            asked.elapsed() < std::time::Duration::from_secs(2),
            "GET waited for gh"
        );
        assert_eq!(status.body["signIn"], json!(null));
        let second = call(&obid, "POST", "/v1/github/sign-in", None);
        assert_eq!(second.status, 409, "{}", second.text);
        assert!(second.text.contains("starting"), "{}", second.text);
        let first = first.join().unwrap();
        assert_eq!(first.status, 200, "{}", first.text);
        assert_eq!(first.body["userCode"], "AB12-CD34");
    });
}

/// A sign-in started right after the last one ended gets a folder of its own, which the ended
/// one's task never removes.
#[test]
fn back_to_back_sign_ins_keep_their_own_folders() {
    let folder = Folder::new("github-sign-in-again");
    let remote = folder.0.join("remote.git");
    let config = config(&folder.0, &remote, &stub_agent());
    let bin = stand_in_gh(&folder.0);
    let obid = start(&folder.0, &config, Some(&bin));
    let home = folder.0.join("env-home");
    let global = || {
        std::path::PathBuf::from(
            std::fs::read_to_string(home.join("git-config-global"))
                .unwrap()
                .trim(),
        )
    };
    let first = call(&obid, "POST", "/v1/github/sign-in", None);
    assert_eq!(first.status, 200, "{}", first.text);
    let first_folder = global().parent().unwrap().to_path_buf();
    let ended = call(&obid, "DELETE", "/v1/github/sign-in", None);
    assert_eq!(ended.status, 204, "{}", ended.text);
    let second = call(&obid, "POST", "/v1/github/sign-in", None);
    assert_eq!(second.status, 200, "{}", second.text);
    let second_folder = global().parent().unwrap().to_path_buf();
    assert_ne!(first_folder, second_folder);
    assert!(!first_folder.exists(), "{first_folder:?}");
    // The ended one's task is long done; the new one's folder is still there while it waits.
    std::thread::sleep(std::time::Duration::from_millis(500));
    assert!(second_folder.is_dir(), "{second_folder:?}");
    assert_eq!(
        call(&obid, "GET", "/v1/github", None).body["signIn"]["userCode"],
        "AB12-CD34"
    );
}

/// A sign-in left waiting when its test ends (obid gone, the approve file never written) ends too:
/// the stand-in gh never outlives its test.
#[test]
fn a_waiting_sign_in_ends_with_its_test() {
    let folder = Folder::new("github-sign-in-left");
    let remote = folder.0.join("remote.git");
    let config = config(&folder.0, &remote, &stub_agent());
    let bin = stand_in_gh(&folder.0);
    let obid = start(&folder.0, &config, Some(&bin));
    let started = call(&obid, "POST", "/v1/github/sign-in", None);
    assert_eq!(started.status, 200, "{}", started.text);
    let pid: i32 = within(10, "the stand-in gh to say its pid", || {
        std::fs::read_to_string(folder.0.join("env-home/gh-pid"))
            .ok()?
            .trim()
            .parse()
            .ok()
    });
    let alive = || nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None).is_ok();
    assert!(alive());
    drop(obid);
    within(10, "the stand-in gh to end", || (!alive()).then_some(()));
}
