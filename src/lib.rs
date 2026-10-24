//! Zed side of the Haxe debugger extension.
//!
//! Like Zed-Haxe, this only downloads and starts things. Zed runs `node bridge.js` as the debug adapter;
//! the bridge, written in Haxe under `bridge/`, works out the project, the Haxe to use and which debugger
//! fits, then debugs: through vshaxe's eval-debugger or hashlink-debugger, Microsoft's js-debug, or for
//! hxcpp itself, with hxcpp-debug-server compiled into the program.

use std::{env, fs};

use zed_extension_api::{
    self as zed, DebugAdapterBinary, DebugConfig, DebugRequest, DebugScenario, DebugTaskDefinition,
    DownloadedFileType, Result, StartDebuggingRequestArguments,
    StartDebuggingRequestArgumentsRequest, TaskTemplate, Worktree,
    serde_json::{Value, json},
    settings::LspSettings,
};

/// Name of the debug adapter in extension.toml, debug.json and the `dap` settings.
const ADAPTER: &str = "Haxe";
/// Name of the locator in extension.toml.
const LOCATOR: &str = "haxe";

/// eval-debugger has no releases of its own; vshaxe's VS Code extension bundles it.
const VSHAXE_VERSION: &str = "2.34.2";
const EVAL_ADAPTER: &str = "extension/eval-debugger/bin/index.js";

/// hxcpp-debug-server, the library the bridge compiles into hxcpp programs, from this fork of
/// vshaxe/hxcpp-debugger. The haxelib release (1.2.4) predates fixes the bridge relies on.
const HXCPP_DEBUGGER_REPOSITORY: &str = "Jarrio/hxcpp-debugger";
const HXCPP_DEBUGGER_COMMIT: &str = "dc2aac17eb3b761e8e47f909ff2b7dbf9a7cc7c0";
const HXCPP_DEBUG_SERVER: &str = "hxcpp-debug-server/haxelib.json";

/// hashlink-debugger, from its GitHub release (the VS Code extension's .vsix).
const HASHLINK_DEBUGGER_VERSION: &str = "2.0.0";
const HASHLINK_ADAPTER: &str = "extension/adapter.js";

/// js-debug, the debugger behind Zed's own JavaScript support, from its GitHub release.
const JS_DEBUG_VERSION: &str = "v1.140.0";
const JS_DEBUG_SERVER: &str = "js-debug/src/dapDebugServer.js";

/// Zed-Haxe's language server; its `project` settings (Haxe path, project root, hxml) apply here too.
const LANGUAGE_SERVER: &str = "haxe-language-server";

/// Built by `haxe build.hxml` in `bridge/`.
const BRIDGE_JS: &str = include_str!("../bridge/bin/bridge.js");

struct HaxeDebugExtension;

impl zed::Extension for HaxeDebugExtension {
    fn new() -> Self {
        HaxeDebugExtension
    }

    fn get_dap_binary(
        &mut self,
        adapter_name: String,
        config: DebugTaskDefinition,
        user_provided_debug_adapter_path: Option<String>,
        worktree: &Worktree,
    ) -> Result<DebugAdapterBinary> {
        if adapter_name != ADAPTER {
            return Err(format!("unknown debug adapter {adapter_name}"));
        }
        let configuration: Value = zed::serde_json::from_str(&config.config)
            .map_err(|e| format!("invalid debug configuration: {e}"))?;
        // `"dap": {"Haxe": {"binary": "/path/to/bridge.js"}}` uses a local build of the bridge.
        let bridge = match user_provided_debug_adapter_path {
            Some(path) => path,
            None => write_bridge()?,
        };
        let project = LspSettings::for_worktree(LANGUAGE_SERVER, worktree)
            .ok()
            .and_then(|s| s.settings)
            .and_then(|s| s.get("project").cloned())
            .unwrap_or_else(|| json!({}));
        // Zed has already filled in the variables (`$ZED_WORKTREE_ROOT`, ...) in the configuration.
        let mut arguments = vec![
            bridge,
            "--config".to_string(),
            configuration.to_string(),
            "--project".to_string(),
            project.to_string(),
        ];
        // Downloaded whichever debugger the session turns out to need; the bridge reports one that's missing.
        let eval = download(
            "vshaxe",
            VSHAXE_VERSION,
            &format!("https://open-vsx.org/api/nadako/vshaxe/{VSHAXE_VERSION}/file/nadako.vshaxe-{VSHAXE_VERSION}.vsix"),
            DownloadedFileType::Zip,
            EVAL_ADAPTER,
        );
        let server = download(
            "hxcpp-debugger",
            HXCPP_DEBUGGER_COMMIT,
            &format!("https://github.com/{HXCPP_DEBUGGER_REPOSITORY}/archive/{HXCPP_DEBUGGER_COMMIT}.zip"),
            DownloadedFileType::Zip,
            HXCPP_DEBUG_SERVER,
        );
        let hashlink = download(
            "hashlink-debugger",
            HASHLINK_DEBUGGER_VERSION,
            &format!(
                "https://github.com/vshaxe/hashlink-debugger/releases/download/{HASHLINK_DEBUGGER_VERSION}/haxe-hl-{HASHLINK_DEBUGGER_VERSION}.vsix"
            ),
            DownloadedFileType::Zip,
            HASHLINK_ADAPTER,
        );
        let js_debug = download(
            "js-debug",
            JS_DEBUG_VERSION,
            &format!(
                "https://github.com/microsoft/vscode-js-debug/releases/download/{JS_DEBUG_VERSION}/js-debug-dap-{JS_DEBUG_VERSION}.tar.gz"
            ),
            DownloadedFileType::GzipTar,
            JS_DEBUG_SERVER,
        );
        for (flag, path) in [
            ("--eval", eval),
            ("--hxcpp-debug-server", server.map(|file| parent(&file))),
            ("--hashlink", hashlink),
            ("--js-debug", js_debug),
        ] {
            match path {
                Ok(path) => arguments.extend([flag.to_string(), path]),
                Err(error) => eprintln!("haxe-debug: {error}"),
            }
        }
        if let Some(file) = configuration.get("traceFile").and_then(Value::as_str) {
            arguments.extend(["--trace".to_string(), file.to_string()]);
        }
        Ok(DebugAdapterBinary {
            command: Some(zed::node_binary_path()?),
            arguments,
            // Zed adds the project's shell environment, so the bridge finds haxe, lix, haxe-manager...
            envs: vec![],
            cwd: Some(worktree.root_path()),
            connection: None,
            request_args: StartDebuggingRequestArguments {
                request: request_kind(&configuration)?,
                configuration: configuration.to_string(),
            },
        })
    }

