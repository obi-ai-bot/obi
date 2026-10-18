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
    "rmdir", "mktemp", "id", "dirname", "grep", "sleep", "pgrep", "kill", "stat", "env",
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
        self.command_for(&script(script_name))
    }

    /// The given script under this machine's `sh`, `HOME`, `PATH` and `TMPDIR`.
    fn command_for(&self, script: &Path) -> Command {
        let mut command = Command::new(tools_sh(&self.tools()));
        command
            .arg(script)
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
    let claude = config
        .agents
        .get()
        .claude
        .expect("Claude Code is configured");
    assert_eq!(claude.bin, "claude");
    assert_eq!(claude.accounts.len(), 1);
    assert_eq!(claude.accounts[0].config_dir, None);
    assert!(config.agents.get().cursor.is_none());
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
    // `curl … -o FILE URL` copies what the URL names from the folder.
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
    // Over https only, redirects included (R3).
    assert!(
        rig.calls()
            .contains("curl -q -fsSL --proto =https --proto-redir =https -o"),
        "{}",
        rig.calls()
    );
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

/// The installed service, started for real: the `systemctl` stand-in runs the unit's `ExecStart`
/// in the background and writes its pid down. Ends it on drop.
struct RealService {
    pid: PathBuf,
}

impl RealService {
    fn new(rig: &Rig) -> RealService {
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
        RealService { pid }
    }
}

impl Drop for RealService {
    fn drop(&mut self) {
        if let Ok(pid) = std::fs::read_to_string(&self.pid) {
            let _ = Command::new("kill").arg(pid.trim()).status();
        }
    }
}

/// R1: curl sends even 127.0.0.1 through `http_proxy`, so the readiness check would hand the
/// token to whatever the proxy is.
#[test]
fn the_token_never_goes_through_a_proxy() {
    let Some(curl) = find_tool("curl") else {
        eprintln!("no curl on this machine: skipped");
        return;
    };
    let rig = Rig::linux("proxy");
    rig.real_archive();
    std::os::unix::fs::symlink(curl, rig.tools().join("curl")).unwrap();
    let _service = RealService::new(&rig);
    // A proxy that writes down every byte it is sent and answers nothing.
    let proxy = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let proxy_url = format!("http://{}", proxy.local_addr().unwrap());
    proxy.set_nonblocking(true).unwrap();
    let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::<u8>::new()));
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let listener = {
        let (seen, stop) = (seen.clone(), stop.clone());
        std::thread::spawn(move || {
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                match proxy.accept() {
                    Ok((mut stream, _)) => {
                        use std::io::Read;
                        stream.set_nonblocking(false).unwrap();
                        stream
                            .set_read_timeout(Some(std::time::Duration::from_millis(300)))
                            .unwrap();
                        let mut buf = [0u8; 4096];
                        let n = stream.read(&mut buf).unwrap_or(0);
                        seen.lock().unwrap().extend_from_slice(&buf[..n]);
                        seen.lock().unwrap().extend_from_slice(b"<connection>");
                    }
                    Err(_) => std::thread::sleep(std::time::Duration::from_millis(20)),
                }
            }
        })
    };
    let port = free_port();
    let mut command = rig.command("install.sh");
    command
        .arg("--archive")
        .arg(rig.archive_path())
        .args(["--listen", &format!("127.0.0.1:{port}")]);
    for name in ["http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"] {
        command.env(name, &proxy_url);
    }
    let out = command.output().unwrap();
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    listener.join().unwrap();
    let seen = String::from_utf8_lossy(&seen.lock().unwrap()).to_string();
    assert!(seen.is_empty(), "the proxy was sent: {seen}");
    assert!(out.status.success(), "{}", text(&out));
    assert!(text(&out).contains("obid is running"), "{}", text(&out));
}

