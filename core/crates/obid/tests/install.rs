//! `install/install.sh` and `install/package.sh` (docs/install.md, #585): what the installer
//! checks, what it puts where, what the service files say, and that no secret is in any argument
//! or environment it uses.
//!
//! The scripts run for real under `sh`, in a `PATH` of symlinks to just the tools they use, plus
//! stand-ins for the ones that would change the machine (`systemctl`, `loginctl`, `launchctl`,
//! `uname`, so a Linux machine is checked on a Mac too). Each stand-in appends what it was called with, and its environment, to
//! `calls.log`.

#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use obid::config::Config;

const OBID: &str = env!("CARGO_BIN_EXE_obid");

/// The tools the installer may use (and `env`, which the stand-ins use), found on this machine and
/// linked into the test's `PATH`.
const TOOLS: &[&str] = &[
    "sh", "tar", "gzip", "od", "head", "tr", "sed", "mkdir", "chmod", "cat", "cp", "mv", "rm",
    "rmdir", "mktemp", "id", "dirname", "grep", "sleep", "pgrep", "kill", "env",
];

struct Folder(PathBuf);

impl Folder {
    fn new(name: &str) -> Folder {
        let path = std::env::temp_dir().join(format!("obid-install-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Folder(path.canonicalize().unwrap())
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        if std::env::var_os("OBID_TEST_KEEP").is_some() {
            eprintln!("kept {}", self.0.display());
            return;
        }
        let _ = Command::new("chmod")
            .args(["-R", "u+w"])
            .arg(&self.0)
            .status();
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn script(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../install")
        .join(name)
        .canonicalize()
        .unwrap()
}

/// The digest tool the installer prefers, or the one it falls back to (macOS before 15 has only
/// `shasum`).
const DIGEST_TOOLS: &[&str] = &["sha256sum", "shasum"];

fn find_tool(name: &str) -> Option<PathBuf> {
    // macOS keeps sha256sum in /sbin.
    [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "/usr/local/bin",
        "/opt/homebrew/bin",
    ]
    .iter()
    .map(|dir| Path::new(dir).join(name))
    .find(|path| path.exists())
}

fn write_executable(path: &Path, text: &str) {
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

#[derive(Clone, Copy, PartialEq)]
enum Os {
    Linux,
    Mac,
}

/// A user's machine in a folder: their `HOME`, the tools on their `PATH`, and an archive to
/// install from.
struct Rig {
    folder: Folder,
    os: Os,
}

impl Rig {
    /// A Linux machine with bubblewrap and slirp4netns, systemd and an archive of a fake obid.
    fn linux(name: &str) -> Rig {
        Rig::new(name, Os::Linux)
    }

    fn mac(name: &str) -> Rig {
        Rig::new(name, Os::Mac)
    }

    fn new(name: &str, os: Os) -> Rig {
        let rig = Rig {
            folder: Folder::new(name),
            os,
        };
        let tools = rig.tools();
        std::fs::create_dir_all(&tools).unwrap();
        std::fs::create_dir_all(rig.user_home()).unwrap();
        std::fs::create_dir_all(rig.folder.0.join("tmp")).unwrap();
        for tool in TOOLS {
            let found = find_tool(tool).unwrap_or_else(|| panic!("{tool} isn't on this machine"));
            std::os::unix::fs::symlink(found, tools.join(tool)).unwrap();
        }
        let digest = DIGEST_TOOLS
            .iter()
            .find_map(|tool| find_tool(tool).map(|found| (tool, found)))
            .expect("neither sha256sum nor shasum is on this machine");
        std::os::unix::fs::symlink(digest.1, tools.join(digest.0)).unwrap();
        if os == Os::Mac {
            write_executable(
                &tools.join("uname"),
                "#!/bin/sh\ncase \"$1\" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n",
            );
            rig.stand_in("launchctl", "");
        } else {
            // Linux whatever machine runs the tests, so the same paths are checked on a Mac.
            write_executable(
                &tools.join("uname"),
                &format!(
                    "#!/bin/sh\ncase \"$1\" in -s) echo Linux ;; -m) echo {} ;; esac\n",
                    if cfg!(target_arch = "aarch64") {
                        "aarch64"
                    } else {
                        "x86_64"
                    }
                ),
            );
            rig.stand_in("systemctl", "");
            rig.stand_in("loginctl", "");
            rig.stand_in("bwrap", "");
            rig.stand_in("slirp4netns", "");
        }
        rig.archive(
            "#!/bin/sh\ncase \"$1\" in --version) echo \"obid 9.9.9-test\" ;; *) sleep 300 ;; esac\n",
        );
        rig
    }

    fn tools(&self) -> PathBuf {
        self.folder.0.join("tools")
    }

    fn user_home(&self) -> PathBuf {
        self.folder.0.join("user")
    }

    fn calls(&self) -> String {
        std::fs::read_to_string(self.folder.0.join("calls.log")).unwrap_or_default()
    }

    fn target(&self) -> &'static str {
        match self.os {
            Os::Linux => {
                if cfg!(target_arch = "aarch64") {
                    "linux-aarch64"
                } else {
                    "linux-x86_64"
                }
            }
            Os::Mac => "macos-arm64",
        }
    }

    /// A tool that does nothing but write down how it was called, and with what in its environment.
    /// `extra` runs after that.
    fn stand_in(&self, name: &str, extra: &str) {
        let log = self.folder.0.join("calls.log");
        write_executable(
            &self.tools().join(name),
            &format!(
                "#!/bin/sh\n{{ echo \"{name} $*\"; env; }} >> '{}'\n{extra}\n",
                log.display()
            ),
        );
    }

    fn remove_tool(&self, name: &str) {
        std::fs::remove_file(self.tools().join(name)).unwrap();
    }

    /// `archive.tar.gz`: `bin/obid` is the given text, with a plug-in and a web app beside it.
    fn archive(&self, obid_script: &str) {
        let stage = self.folder.0.join("stage");
        let _ = std::fs::remove_dir_all(&stage);
        std::fs::create_dir_all(stage.join("bin")).unwrap();
        std::fs::create_dir_all(stage.join("share/plugins/demo")).unwrap();
        std::fs::create_dir_all(stage.join("share/web")).unwrap();
        write_executable(&stage.join("bin/obid"), obid_script);
        std::fs::write(stage.join("share/plugins/demo/obi-plugin.json"), "{}").unwrap();
        std::fs::write(stage.join("share/web/index.html"), "<html></html>").unwrap();
        self.pack(&stage);
    }

    fn real_archive(&self) {
        let stage = self.folder.0.join("stage");
        std::fs::copy(OBID, stage.join("bin/obid")).unwrap();
        self.pack(&stage);
    }

    fn pack(&self, stage: &Path) {
        let archive = self.folder.0.join("archive.tar.gz");
        let status = Command::new("tar")
            .arg("-czf")
            .arg(&archive)
            .arg("-C")
            .arg(stage)
            .args(["bin", "share"])
            .status()
            .unwrap();
        assert!(status.success());
    }

    fn archive_path(&self) -> PathBuf {
        self.folder.0.join("archive.tar.gz")
    }

    fn command(&self, script_name: &str) -> Command {
        let mut command = Command::new(tools_sh(&self.tools()));
        command
            .arg(script(script_name))
            .env_clear()
            .env("HOME", self.user_home())
            .env("PATH", self.tools())
            .env("TMPDIR", self.folder.0.join("tmp"))
            .stdin(Stdio::null());
        command
    }

    /// `install.sh` with the archive, not waiting for obid to answer (nothing here starts it).
    fn install(&self, args: &[&str]) -> Output {
        let mut command = self.command("install.sh");
        command
            .arg("--archive")
            .arg(self.archive_path())
            .arg("--no-wait")
            .args(args);
        command.output().unwrap()
    }

    /// `install`, by someone whose umask lets their group write what they make (Ubuntu's default
    /// for a user with a group of their own).
    fn install_with_group_umask(&self, args: &[&str]) -> Output {
        let mut command = self.command("install.sh");
        command
            .args(["--archive"])
            .arg(self.archive_path())
            .arg("--no-wait")
            .args(args);
        let mut wrapped = Command::new(tools_sh(&self.tools()));
        wrapped
            .args(["-c", "umask 002; exec \"$0\" \"$@\""])
            .arg(command.get_program())
            .args(command.get_args())
            .env_clear()
            .envs(command.get_envs().filter_map(|(k, v)| v.map(|v| (k, v))))
            .stdin(Stdio::null());
        wrapped.output().unwrap()
    }

    fn uninstall(&self, args: &[&str]) -> Output {
        self.command("install.sh")
            .arg("uninstall")
            .args(args)
            .output()
            .unwrap()
    }

    /// Where a plain install puts things.
    fn prefix(&self) -> PathBuf {
        match self.os {
            Os::Linux => self.user_home().join(".local/opt/obid"),
            Os::Mac => self
                .user_home()
                .join("Library/Application Support/Oby/obid"),
        }
    }

    fn obid_home(&self) -> PathBuf {
        match self.os {
            Os::Linux => self.user_home().join(".local/share/obid"),
            Os::Mac => self
                .user_home()
                .join("Library/Application Support/Oby/Runner"),
        }
    }

    fn config(&self) -> PathBuf {
        match self.os {
            Os::Linux => self.user_home().join(".config/obid/config.json"),
            Os::Mac => self.prefix().join("config.json"),
        }
    }

    fn unit(&self) -> PathBuf {
        self.user_home().join(".config/systemd/user/obid.service")
    }

    fn plist(&self) -> PathBuf {
        self.user_home()
            .join("Library/LaunchAgents/com.deskree.obid.plist")
    }
}

fn tools_sh(tools: &Path) -> PathBuf {
    tools.join("sh")
}

fn text(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

/// The SHA-256 of a file, in hex.
fn sha256(path: &Path) -> String {
    let out = match find_tool("sha256sum") {
        Some(tool) => Command::new(tool).arg(path).output().unwrap(),
        None => Command::new(find_tool("shasum").expect("no shasum"))
            .args(["-a", "256"])
            .arg(path)
            .output()
            .unwrap(),
    };
    assert!(out.status.success(), "{}", text(&out));
    String::from_utf8(out.stdout)
        .unwrap()
        .split_whitespace()
        .next()
        .unwrap()
        .to_string()
}

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

fn user_name() -> String {
    let out = Command::new("id").arg("-un").output().unwrap();
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

#[test]
fn without_bubblewrap_it_stops_and_says_how_to_install_it() {
    let rig = Rig::linux("no-bwrap");
    rig.remove_tool("bwrap");
    rig.stand_in("apt-get", "");
    let out = rig.install(&[]);
    assert!(!out.status.success(), "{}", text(&out));
    let said = text(&out);
    assert!(said.contains("bwrap"), "{said}");
    assert!(said.contains("sudo apt install bubblewrap"), "{said}");
    assert!(said.contains("Missing: bwrap."), "{said}");
    assert!(said.contains("sudo apt install bubblewrap\n"), "{said}");
    // Nothing was installed, started or made.
    assert!(!rig.prefix().exists());
    assert!(!rig.obid_home().exists());
    assert!(!rig.unit().exists());
    assert!(!rig.calls().contains("systemctl"));
}

#[test]
fn without_slirp4netns_it_names_the_package_for_this_distribution() {
    let rig = Rig::linux("no-slirp");
    rig.remove_tool("slirp4netns");
    rig.stand_in("dnf", "");
    let out = rig.install(&[]);
    assert!(!out.status.success(), "{}", text(&out));
    let said = text(&out);
    assert!(said.contains("sudo dnf install slirp4netns"), "{said}");
    assert!(!rig.obid_home().exists());
}

#[test]
fn without_either_it_lists_both_and_for_an_unknown_system_names_the_packages() {
    let rig = Rig::linux("no-either");
    rig.remove_tool("bwrap");
    rig.remove_tool("slirp4netns");
    let out = rig.install(&[]);
    assert!(!out.status.success(), "{}", text(&out));
    let said = text(&out);
    assert!(said.contains("bubblewrap slirp4netns"), "{said}");
}

#[test]
fn the_mac_needs_neither() {
    let rig = Rig::mac("mac-no-bwrap");
    let out = rig.install(&[]);
    assert!(out.status.success(), "{}", text(&out));
}

#[test]
fn it_makes_obids_home_and_a_private_token() {
    let rig = Rig::linux("home");
    let out = rig.install(&[]);
    assert!(out.status.success(), "{}", text(&out));
    let home = rig.obid_home();
    assert_eq!(mode(&home), 0o700);
    let token_file = home.join("api-token");
    assert_eq!(mode(&token_file), 0o600);
    let token = std::fs::read_to_string(&token_file).unwrap();
    let token = token.trim_end_matches('\n');
    assert_eq!(token.len(), 64, "{token:?}");
    assert!(token.chars().all(|c| c.is_ascii_hexdigit()));
    // The token is never printed.
    assert!(!text(&out).contains(token));

    // Running it again (an update) keeps the token.
    let again = rig.install(&[]);
    assert!(again.status.success(), "{}", text(&again));
    assert_eq!(
        std::fs::read_to_string(&token_file).unwrap().trim_end(),
        token
    );
    assert_eq!(mode(&token_file), 0o600);
}

#[test]
fn a_token_already_there_is_the_one_obid_uses() {
    let rig = Rig::linux("own-token");
    std::fs::create_dir_all(rig.obid_home()).unwrap();
    let chosen = "c".repeat(48);
    std::fs::write(rig.obid_home().join("api-token"), &chosen).unwrap();
    std::fs::set_permissions(
        rig.obid_home().join("api-token"),
        std::fs::Permissions::from_mode(0o644),
    )
    .unwrap();
    let out = rig.install(&[]);
    assert!(out.status.success(), "{}", text(&out));
    let token_file = rig.obid_home().join("api-token");
    assert_eq!(std::fs::read_to_string(&token_file).unwrap(), chosen);
    assert_eq!(mode(&token_file), 0o600);
    assert_eq!(mode(&rig.obid_home()), 0o700);
}

#[test]
fn no_secret_is_in_an_argument_an_environment_or_a_file_it_writes_besides_the_token() {
    let rig = Rig::linux("no-secret");
    let out = rig.install(&[]);
    assert!(out.status.success(), "{}", text(&out));
    let token = std::fs::read_to_string(rig.obid_home().join("api-token")).unwrap();
    let token = token.trim();
    // Every stand-in logged its arguments and its whole environment.
    assert!(rig.calls().contains("systemctl --user"), "{}", rig.calls());
    assert!(!rig.calls().contains(token), "the token reached a process");
    for file in [rig.unit(), rig.config()] {
        let written = std::fs::read_to_string(&file).unwrap();
        assert!(!written.contains(token), "{}", file.display());
    }
    // And on the Mac, in the property list.
    let mac = Rig::mac("no-secret-mac");
    let out = mac.install(&[]);
    assert!(out.status.success(), "{}", text(&out));
    let token = std::fs::read_to_string(mac.obid_home().join("api-token")).unwrap();
    let token = token.trim();
    assert!(!mac.calls().contains(token));
    assert!(
        !std::fs::read_to_string(mac.plist())
            .unwrap()
            .contains(token)
    );
    assert!(!mac.calls().is_empty());
}

#[test]
fn it_refuses_to_run_with_the_token_in_its_environment() {
    let rig = Rig::linux("env-token");
    let mut command = rig.command("install.sh");
    command
        .arg("--archive")
        .arg(rig.archive_path())
        .arg("--no-wait")
        .env("OBID_API_TOKEN", "x".repeat(40));
    let out = command.output().unwrap();
    assert!(!out.status.success());
    let said = text(&out);
    assert!(said.contains("home/api-token"), "{said}");
    assert!(!said.contains(&"x".repeat(40)));
    assert!(!rig.obid_home().exists());
}

#[test]
fn the_systemd_unit_runs_obid_serve_with_the_config_and_survives_a_reboot() {
    let rig = Rig::linux("unit");
    let out = rig.install(&[]);
    assert!(out.status.success(), "{}", text(&out));
    let unit = std::fs::read_to_string(rig.unit()).unwrap();
    let lines: Vec<&str> = unit.lines().filter(|l| !l.starts_with('#')).collect();
    let exec = format!(
        "ExecStart=\"{}/bin/obid\" serve --config \"{}\"",
        rig.prefix().display(),
        rig.config().display()
    );
    assert!(lines.contains(&exec.as_str()), "{unit}");
    assert!(lines.contains(&"Restart=on-failure"), "{unit}");
    assert!(lines.contains(&"WantedBy=default.target"), "{unit}");
    assert!(lines.contains(&"UnsetEnvironment=OBID_API_TOKEN"), "{unit}");
    assert!(lines.contains(&"KillMode=control-group"), "{unit}");
    // Nothing is set in its environment, and no secret is named.
    assert!(!unit.contains("Environment=OBID_API_TOKEN="), "{unit}");
    assert!(
        !lines.iter().any(|l| l.starts_with("Environment=")),
        "{unit}"
    );
    assert!(
        !unit.contains("User="),
        "a user unit runs as its user: {unit}"
    );
    // It was started and enabled, and lingering keeps it across a reboot with nobody logged in.
    let calls = rig.calls();
    assert!(
        calls.contains("systemctl --user enable --now obid.service"),
        "{calls}"
    );
    assert!(
        calls.contains(&format!("loginctl enable-linger {}", user_name())),
        "{calls}"
    );
    // systemd itself accepts the file, where there is a systemd to ask.
    if let Some(analyze) = find_tool("systemd-analyze") {
        let check = Command::new(analyze)
            .args(["--user", "verify"])
            .arg(rig.unit())
            .output()
            .unwrap();
        assert!(check.status.success(), "{}", text(&check));
    }
}

#[test]
fn when_lingering_cant_be_turned_on_it_says_the_command_and_still_installs() {
    let rig = Rig::linux("linger");
    rig.stand_in("loginctl", "exit 1");
    let out = rig.install(&[]);
    assert!(out.status.success(), "{}", text(&out));
    assert!(
        text(&out).contains("sudo loginctl enable-linger"),
        "{}",
        text(&out)
    );
}

#[test]
fn the_configuration_it_writes_is_obids_defaults() {
    let rig = Rig::linux("config");
    let out = rig.install(&[]);
    assert!(out.status.success(), "{}", text(&out));
    let config = Config::load(&rig.config()).unwrap();
    assert_eq!(config.listen.to_string(), "127.0.0.1:7777");
    assert_eq!(config.home, rig.obid_home());
    assert_eq!(config.owner, user_name());
    assert!(!config.telemetry);
    assert_eq!(config.bundled_plugins, rig.prefix().join("share/plugins"));
    assert_eq!(config.web, rig.prefix().join("share/web"));
    let claude = config.agents.claude.expect("Claude Code is configured");
    assert_eq!(claude.bin, "claude");
    assert_eq!(claude.accounts.len(), 1);
    assert_eq!(claude.accounts[0].config_dir, None);
    assert!(config.agents.cursor.is_none());
    // The plug-ins and the web app obid ships are where the configuration says.
    assert!(
        rig.prefix()
            .join("share/plugins/demo/obi-plugin.json")
            .is_file()
    );
    assert!(rig.prefix().join("share/web/index.html").is_file());
    assert_eq!(mode(&rig.prefix().join("bin/obid")), 0o755);
}

#[test]
fn owner_listen_and_home_can_be_chosen_and_are_checked() {
    let rig = Rig::linux("choose");
    let home = rig.folder.0.join("srv/obid");
    let out = rig.install(&[
        "--owner",
        "wellington",
        "--listen",
        "127.0.0.1:7811",
        "--home",
        home.to_str().unwrap(),
    ]);
    assert!(out.status.success(), "{}", text(&out));
    let config = Config::load(&rig.config()).unwrap();
    assert_eq!(config.owner, "wellington");
    assert_eq!(config.listen.to_string(), "127.0.0.1:7811");
    assert_eq!(config.home, home);
    assert_eq!(mode(&home), 0o700);
    assert!(home.join("api-token").is_file());

    // Not an address obid would bind, not an absolute path, and not a name that would break the
    // files the installer writes: refused before anything is made.
    let other = Rig::linux("choose-bad");
    for args in [
        vec!["--listen", "0.0.0.0:7777"],
        vec!["--home", "relative/home"],
        vec!["--home", "/tmp/with\"quote"],
        vec!["--owner", "a\"b"],
        vec!["--prefix", "/tmp/a&b"],
    ] {
        let out = other.install(&args);
        assert!(!out.status.success(), "{args:?}: {}", text(&out));
    }
    assert!(!other.obid_home().exists());
    assert!(!other.prefix().exists());
}

#[test]
fn an_update_keeps_the_configuration_the_owner_edited() {
    let rig = Rig::linux("update");
    assert!(rig.install(&[]).status.success());
    let edited = std::fs::read_to_string(rig.config())
        .unwrap()
        .replace("\"telemetry\": false", "\"telemetry\": true");
    std::fs::write(rig.config(), &edited).unwrap();
    rig.archive("#!/bin/sh\ncase \"$1\" in --version) echo \"obid 10.0.0-test\" ;; esac\n");
    let out = rig.install(&["--owner", "someone-else"]);
    assert!(out.status.success(), "{}", text(&out));
    assert_eq!(std::fs::read_to_string(rig.config()).unwrap(), edited);
    // The new obid is in place and the service was stopped for it and started again.
    let installed = Command::new(rig.prefix().join("bin/obid"))
        .arg("--version")
        .output()
        .unwrap();
    assert!(String::from_utf8_lossy(&installed.stdout).contains("10.0.0-test"));
    let calls = rig.calls();
    assert!(
        calls.contains("systemctl --user disable --now obid.service"),
        "{calls}"
    );
}

#[test]
fn the_mac_gets_a_launch_agent_in_the_home_the_mac_app_reads() {
    let rig = Rig::mac("mac");
    let out = rig.install(&[]);
    assert!(out.status.success(), "{}", text(&out));
    // The folder docs/runner-api.md names for This Mac, and the token the app discovers there.
    let home = rig.obid_home();
    assert!(home.ends_with("Library/Application Support/Oby/Runner"));
    assert_eq!(mode(&home), 0o700);
    assert_eq!(mode(&home.join("api-token")), 0o600);
    let config = Config::load(&rig.config()).unwrap();
    assert_eq!(config.listen.to_string(), "127.0.0.1:7777");
    assert_eq!(config.home, home);
    let plist = std::fs::read_to_string(rig.plist()).unwrap();
    assert!(
        plist.contains("<key>Label</key>\n\t<string>com.deskree.obid</string>"),
        "{plist}"
    );
    for part in [
        format!("<string>{}/bin/obid</string>", rig.prefix().display()),
        "<string>serve</string>".to_string(),
        "<string>--config</string>".to_string(),
        format!("<string>{}</string>", rig.config().display()),
        "<key>RunAtLoad</key>\n\t<true/>".to_string(),
        "<key>SuccessfulExit</key>\n\t\t<false/>".to_string(),
    ] {
        assert!(plist.contains(&part), "{part}\n{plist}");
    }
    assert!(!plist.contains("EnvironmentVariables"), "{plist}");
    // Its log, where obid's output goes, is the owner's alone.
    assert_eq!(mode(&rig.user_home().join("Library/Logs/obid.log")), 0o600);
    let calls = rig.calls();
    assert!(
        calls.contains(&format!("launchctl bootstrap gui/{} ", unsafe_uid())),
        "{calls}"
    );
    assert!(!calls.contains("systemctl"), "{calls}");
    // plutil, where there is one, reads the file.
    if let Some(plutil) = find_tool("plutil") {
        let lint = Command::new(plutil)
            .arg("-lint")
            .arg(rig.plist())
            .output()
            .unwrap();
        assert!(lint.status.success(), "{}", text(&lint));
    }
}

fn unsafe_uid() -> String {
    let out = Command::new("id").arg("-u").output().unwrap();
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

#[test]
fn a_download_is_checked_against_its_checksum() {
    let rig = Rig::linux("download");
    let served = rig.folder.0.join("served");
    std::fs::create_dir_all(&served).unwrap();
    let name = format!("obid-{}.tar.gz", rig.target());
    std::fs::copy(rig.archive_path(), served.join(&name)).unwrap();
    let digest = sha256(&served.join(&name));
    std::fs::write(
        served.join(format!("{name}.sha256")),
        format!("{digest}  {name}\n"),
    )
    .unwrap();
    // `curl -fsSL -o FILE URL` copies what the URL names from the folder.
    rig.stand_in(
        "curl",
        &format!(
            "while [ $# -gt 0 ]; do case \"$1\" in -o) out=\"$2\"; shift 2 ;; -*) shift ;; *) url=\"$1\"; shift ;; esac; done\n\
             cp '{}'/\"$(basename \"$url\")\" \"$out\"",
            served.display()
        ),
    );
    write_executable(
        &rig.tools().join("basename"),
        "#!/bin/sh\necho \"${1##*/}\"\n",
    );
    let run = |rig: &Rig| {
        rig.command("install.sh")
            .args(["--from", "https://example.invalid/obid", "--no-wait"])
            .output()
            .unwrap()
    };
    // A file that isn't the one the checksum is for installs nothing.
    std::fs::write(
        served.join(format!("{name}.sha256")),
        format!("{}  {name}\n", "0".repeat(64)),
    )
    .unwrap();
    let bad = run(&rig);
    assert!(!bad.status.success(), "{}", text(&bad));
    assert!(text(&bad).contains("checksum"), "{}", text(&bad));
    assert!(!rig.prefix().exists());
    assert!(!rig.obid_home().exists());
    assert!(!rig.unit().exists());

    std::fs::write(
        served.join(format!("{name}.sha256")),
        format!("{digest}  {name}\n"),
    )
    .unwrap();
    let good = run(&rig);
    assert!(good.status.success(), "{}", text(&good));
    assert!(rig.prefix().join("bin/obid").is_file());
    assert!(rig.calls().contains("curl -fsSL -o"), "{}", rig.calls());
    assert!(
        rig.calls()
            .contains(&format!("https://example.invalid/obid/{name}"))
    );
}

#[test]
fn an_archive_with_a_wrong_checksum_given_by_hand_installs_nothing() {
    let rig = Rig::linux("sha-by-hand");
    let out = rig.install(&["--sha256", &"1".repeat(64)]);
    assert!(!out.status.success(), "{}", text(&out));
    assert!(!rig.prefix().exists());
    assert!(!rig.obid_home().exists());
}

#[test]
fn an_archive_without_obid_in_it_installs_nothing() {
    let rig = Rig::linux("empty-archive");
    let stage = rig.folder.0.join("empty");
    std::fs::create_dir_all(stage.join("share")).unwrap();
    let archive = rig.archive_path();
    let status = Command::new("tar")
        .arg("-czf")
        .arg(&archive)
        .arg("-C")
        .arg(&stage)
        .arg("share")
        .status()
        .unwrap();
    assert!(status.success());
    let out = rig.install(&[]);
    assert!(!out.status.success(), "{}", text(&out));
    assert!(text(&out).contains("no bin/obid"), "{}", text(&out));
    assert!(!rig.obid_home().exists());
}

#[test]
fn uninstalling_stops_the_service_removes_it_and_keeps_the_owners_data() {
    let rig = Rig::linux("uninstall");
    assert!(rig.install(&[]).status.success());
    let token = std::fs::read_to_string(rig.obid_home().join("api-token")).unwrap();
    let out = rig.uninstall(&[]);
    assert!(out.status.success(), "{}", text(&out));
    assert!(!rig.unit().exists());
    assert!(!rig.prefix().exists(), "{:?}", rig.prefix());
    assert!(
        rig.calls()
            .contains("systemctl --user disable --now obid.service")
    );
    // The jobs, the clones and the token stay, and so does the configuration.
    assert_eq!(
        std::fs::read_to_string(rig.obid_home().join("api-token")).unwrap(),
        token
    );
    assert!(rig.config().is_file());
    assert!(text(&out).contains("--purge"), "{}", text(&out));
}

#[test]
fn purging_deletes_what_the_configuration_names_and_nothing_else() {
    let rig = Rig::linux("purge");
    let home = rig.folder.0.join("srv/obid");
    assert!(
        rig.install(&["--home", home.to_str().unwrap()])
            .status
            .success()
    );
    std::fs::create_dir_all(home.join("worktrees/job-1")).unwrap();
    let neighbour = rig.folder.0.join("srv/other");
    std::fs::create_dir_all(&neighbour).unwrap();
    // The next uninstall is given no --home: the configuration says where it is.
    let out = rig.uninstall(&["--purge"]);
    assert!(out.status.success(), "{}", text(&out));
    assert!(!home.exists());
    assert!(!rig.config().exists());
    assert!(!rig.prefix().exists());
    assert!(neighbour.is_dir());
    assert!(
        text(&out).contains(home.to_str().unwrap()),
        "{}",
        text(&out)
    );
}

#[test]
fn the_mac_uninstall_boots_the_agent_out_and_removes_it() {
    let rig = Rig::mac("mac-uninstall");
    assert!(rig.install(&[]).status.success());
    assert!(rig.plist().is_file());
    let out = rig.uninstall(&[]);
    assert!(out.status.success(), "{}", text(&out));
    assert!(!rig.plist().exists());
    assert!(rig.calls().contains(&format!(
        "launchctl bootout gui/{}/com.deskree.obid",
        unsafe_uid()
    )));
    assert!(!rig.prefix().join("bin").exists());
    // The Mac's configuration lives in the same folder, and stays.
    assert!(rig.config().is_file());
    assert!(rig.obid_home().join("api-token").is_file());
}

#[test]
fn a_second_obid_installs_beside_the_first_under_its_own_service_name() {
    let rig = Rig::linux("service");
    assert!(rig.install(&[]).status.success());
    let first_unit = std::fs::read_to_string(rig.unit()).unwrap();
    let first_config = std::fs::read_to_string(rig.config()).unwrap();
    let first_token = std::fs::read_to_string(rig.obid_home().join("api-token")).unwrap();

    let scratch = rig.folder.0.join("scratch");
    let (prefix, home, config) = (
        scratch.join("opt"),
        scratch.join("home"),
        scratch.join("etc/config.json"),
    );
    let args = [
        "--service",
        "obid-test-585",
        "--prefix",
        prefix.to_str().unwrap(),
        "--home",
        home.to_str().unwrap(),
        "--config",
        config.to_str().unwrap(),
        "--listen",
        "127.0.0.1:7895",
    ];
    // A folder of the prefix's that an earlier install left open to the group.
    std::fs::create_dir_all(prefix.join("bin")).unwrap();
    std::fs::set_permissions(prefix.join("bin"), std::fs::Permissions::from_mode(0o775)).unwrap();
    let out = rig.install_with_group_umask(&args);
    assert!(out.status.success(), "{}", text(&out));
    let unit = rig
        .user_home()
        .join(".config/systemd/user/obid-test-585.service");
    let written = std::fs::read_to_string(&unit).unwrap();
    // What runs as the owner is theirs alone to change, whatever their umask.
    assert_eq!(mode(&unit), 0o644);
    assert_eq!(mode(&prefix.join("bin/obid")), 0o755);
    assert_eq!(mode(&prefix.join("bin")), 0o755);
    assert_eq!(mode(&prefix.join("share/plugins")), 0o755);
    assert!(
        written.contains(&format!(
            "ExecStart=\"{}/bin/obid\" serve --config \"{}\"",
            prefix.display(),
            config.display()
        )),
        "{written}"
    );
    let loaded = Config::load(&config).unwrap();
    assert_eq!(loaded.home, home);
    assert_eq!(loaded.listen.to_string(), "127.0.0.1:7895");
    assert_eq!(mode(&home.join("api-token")), 0o600);
    assert!(
        rig.calls()
            .contains("systemctl --user enable --now obid-test-585.service"),
        "{}",
        rig.calls()
    );

    // Removing it, named the same way, leaves the first one exactly as it was.
    let removed = rig.uninstall(&[
        "--service",
        "obid-test-585",
        "--prefix",
        prefix.to_str().unwrap(),
        "--config",
        config.to_str().unwrap(),
        "--purge",
    ]);
    assert!(removed.status.success(), "{}", text(&removed));
    assert!(!unit.exists());
    assert!(!home.exists());
    assert!(!config.exists());
    assert!(!prefix.exists());
    assert_eq!(std::fs::read_to_string(rig.unit()).unwrap(), first_unit);
    assert_eq!(std::fs::read_to_string(rig.config()).unwrap(), first_config);
    assert_eq!(
        std::fs::read_to_string(rig.obid_home().join("api-token")).unwrap(),
        first_token
    );
    assert!(rig.prefix().join("bin/obid").is_file());
    let calls = rig.calls();
    assert!(
        calls.contains("systemctl --user disable --now obid-test-585.service"),
        "{calls}"
    );
    assert!(
        !calls.contains("disable --now obid.service"),
        "the first obid was stopped: {calls}"
    );

    // A name that would break the unit's file name or a property list is refused.
    for name in ["../obid", "a b", ".hidden", "a/b"] {
        let out = rig.install(&["--service", name, "--prefix", prefix.to_str().unwrap()]);
        assert!(!out.status.success(), "{name}: {}", text(&out));
    }
    assert!(!prefix.exists());
}

#[test]
fn a_test_launch_agent_on_the_mac_never_names_the_real_one() {
    let rig = Rig::mac("mac-service");
    let scratch = rig.folder.0.join("scratch");
    let (prefix, home) = (scratch.join("opt"), scratch.join("home"));
    let label = "com.deskree.obid.test-585";
    let out = rig.install_with_group_umask(&[
        "--service",
        label,
        "--prefix",
        prefix.to_str().unwrap(),
        "--home",
        home.to_str().unwrap(),
        "--listen",
        "127.0.0.1:7895",
    ]);
    assert!(out.status.success(), "{}", text(&out));
    let plist_path = rig
        .user_home()
        .join(format!("Library/LaunchAgents/{label}.plist"));
    let plist = std::fs::read_to_string(&plist_path).unwrap();
    assert_eq!(mode(&plist_path), 0o644);
    assert!(
        plist.contains(&format!("<key>Label</key>\n\t<string>{label}</string>")),
        "{plist}"
    );
    let log = rig.user_home().join(format!("Library/Logs/{label}.log"));
    assert!(
        plist.contains(&format!("<string>{}</string>", log.display())),
        "{plist}"
    );
    // The config is in the prefix, and points at the scratch home.
    let config = Config::load(&prefix.join("config.json")).unwrap();
    assert_eq!(config.home, home);
    // Nothing of the real install was made or called.
    assert!(!rig.plist().exists());
    assert!(!rig.prefix().exists());
    assert!(!rig.obid_home().exists());
    let uid = unsafe_uid();
    let calls = rig.calls();
    assert!(
        calls.contains(&format!(
            "launchctl bootstrap gui/{uid} {}",
            plist_path.display()
        )),
        "{calls}"
    );
    assert!(
        !calls.contains(&format!("gui/{uid}/com.deskree.obid\n")),
        "{calls}"
    );

    let out = rig.uninstall(&["--service", label, "--prefix", prefix.to_str().unwrap()]);
    assert!(out.status.success(), "{}", text(&out));
    assert!(!plist_path.exists());
    let calls = rig.calls();
    assert!(
        calls.contains(&format!("launchctl bootout gui/{uid}/{label}")),
        "{calls}"
    );
    assert!(
        !calls
            .lines()
            .any(|l| l == format!("launchctl bootout gui/{uid}/com.deskree.obid")),
        "{calls}"
    );
}

#[test]
fn a_configuration_already_there_decides_the_home_and_the_port() {
    // An obid set up by hand before the installer: its config.json names its own home and port.
    let rig = Rig::mac("existing-config");
    let own_home = rig
        .user_home()
        .join("Library/Application Support/Oby/obid/home");
    std::fs::create_dir_all(rig.prefix()).unwrap();
    let edited = format!(
        "{{\"listen\": \"127.0.0.1:7811\", \"home\": \"{}\", \"owner\": \"someone\"}}\n",
        own_home.display()
    );
    std::fs::write(rig.config(), &edited).unwrap();
    let out = rig.install(&[]);
    assert!(out.status.success(), "{}", text(&out));
    // The token is made where that obid will look for it, not in the default home.
    assert_eq!(mode(&own_home.join("api-token")), 0o600);
    assert!(!rig.obid_home().exists(), "a second home was made");
    assert_eq!(std::fs::read_to_string(rig.config()).unwrap(), edited);
    assert!(text(&out).contains("127.0.0.1:7811"), "{}", text(&out));

    // An option that contradicts it stops the install before anything changes.
    let token = std::fs::read_to_string(own_home.join("api-token")).unwrap();
    let elsewhere = rig.folder.0.join("elsewhere");
    for args in [
        vec!["--home", elsewhere.to_str().unwrap()],
        vec!["--listen", "127.0.0.1:7777"],
    ] {
        let calls_before = rig.calls();
        let out = rig.install(&args);
        assert!(!out.status.success(), "{args:?}: {}", text(&out));
        assert!(text(&out).contains(rig.config().to_str().unwrap()));
        assert_eq!(
            rig.calls(),
            calls_before,
            "{args:?}: the service was touched"
        );
    }
    assert!(!elsewhere.exists());
    assert_eq!(
        std::fs::read_to_string(own_home.join("api-token")).unwrap(),
        token
    );
}

#[test]
fn purging_never_deletes_a_home_the_swift_runner_keeps_its_data_in() {
    // On a Mac the This Mac home can be the Swift runner's folder too.
    let rig = Rig::mac("purge-shared");
    assert!(rig.install(&[]).status.success());
    std::fs::write(rig.obid_home().join("oby.sqlite"), "the Swift runner's").unwrap();
    let calls_before = rig.calls();
    let out = rig.uninstall(&["--purge"]);
    assert!(!out.status.success(), "{}", text(&out));
    assert!(text(&out).contains("oby.sqlite"), "{}", text(&out));
    assert_eq!(
        std::fs::read_to_string(rig.obid_home().join("oby.sqlite")).unwrap(),
        "the Swift runner's"
    );
    assert!(rig.obid_home().join("api-token").is_file());
    // It stopped before anything: the agent is still loaded and installed.
    assert_eq!(rig.calls(), calls_before);
    assert!(rig.plist().is_file());
    assert!(rig.prefix().join("bin/obid").is_file());
}

/// Ends a process on drop, so a failed test leaves none behind.
struct Process(std::process::Child);

impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn uninstalling_ends_whatever_of_obids_is_still_running() {
    let rig = Rig::linux("leftovers");
    rig.real_archive();
    let port = free_port();
    assert!(
        rig.install(&["--listen", &format!("127.0.0.1:{port}")])
            .status
            .success()
    );
    // An obid the service manager didn't take with it (its stand-in stops nothing): the
    // installed binary, running.
    let mut leftover = Process(
        Command::new(rig.prefix().join("bin/obid"))
            .args(["serve", "--config"])
            .arg(rig.config())
            .env_clear()
            .env("HOME", rig.user_home())
            .env("PATH", rig.tools())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    wait_until_listening(port, &mut leftover);
    let out = rig.uninstall(&[]);
    assert!(out.status.success(), "{}", text(&out));
    let status = leftover.0.try_wait().unwrap();
    assert!(status.is_some(), "obid is still running after uninstall");
}

fn wait_until_listening(port: u16, process: &mut Process) {
    let start = std::time::Instant::now();
    while start.elapsed() < std::time::Duration::from_secs(20) {
        assert!(process.0.try_wait().unwrap().is_none(), "obid stopped");
        if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    panic!("obid didn't start");
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// The whole path with the real obid: the installer starts the service (the stand-in runs the
/// unit's `ExecStart`), asks obid who it is with the token it made, and obid answers `engine`
/// `obid`.
#[test]
fn the_installed_service_starts_and_answers_with_the_token_the_installer_made() {
    let Some(curl) = find_tool("curl") else {
        eprintln!("no curl on this machine: skipped");
        return;
    };
    let rig = Rig::linux("e2e");
    rig.real_archive();
    std::os::unix::fs::symlink(curl, rig.tools().join("curl")).unwrap();
    let pid = rig.folder.0.join("obid.pid");
    rig.stand_in(
        "systemctl",
        &format!(
            "case \"$*\" in *enable*--now*) \
             line=$(grep '^ExecStart=' \"$HOME/.config/systemd/user/obid.service\"); \
             eval \"${{line#ExecStart=}} >/dev/null 2>&1 &\"; echo $! > '{}' ;; esac",
            pid.display()
        ),
    );
    let port = free_port();
    let mut command = rig.command("install.sh");
    command
        .arg("--archive")
        .arg(rig.archive_path())
        .args(["--listen", &format!("127.0.0.1:{port}")]);
    let out = command.output().unwrap();
    let pid_text = std::fs::read_to_string(&pid).unwrap_or_default();
    struct Kill(String);
    impl Drop for Kill {
        fn drop(&mut self) {
            if !self.0.is_empty() {
                let _ = Command::new("kill").arg(self.0.trim()).status();
            }
        }
    }
    let _kill = Kill(pid_text);
    assert!(out.status.success(), "{}", text(&out));
    assert!(text(&out).contains(&format!("http://127.0.0.1:{port}")));
    let token = std::fs::read_to_string(rig.obid_home().join("api-token")).unwrap();
    assert!(!text(&out).contains(token.trim()));
}

#[test]
fn the_packager_builds_the_archive_the_installer_reads() {
    let folder = Folder::new("package");
    let bin = folder.0.join("obid");
    write_executable(&bin, "#!/bin/sh\necho \"obid 1.2.3\"\n");
    let plugins = folder.0.join("plugins");
    std::fs::create_dir_all(plugins.join("one")).unwrap();
    std::fs::write(plugins.join("one/obi-plugin.json"), "{}").unwrap();
    let web = folder.0.join("dist");
    std::fs::create_dir_all(&web).unwrap();
    std::fs::write(web.join("index.html"), "<html></html>").unwrap();
    let out_dir = folder.0.join("out");
    let run = |web: &Path| {
        Command::new("sh")
            .arg(script("package.sh"))
            .arg("--bin")
            .arg(&bin)
            .arg("--plugins")
            .arg(&plugins)
            .arg("--web")
            .arg(web)
            .arg("--out")
            .arg(&out_dir)
            .args(["--target", "linux-x86_64"])
            .env("TMPDIR", folder.0.join("tmp"))
            .output()
            .unwrap()
    };
    std::fs::create_dir_all(folder.0.join("tmp")).unwrap();
    let out = run(&web);
    assert!(out.status.success(), "{}", text(&out));
    let archive = out_dir.join("obid-linux-x86_64.tar.gz");
    assert_eq!(
        String::from_utf8_lossy(&out.stdout).trim(),
        archive.to_str().unwrap()
    );
    let listing = Command::new("tar")
        .arg("-tzf")
        .arg(&archive)
        .output()
        .unwrap();
    let listing = String::from_utf8(listing.stdout).unwrap();
    for entry in [
        "bin/obid",
        "share/plugins/one/obi-plugin.json",
        "share/web/index.html",
    ] {
        assert!(
            listing.lines().any(|l| l.trim_start_matches("./") == entry),
            "{entry}\n{listing}"
        );
    }
    // Its checksum file is the one the installer reads.
    let sums = std::fs::read_to_string(out_dir.join("obid-linux-x86_64.tar.gz.sha256")).unwrap();
    assert_eq!(
        sums.split_whitespace().next(),
        Some(sha256(&archive).as_str())
    );
    assert!(sums.trim_end().ends_with("obid-linux-x86_64.tar.gz"));

    // Without a built web app it still packs, and says so.
    let none = run(&folder.0.join("missing-dist"));
    assert!(none.status.success(), "{}", text(&none));
    assert!(text(&none).contains("no web app"), "{}", text(&none));
    let listing = Command::new("tar")
        .arg("-tzf")
        .arg(&archive)
        .output()
        .unwrap();
    assert!(
        !String::from_utf8(listing.stdout)
            .unwrap()
            .contains("share/web")
    );
}