    fn dap_request_kind(
        &mut self,
        _adapter_name: String,
        config: Value,
    ) -> Result<StartDebuggingRequestArgumentsRequest> {
        request_kind(&config)
    }

    /// The new-session dialog. Its "program" is an hxml or a Haxe argument, with more Haxe arguments
    /// after it, `haxe` followed by its arguments, or a project tool (`lime test linux`); anything else is
    /// an hxcpp program already built.
    fn dap_config_to_scenario(&mut self, config: DebugConfig) -> Result<DebugScenario> {
        let DebugRequest::Launch(launch) = config.request else {
            return Err("Haxe debugging can't attach to a running program yet".to_string());
        };
        let mut scenario = json!({
            "request": "launch",
            "stopOnEntry": config.stop_on_entry.unwrap_or(false),
        });
        if is_haxe(&launch.program) {
            scenario["haxeArgs"] = launch.args.into();
        } else if is_project_tool(&launch.program, &launch.args) {
            let mut command = vec![launch.program];
            command.extend(launch.args);
            scenario["command"] = command.into();
        } else if launch.program.ends_with(".hxml") || launch.program.starts_with('-') {
            let mut haxe_args = vec![launch.program];
            haxe_args.extend(launch.args);
            scenario["haxeArgs"] = haxe_args.into();
        } else {
            scenario["program"] = launch.program.into();
            scenario["args"] = launch.args.into();
        }
        if let Some(cwd) = launch.cwd {
            scenario["cwd"] = cwd.into();
        }
        if !launch.envs.is_empty() {
            scenario["env"] = launch
                .envs
                .into_iter()
                .map(|(name, value)| (name, Value::from(value)))
                .collect::<zed::serde_json::Map<_, _>>()
                .into();
        }
        Ok(DebugScenario {
            label: config.label,
            adapter: config.adapter,
            build: None,
            config: scenario.to_string(),
            tcp_connection: None,
        })
    }

    /// The tasks Zed-Haxe writes: `haxe build.hxml` for plain hxml projects, Lime's
    /// `haxelib run lime test|build <project> <target>` and Ceramic's `ceramic <backend> run|build <target>`. The bridge builds the program itself, in debug
    /// mode, so there is no build step.
    fn dap_locator_create_scenario(
        &mut self,
        locator_name: String,
        build_task: TaskTemplate,
        resolved_label: String,
        _debug_adapter_name: String,
    ) -> Option<DebugScenario> {
        if locator_name != LOCATOR {
            return None;
        }
        let mut config = if is_haxe(&build_task.command)
            && build_task.args.iter().any(|arg| arg.ends_with(".hxml"))
        {
            json!({"request": "launch", "haxeArgs": build_task.args})
        } else if is_project_tool(&build_task.command, &build_task.args) {
            let mut command = vec![build_task.command];
            command.extend(build_task.args);
            json!({"request": "launch", "command": command})
        } else {
            return None;
        };
        if let Some(cwd) = build_task.cwd {
            config["cwd"] = cwd.into();
        }
        Some(DebugScenario {
            label: resolved_label,
            adapter: ADAPTER.to_string(),
            build: None,
            config: config.to_string(),
            tcp_connection: None,
        })
    }