/// R2: --purge deletes only a folder that is obid's home, judged where it really is.
#[test]
fn purging_refuses_a_folder_that_isnt_obids_home_wherever_it_points() {
    // Your home folder, named through `..`, with an api-token in it.
    let rig = Rig::linux("purge-dotdot");
    let user = rig.user_home();
    std::fs::write(user.join("api-token"), "a".repeat(64)).unwrap();
    std::fs::write(user.join("keep.txt"), "mine").unwrap();
    let dotdot = format!("{}/../user", user.display());
    let out = rig.uninstall(&["--purge", "--home", &dotdot]);
    assert!(!out.status.success(), "{}", text(&out));
    assert!(text(&out).contains("Nothing was removed"), "{}", text(&out));
    assert_eq!(
        std::fs::read_to_string(user.join("keep.txt")).unwrap(),
        "mine"
    );

    // A folder that holds your home folder.
    let parent = rig.folder.0.clone();
    std::fs::write(parent.join("api-token"), "a".repeat(64)).unwrap();
    let out = rig.uninstall(&["--purge", "--home", parent.to_str().unwrap()]);
    assert!(!out.status.success(), "{}", text(&out));
    assert!(user.join("keep.txt").is_file());
    assert!(rig.tools().join("sh").exists());

    // A configuration whose home is a folder of yours with no token in it.
    let rig = Rig::linux("purge-projects");
    let projects = rig.user_home().join("Projects");
    std::fs::create_dir_all(projects.join("app")).unwrap();
    std::fs::write(projects.join("app/main.rs"), "fn main() {}").unwrap();
    std::fs::create_dir_all(rig.config().parent().unwrap()).unwrap();
    std::fs::write(
        rig.config(),
        format!(
            "{{\"listen\": \"127.0.0.1:7777\", \"home\": \"{}\", \"owner\": \"me\"}}\n",
            projects.display()
        ),
    )
    .unwrap();
    let out = rig.uninstall(&["--purge"]);
    assert!(!out.status.success(), "{}", text(&out));
    assert!(text(&out).contains("no api-token"), "{}", text(&out));
    assert!(projects.join("app/main.rs").is_file());
    assert!(rig.config().is_file());

    // A link to obid's home: what it points at goes, checked there.
    let rig = Rig::linux("purge-link");
    let real = rig.folder.0.join("disk/obid");
    assert!(
        rig.install(&["--home", real.to_str().unwrap()])
            .status
            .success()
    );
    let out = rig.uninstall(&["--purge"]);
    assert!(out.status.success(), "{}", text(&out));
    assert!(!real.exists());
}

/// R4: anything but 127.0.0.1 and a port from 1 to 65535 is refused, before anything is made.
#[test]
fn listen_takes_only_127_0_0_1_and_a_port() {
    let rig = Rig::linux("listen");
    for listen in [
        "127.0.0.1:7@evil.example",
        "127.0.0.1:7777x",
        "127.0.0.1:7777\", \"owner\": \"x",
        "127.0.0.1:",
        "127.0.0.1:0",
        "127.0.0.1:07777",
        "127.0.0.1:65536",
        "127.0.0.1:123456",
        "127.0.0.2:7777",
    ] {
        let out = rig.install(&["--listen", listen]);
        assert!(!out.status.success(), "{listen}: {}", text(&out));
        assert!(
            text(&out).contains("1 to 65535"),
            "{listen}: {}",
            text(&out)
        );
    }
    assert!(!rig.prefix().exists());
    assert!(!rig.obid_home().exists());
    for listen in ["127.0.0.1:1", "127.0.0.1:65535"] {
        let out = rig.install(&["--listen", listen]);
        assert!(out.status.success(), "{listen}: {}", text(&out));
        assert_eq!(
            Config::load(&rig.config()).unwrap().listen.to_string(),
            listen
        );
        std::fs::remove_file(rig.config()).unwrap();
    }
}

/// R5: root with another user's HOME (`sudo -E`) is refused before anything is written.
#[test]
fn root_with_someone_elses_home_is_refused() {
    let rig = Rig::linux("root");
    rig.remove_tool("id");
    write_executable(
        &rig.tools().join("id"),
        "#!/bin/sh\ncase \"$1\" in -u) echo 0 ;; -un) echo root ;; esac\n",
    );
    // HOME belongs to whoever runs the tests, not to root.
    let out = rig.install(&[]);
    assert!(!out.status.success(), "{}", text(&out));
    assert!(text(&out).contains("as root"), "{}", text(&out));
    assert!(!rig.prefix().exists());
    assert!(!rig.obid_home().exists());
    assert!(rig.calls().is_empty(), "{}", rig.calls());
}

