//! Built-in editable rule templates. IDs are supplied by the caller.
use crate::rule::*;
use crate::uuid::Uuid;
type RuleSpec<'a> = (&'a str, &'a str, &'a [&'a str], &'a [&'a str], &'a str, f64);

/// A tool's usual data folder for a template (name, home-relative path). A suggestion, never a grant of access.
pub type TemplateFolder = (&'static str, &'static str);

pub struct RuleTemplate { pub title: &'static str, pub summary: &'static str, pub suggested_folders: &'static [TemplateFolder], pub is_broad: bool, key: &'static str }
impl RuleTemplate {
    pub fn parse(key: &str) -> Option<Self> {
        let (key, title, summary, suggested_folders, is_broad): (&'static str, &'static str, &'static str, &'static [TemplateFolder], bool) = match key {
            "developerCleanup" => ("developerCleanup", "Developer Cleanup", "Dependencies, virtual environments, caches, and build output once a project goes quiet.", &[], true),
            "downloads" => ("downloads", "Downloads", "DMG installers after 7 days, ZIP archives after 14, everything else after 30.", &[], false),
            "screenshots" => ("screenshots", "Screenshots", "Screenshots 7 days after they are created.", &[], false),
            "temporaryWorkspace" => ("temporaryWorkspace", "Temporary Workspace", "Anything placed in the chosen folder expires after a set time.", &[], false),
            "buildArtifacts" => ("buildArtifacts", "Build Artifacts", "dist, build, target, coverage, and .cache folders after 30 days of project inactivity.", &[], true),
            "xcodeDerivedData" => ("xcodeDerivedData", "Xcode Derived Data", "Generated project folders after 60 days without modification; Xcode rebuilds them.", &[("Xcode", "~/Library/Developer/Xcode/DerivedData")], true),
            "xcodeDeviceSupport" => ("xcodeDeviceSupport", "Xcode Device Support", "Device symbol folders after 180 days without modification; reconnect the matching device to restore them.", &[("Xcode", "~/Library/Developer/Xcode/iOS DeviceSupport")], true),
            "homebrewDownloads" => ("homebrewDownloads", "Homebrew Downloads", "Completed package downloads after 90 days without modification; Homebrew downloads them again.", &[("Homebrew", "~/Library/Caches/Homebrew/downloads")], true),
            "npmCache" => ("npmCache", "npm Cache", "Package cache files after 90 days without modification; npm fetches missing packages again.", &[("npm", "~/.npm/_cacache")], true),
            "yarnClassicCache" => ("yarnClassicCache", "Yarn Classic Cache", "Yarn 1 package caches after 90 days without modification; excludes project-local Yarn caches.", &[("Yarn", "~/Library/Caches/Yarn")], true),
            "pipCache" => ("pipCache", "pip Cache", "HTTP and wheel cache files after 90 days without modification; pip downloads or rebuilds them.", &[("pip", "~/Library/Caches/pip")], true),
            "cargoRegistryCache" => ("cargoRegistryCache", "Cargo Registry Cache", "Downloaded .crate archives after 90 days without modification; leaves sources, credentials, and tools alone.", &[("Cargo", "~/.cargo/registry/cache")], true),
            "gradleCaches" => ("gradleCaches", "Gradle Caches", "Generated and downloaded cache files after 90 days without modification; leaves Gradle settings and wrappers alone.", &[("Gradle", "~/.gradle/caches")], true),
            "agentSessionLogs" => ("agentSessionLogs", "AI Agent Session Logs", "Conversation transcripts (.jsonl, .jsonl.zst) kept by Claude Code, Codex, OMP, pi, and Gemini CLI, after 60 days without modification. Old sessions can no longer be resumed. Choose one agent's folder at a time.",
                &[("Claude Code", "~/.claude/projects"), ("Codex", "~/.codex/sessions"), ("Codex (archived)", "~/.codex/archived_sessions"), ("OMP", "~/.omp/agent/sessions"), ("pi", "~/.pi/agent/sessions"), ("Gemini CLI", "~/.gemini/tmp")], true),
            "agentEditBackups" => ("agentEditBackups", "AI Agent Edit Backups", "Per-session file backups that Claude Code keeps for undo, after 30 days without modification.", &[("Claude Code", "~/.claude/file-history")], true),
            "agentDebugLogs" => ("agentDebugLogs", "AI Agent Debug Logs", "Log and trace files (.log, .trace) written by OMP (including per-session tool output), Codex, GitHub Copilot, and opencode, after 14 days without modification. Session transcripts, reports, and images are not matched.",
                &[("OMP", "~/.omp/logs"), ("OMP session tool output", "~/.omp/agent/sessions"), ("Codex", "~/.codex/log"), ("GitHub Copilot", "~/.copilot/logs"), ("opencode", "~/.local/share/opencode/log")], true),
            _ => return None,
        };
        Some(Self { key, title, summary, suggested_folders, is_broad })
    }
    pub fn rules(&self, path: &str, state: RuleState, temporary_lifetime: f64, mut next_id: impl FnMut() -> Uuid) -> Result<Vec<LifetimeRule>, RuleValidationError> {
        let recursive = !matches!(self.key, "downloads" | "temporaryWorkspace" | "xcodeDerivedData" | "xcodeDeviceSupport");
        let scope = RuleScope::new(path, recursive)?;
        let initial = if self.is_broad && state == RuleState::Active { RuleState::Preview } else { state };
        let specs: &[RuleSpec<'_>] = match self.key {
            "developerCleanup" => &[
                ("Old node_modules", "directory", &["node_modules"], &[], "projectActivity", 2592000.0),
                ("Old Python environments", "directory", &[".venv", "venv"], &[], "projectActivity", 3888000.0),
                ("Stale Python caches", "directory", &["__pycache__", ".pytest_cache"], &[], "modified", 604800.0),
                ("Stale Next.js cache", "directory", &[], &["**/.next/cache"], "projectActivity", 1209600.0),
                ("Old build output", "directory", &["dist", "build", "target"], &[], "projectActivity", 2592000.0),
            ],
            "downloads" => &[
                ("Old installers", "file", &[], &["*.dmg"], "firstObserved", 604800.0),
                ("Old archives", "file", &[], &["*.zip"], "firstObserved", 1209600.0),
                ("Other old downloads", "fileOrDirectory", &[], &[], "firstObserved", 2592000.0),
            ],
            "screenshots" => &[
                ("Old screenshots", "file", &[], &["Screenshot*", "Screen Shot*"], "created", 604800.0),
            ],
            "temporaryWorkspace" => &[
                ("Temporary workspace", "fileOrDirectory", &[], &[], "firstObserved", temporary_lifetime),
            ],
            "buildArtifacts" => &[
                ("Old build artifacts", "directory", &["dist", "build", "target", "coverage", ".cache"], &[], "projectActivity", 2592000.0),
            ],
            "xcodeDerivedData" => &[
                ("Old Xcode derived data", "directory", &[], &[], "modified", 5184000.0),
            ],
            "xcodeDeviceSupport" => &[
                ("Old iOS device symbols", "directory", &[], &[], "modified", 15552000.0),
            ],
            "homebrewDownloads" => &[
                ("Old completed Homebrew downloads", "file", &[], &["*--*.tar.gz", "*--*.tar.xz", "*--*.tar.bz2", "*--*.zip", "*--*.dmg", "*--*.pkg"], "modified", 7776000.0),
            ],
            "npmCache" => &[
                ("Old npm cache files", "file", &[], &[], "modified", 7776000.0),
            ],
            "yarnClassicCache" => &[
                ("Old Yarn Classic cache files", "file", &[], &[], "modified", 7776000.0),
            ],
            "pipCache" => &[
                ("Old pip cache files", "file", &[], &[], "modified", 7776000.0),
            ],
            "cargoRegistryCache" => &[
                ("Old downloaded crates", "file", &[], &["**/*.crate"], "modified", 7776000.0),
            ],
            "gradleCaches" => &[
                ("Old Gradle cache files", "file", &[], &[], "modified", 7776000.0),
            ],
            "agentSessionLogs" => &[
                ("Old agent session logs", "file", &[], &["*.jsonl", "*.jsonl.zst"], "modified", 5184000.0),
            ],
            "agentEditBackups" => &[
                ("Old agent edit backups", "file", &[], &[], "modified", 2592000.0),
            ],
            "agentDebugLogs" => &[
                ("Old agent debug logs", "file", &[], &["*.log", "*.trace"], "modified", 1209600.0),
            ],
            _ => unreachable!(),
        };
        specs.iter().map(|(name, kind, names, globs, basis, lifetime)| LifetimeRule::new(next_id(), name, scope.clone(),
            ItemMatcher::new(ItemKind::parse(kind).unwrap(), names.iter().map(|s| (*s).into()).collect(), globs.iter().map(|s| (*s).into()).collect())?,
            ExpiryBasis::parse(basis).unwrap(), RuleDuration::new(*lifetime)?, None, FolderAction::TrashItem, initial, RuleMatchMode::Scoped)).collect()
    }
}