    fn run_dap_locator(
        &mut self,
        _locator_name: String,
        _build_task: TaskTemplate,
    ) -> Result<zed::DebugRequest> {
        Err("Haxe debug scenarios have no build step".to_string())
    }
}

fn request_kind(config: &Value) -> Result<StartDebuggingRequestArgumentsRequest> {
    match config.get("request").and_then(Value::as_str) {
        Some("launch") => Ok(StartDebuggingRequestArgumentsRequest::Launch),
        Some("attach") => Ok(StartDebuggingRequestArgumentsRequest::Attach),
        _ => Err("the debug configuration needs \"request\": \"launch\"".to_string()),
    }
}

/// `haxe`, or a path to it (`/opt/haxe/haxe`, `haxe.exe`).
fn is_haxe(command: &str) -> bool {
    matches!(file_name(command), "haxe" | "haxe.exe" | "haxe.cmd")
}

/// Lime's `lime`/`openfl` or `haxelib run lime|openfl` running `test`, `build` or `run`, or Ceramic's
/// `ceramic <backend> run|build`: the bridge knows how to debug what they make.
fn is_project_tool(command: &str, args: &[String]) -> bool {
    let rest = match file_name(command).trim_end_matches(".exe").trim_end_matches(".cmd") {
        "lime" | "openfl" => args,
        "ceramic" if !args.is_empty() => &args[1..],
        "haxelib" if args.len() > 1 && args[0] == "run" && matches!(args[1].as_str(), "lime" | "openfl") => {
            &args[2..]
        }
        _ => return false,
    };
    matches!(rest.first().map(String::as_str), Some("test" | "build" | "run"))
}

fn file_name(path: &str) -> &str {
    path.rsplit(['/', '\\']).next().unwrap_or(path)
}

/// Absolute path of `file` in the archive at `url`, unpacked into `{name}-{version}` on first use.
/// Offline, falls back to a version downloaded earlier. `file` may also sit one folder down, as in
/// GitHub's archives, whose files are all in `{repository}-{commit}/`.
fn download(
    name: &str,
    version: &str,
    url: &str,
    kind: DownloadedFileType,
    file: &str,
) -> Result<String> {
    let dir = format!("{name}-{version}");
    if let Some(path) = find(&dir, file) {
        return absolute(&path);
    }
    // A .vsix is a zip file too.
    match zed::download_file(url, &dir, kind) {
        Ok(()) => {
            let path = find(&dir, file).ok_or_else(|| format!("{url} has no {file}"))?;
            remove_other_versions(name, &dir);
            absolute(&path)
        }
        Err(error) => {
            let mut earlier: Vec<String> = fs::read_dir(".")
                .map_err(|e| e.to_string())?
                .flatten()
                .map(|entry| entry.file_name().to_string_lossy().to_string())
                .filter(|other| other.starts_with(&format!("{name}-")))
                .filter_map(|other| find(&other, file))
                .collect();
            earlier.sort();
            let path = earlier
                .pop()
                .ok_or_else(|| format!("could not download {url}: {error}"))?;
            eprintln!("haxe-debug: using {path} downloaded earlier; downloading {url} failed: {error}");
            absolute(&path)
        }
    }
}

/// `dir/file`, or `dir/<folder>/file`, if it exists.
fn find(dir: &str, file: &str) -> Option<String> {
    let direct = format!("{dir}/{file}");
    if is_file(&direct) {
        return Some(direct);
    }
    fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|entry| format!("{dir}/{}/{file}", entry.file_name().to_string_lossy()))
        .find(|path| is_file(path))
}

fn remove_other_versions(name: &str, keep: &str) {
    if let Ok(entries) = fs::read_dir(".") {
        for entry in entries.flatten() {
            let other = entry.file_name().to_string_lossy().to_string();
            if other.starts_with(&format!("{name}-")) && other != keep {
                fs::remove_dir_all(entry.path()).ok();
            }
        }
    }
}

/// The folder of the haxelib whose `haxelib.json` is at `file`.
fn parent(file: &str) -> String {
    file.rsplit_once(['/', '\\'])
        .map_or(file, |(dir, _)| dir)
        .to_string()
}

/// Writes the embedded bridge into the extension's work directory, if it changed.
fn write_bridge() -> Result<String> {
    let path = "bridge.js";
    if fs::read_to_string(path).ok().as_deref() != Some(BRIDGE_JS) {
        fs::write(path, BRIDGE_JS).map_err(|e| format!("could not write {path}: {e}"))?;
    }
    absolute(path)
}

fn is_file(path: &str) -> bool {
    fs::metadata(path).map(|m| m.is_file()).unwrap_or(false)
}

fn absolute(path: &str) -> Result<String> {
    let dir = env::current_dir().map_err(|e| e.to_string())?;
    Ok(dir.join(path).to_string_lossy().to_string())
}

zed::register_extension!(HaxeDebugExtension);