/// R6: `curl | sh` with the download cut short runs none of it.
#[test]
fn a_script_cut_short_runs_nothing() {
    let rig = Rig::linux("cut");
    let whole = std::fs::read_to_string(script("install.sh")).unwrap();
    let lines: Vec<&str> = whole.lines().collect();
    for tenth in 1..10 {
        let cut = lines.len() * tenth / 10;
        let part = rig.folder.0.join(format!("install-{tenth}.sh"));
        std::fs::write(&part, lines[..cut].join("\n") + "\n").unwrap();
        let out = rig
            .command_for(&part)
            .arg("--archive")
            .arg(rig.archive_path())
            .arg("--no-wait")
            .output()
            .unwrap();
        assert!(
            !rig.prefix().exists() && !rig.obid_home().exists() && !rig.unit().exists(),
            "cut at line {cut} of {}: {}",
            lines.len(),
            text(&out)
        );
        assert!(rig.calls().is_empty(), "cut at line {cut}: {}", rig.calls());
    }
}

/// R7: a `.new` left by a run cut short is never written through: not its mode, not its link.
#[test]
fn a_leftover_new_file_is_never_written_through() {
    let rig = Rig::linux("leftover-new");
    std::fs::create_dir_all(rig.obid_home()).unwrap();
    let token_new = rig.obid_home().join("api-token.new");
    std::fs::write(&token_new, "old").unwrap();
    std::fs::set_permissions(&token_new, std::fs::Permissions::from_mode(0o644)).unwrap();
    std::fs::create_dir_all(rig.config().parent().unwrap()).unwrap();
    let victim = rig.folder.0.join("victim");
    std::fs::write(&victim, "untouched").unwrap();
    std::os::unix::fs::symlink(&victim, rig.config().with_extension("json.new")).unwrap();
    let out = rig.install(&[]);
    assert!(out.status.success(), "{}", text(&out));
    assert_eq!(mode(&rig.obid_home().join("api-token")), 0o600);
    assert_eq!(mode(&rig.config()), 0o600);
    assert!(
        !std::fs::symlink_metadata(rig.config())
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert_eq!(std::fs::read_to_string(&victim).unwrap(), "untouched");
}

/// R8: an older archive is a rollback: it installs, and says so.
#[test]
fn an_older_archive_warns_and_still_installs() {
    let rig = Rig::linux("rollback");
    assert!(rig.install(&[]).status.success());
    // The same version again says nothing.
    let same = rig.install(&[]);
    assert!(same.status.success(), "{}", text(&same));
    assert!(!text(&same).contains("is older than"), "{}", text(&same));
    rig.archive("#!/bin/sh\ncase \"$1\" in --version) echo \"obid 9.10.0-test\" ;; esac\n");
    let newer = rig.install(&[]);
    assert!(!text(&newer).contains("is older than"), "{}", text(&newer));
    rig.archive("#!/bin/sh\ncase \"$1\" in --version) echo \"obid 1.0.0-test\" ;; esac\n");
    let out = rig.install(&[]);
    assert!(out.status.success(), "{}", text(&out));
    assert!(
        text(&out).contains("obid 1.0.0-test is older than the obid 9.10.0-test"),
        "{}",
        text(&out)
    );
    let installed = Command::new(rig.prefix().join("bin/obid"))
        .arg("--version")
        .output()
        .unwrap();
    assert!(String::from_utf8_lossy(&installed.stdout).contains("1.0.0-test"));
}

/// The nit: without waiting, it doesn't claim obid is running.
#[test]
fn without_waiting_it_doesnt_say_obid_is_running() {
    let rig = Rig::linux("no-wait");
    let out = rig.install(&[]);
    assert!(out.status.success(), "{}", text(&out));
    assert!(!text(&out).contains("obid is running"), "{}", text(&out));
    assert!(text(&out).contains("wasn't checked"), "{}", text(&out));
}

/// A folder served as a download host: `curl … -o FILE URL` copies what the URL names from it, and
/// the server's own checksum file agrees with the archive. Returns the archive's digest.
fn serve_archive(rig: &Rig) -> String {
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
    rig.stand_in(
        "curl",
        &format!(
            "while [ $# -gt 0 ]; do case \"$1\" in -o) out=\"$2\"; shift 2 ;; --proto|--proto-redir) shift 2 ;; -*) shift ;; *) url=\"$1\"; shift ;; esac; done\n\
             cp '{}'/\"${{url##*/}}\" \"$out\"",
            served.display()
        ),
    );
    digest
}

/// R3: a download over anything but https needs a digest you give.
#[test]
fn a_download_that_isnt_https_needs_a_digest_you_give() {
    let rig = Rig::linux("http-from");
    let digest = serve_archive(&rig);
    let run = |args: &[&str]| {
        rig.command("install.sh")
            .args(["--from", "http://mirror.example/obid", "--no-wait"])
            .args(args)
            .output()
            .unwrap()
    };
    let bare = run(&[]);
    assert!(!bare.status.success(), "{}", text(&bare));
    assert!(text(&bare).contains("https://"), "{}", text(&bare));
    assert!(!rig.calls().contains("curl"), "{}", rig.calls());
    assert!(!rig.prefix().exists());

    let pinned = run(&["--sha256", &digest]);
    assert!(pinned.status.success(), "{}", text(&pinned));
    assert!(
        rig.calls()
            .contains("curl -q -fsSL --proto =http,https --proto-redir =https"),
        "{}",
        rig.calls()
    );
}

/// R3: the digest you give is the one checked, not one fetched from the same place.
#[test]
fn a_digest_you_give_is_the_one_checked() {
    let rig = Rig::linux("pinned");
    serve_archive(&rig);
    // A digest that isn't the archive's, though the server's checksum file agrees with it.
    let out = rig
        .command("install.sh")
        .args(["--from", "https://mirror.example/obid", "--no-wait"])
        .args(["--sha256", &"0".repeat(64)])
        .output()
        .unwrap();
    assert!(!out.status.success(), "{}", text(&out));
    assert!(text(&out).contains("checksum"), "{}", text(&out));
    assert!(!rig.prefix().exists());
    assert!(!rig.obid_home().exists());
    assert!(!rig.calls().contains(".sha256"), "{}", rig.calls());
}

/// N1: the user's own ~/.curlrc never applies to the installer's curls, so a `trace-ascii` in it
/// can't write the token's header to a file.
#[test]
fn a_curlrc_never_sees_the_token() {
    let Some(curl) = find_tool("curl") else {
        eprintln!("no curl on this machine: skipped");
        return;
    };
    let rig = Rig::linux("curlrc");
    rig.real_archive();
    std::os::unix::fs::symlink(curl, rig.tools().join("curl")).unwrap();
    let _service = RealService::new(&rig);
    let trace = rig.folder.0.join("trace.txt");
    std::fs::write(
        rig.user_home().join(".curlrc"),
        format!("trace-ascii \"{}\"\n", trace.display()),
    )
    .unwrap();
    let port = free_port();
    let out = rig
        .command("install.sh")
        .arg("--archive")
        .arg(rig.archive_path())
        .args(["--listen", &format!("127.0.0.1:{port}")])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", text(&out));
    assert!(text(&out).contains("obid is running"), "{}", text(&out));
    let token = std::fs::read_to_string(rig.obid_home().join("api-token")).unwrap();
    let traced = std::fs::read_to_string(&trace).unwrap_or_default();
    // trace-ascii breaks its lines every 64 bytes, so the header is looked for in pieces.
    assert!(
        !traced.contains("Authorization") && !traced.contains(&token.trim()[..16]),
        "the token's header is in {}",
        trace.display()
    );
    assert!(!trace.exists(), "~/.curlrc was read: {traced}");
}

/// N2: a home already gone (deleted by hand, a purge cut short) doesn't stop the rest of
/// `uninstall --purge`.
#[test]
fn purging_after_the_home_is_gone_still_uninstalls() {
    let rig = Rig::linux("home-gone");
    assert!(rig.install(&[]).status.success());
    std::fs::remove_dir_all(rig.obid_home()).unwrap();
    let out = rig.uninstall(&["--purge"]);
    assert!(out.status.success(), "{}", text(&out));
    assert!(text(&out).contains("already gone"), "{}", text(&out));
    assert!(!rig.unit().exists());
    assert!(!rig.prefix().exists());
    assert!(!rig.config().exists());
    assert!(
        rig.calls()
            .contains("systemctl --user disable --now obid.service"),
        "{}",
        rig.calls()
    );
    // A home that is there but isn't obid's is still refused, as before.
    let rig = Rig::linux("home-gone-other");
    assert!(rig.install(&[]).status.success());
    std::fs::remove_file(rig.obid_home().join("api-token")).unwrap();
    let out = rig.uninstall(&["--purge"]);
    assert!(!out.status.success(), "{}", text(&out));
    assert!(rig.obid_home().is_dir());
    assert!(rig.unit().exists());
}
