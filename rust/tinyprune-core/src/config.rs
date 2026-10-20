//! Config-as-code: the deliberately restricted YAML subset (spec §41), its derived policy, and the exporter.
//! Mirrors `ConfigDocument` / `ConfigSyntax`; diagnostics are user-facing and must match byte for byte.

use crate::rule::*;
use crate::swiftstr::{canonical_eq, dedup_canonical, drop_first, has_prefix, swift_cmp};
use crate::uuid::Uuid;
use sha2::{Digest, Sha256};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigError {
    /// 1-based; `None` only for whole-document problems.
    pub line: Option<usize>,
    pub message: String,
}

fn error<T>(line: impl Into<Option<usize>>, message: impl Into<String>) -> Result<T, ConfigError> {
    Err(ConfigError { line: line.into(), message: message.into() })
}

#[derive(Debug, Clone, PartialEq)]
pub struct Root {
    pub path: String,
    pub line: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RuleSpec {
    pub name: String,
    pub item_kind: ItemKind,
    pub exact_names: Vec<String>,
    pub glob_patterns: Vec<String>,
    pub basis: ExpiryBasis,
    pub lifetime: RuleDuration,
    pub grace: Option<RuleDuration>,
    pub line: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Exception {
    pub path: String,
    pub protect_descendants: bool,
    pub line: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ConfigDocument {
    pub version: i64,
    pub roots: Vec<Root>,
    pub rules: Vec<RuleSpec>,
    pub exceptions: Vec<Exception>,
}

/// Deterministic UUID (version-5 layout over SHA-256) so re-applying a config is idempotent.
pub fn rule_id(name: &str, root_path: &str) -> Uuid {
    let digest = Sha256::digest(format!("tinyprune.config\u{0}{name}\u{0}{root_path}").as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0F) | 0x50;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    Uuid(u128::from_be_bytes(bytes))
}

const BASIS_NAMES: [(&str, ExpiryBasis); 6] = [
    ("project_activity", ExpiryBasis::ProjectActivity),
    ("modified", ExpiryBasis::Modified),
    ("created", ExpiryBasis::Created),
    ("first_observed", ExpiryBasis::FirstObserved),
    ("observed_activity", ExpiryBasis::ObservedActivity),
    ("accessed", ExpiryBasis::Accessed),
];

fn basis_named(name: &str) -> Option<ExpiryBasis> {
    BASIS_NAMES.iter().find(|(candidate, _)| *candidate == name).map(|(_, basis)| *basis)
}

fn name_of(basis: ExpiryBasis) -> Option<&'static str> {
    BASIS_NAMES.iter().find(|(_, candidate)| *candidate == basis).map(|(name, _)| *name)
}

impl ConfigDocument {
    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.version != 1 {
            return error(1, format!("Unsupported version {}; only version 1 is supported.", self.version));
        }
        if self.roots.is_empty() {
            return error(None, "At least one root is required.");
        }
        for (index, root) in self.roots.iter().enumerate() {
            for other in &self.roots[..index] {
                if canonical_eq(&other.path, &root.path) {
                    return error(root.line, format!("Duplicate root {}.", root.path));
                }
                if has_prefix(&root.path, &format!("{}/", other.path)) || has_prefix(&other.path, &format!("{}/", root.path)) {
                    return error(root.line, format!("Root {} overlaps root {}; list only the outer folder.", root.path, other.path));
                }
            }
        }
        let mut names: Vec<&str> = Vec::new();
        for rule in &self.rules {
            if crate::swiftstr::is_blank(&rule.name) {
                return error(rule.line, "Rule name must not be empty.");
            }
            if names.iter().any(|seen| canonical_eq(seen, &rule.name)) {
                return error(rule.line, format!("Duplicate rule name '{}'.", rule.name));
            }
            names.push(&rule.name);
            if rule.exact_names.is_empty() && rule.glob_patterns.is_empty() {
                return error(rule.line, format!("Rule '{}' must match something.", rule.name));
            }
        }
        let mut exception_paths: Vec<&str> = Vec::new();
        for exception in &self.exceptions {
            if exception_paths.iter().any(|seen| canonical_eq(seen, &exception.path)) {
                return error(exception.line, format!("Duplicate exception for {}.", exception.path));
            }
            exception_paths.push(&exception.path);
            if !self.roots.iter().any(|root| has_prefix(&exception.path, &format!("{}/", root.path))) {
                return error(exception.line, format!("Exception {} is not inside any listed root.", exception.path));
            }
        }
        Ok(())
    }

    pub fn parse(text: &str, home_directory: &str) -> Result<ConfigDocument, ConfigError> {
        if !has_prefix(home_directory, "/") {
            return error(None, "Home directory must be absolute.");
        }
        let root = syntax::parse(text)?;
        let Node::Map(entries, _) = &root else {
            return error(root.line(), "Top level must be a mapping.");
        };
        let top = fields(entries, &["exceptions", "roots", "rules", "version"], &["roots", "version"], "top level", None)?;

        let version_node = top.get("version").unwrap();
        let Node::Scalar(version_text, _) = &version_node.value else {
            return error(version_node.value.line(), "version must be a number.");
        };
        if version_text != "1" {
            return error(version_node.value.line(), format!("Unsupported version '{version_text}'; only version 1 is supported."));
        }

        let roots_node = &top.get("roots").unwrap().value;
        let mut roots = Vec::new();
        for (raw, line) in strings(roots_node, "roots")? {
            roots.push(Root { path: expand(&raw, home_directory, line)?, line });
        }
        if roots.is_empty() {
            return error(roots_node.line(), "roots must not be empty.");
        }

        let mut rules = Vec::new();
        if let Some(field) = top.get("rules") {
            for item in list(field.value, "rules")? {
                rules.push(parse_rule(item)?);
            }
        }
        let mut exceptions = Vec::new();
        if let Some(field) = top.get("exceptions") {
            for item in list(field.value, "exceptions")? {
                exceptions.push(parse_exception(item, home_directory)?);
            }
        }
        let document = ConfigDocument { version: 1, roots, rules, exceptions };
        document.validate()?;
        Ok(document)
    }
}

struct Field<'a> {
    key_line: usize,
    value: &'a Node,
}

fn fields<'a>(
    entries: &'a [Entry],
    allowed: &[&str],
    required: &[&str],
    context: &str,
    line: Option<usize>,
) -> Result<std::collections::HashMap<String, Field<'a>>, ConfigError> {
    let mut result = std::collections::HashMap::new();
    for entry in entries {
        if !allowed.contains(&entry.key.as_str()) {
            return error(
                entry.line,
                format!("Unknown key '{}' in {context}; allowed: {}.", entry.key, allowed.join(", ")),
            );
        }
        result.insert(entry.key.clone(), Field { key_line: entry.line, value: &entry.value });
    }
    for key in required {
        if !result.contains_key(*key) {
            return error(line.or(entries.first().map(|entry| entry.line)).unwrap_or(1), format!("Missing required key '{key}' in {context}."));
        }
    }
    Ok(result)
}

fn list<'a>(node: &'a Node, what: &str) -> Result<&'a [Node], ConfigError> {
    match node {
        Node::List(items, _) => Ok(items),
        _ => error(node.line(), format!("{what} must be a list.")),
    }
}

fn strings(node: &Node, what: &str) -> Result<Vec<(String, usize)>, ConfigError> {
    list(node, what)?
        .iter()
        .map(|item| match item {
            Node::Scalar(value, line) if !value.is_empty() => Ok((value.clone(), *line)),
            _ => error(item.line(), format!("{what} entries must be non-empty strings.")),
        })
        .collect()
}

fn expand(raw: &str, home: &str, line: usize) -> Result<String, ConfigError> {
    let absolute = if raw == "~" {
        home.to_string()
    } else if has_prefix(raw, "~/") {
        format!("{home}/{}", drop_first(raw, 2))
    } else if has_prefix(raw, "~") {
        return error(line, format!("'{raw}': only ~ and ~/ are supported."));
    } else if has_prefix(raw, "/") {
        raw.to_string()
    } else {
        return error(line, format!("'{raw}' is a relative path; use an absolute path or one starting with ~/."));
    };
    let normalized = normalize_path(&absolute);
    if normalized == "/" {
        return error(line, "The filesystem root cannot be used.");
    }
    Ok(normalized)
}

fn duration(node: &Node, what: &str) -> Result<RuleDuration, ConfigError> {
    let failure = || error(node.line(), format!("{what} must be a positive duration such as 12h, 30d, or 2w."));
    let Node::Scalar(text, _) = node else { return failure() };
    let clusters: Vec<&str> = text.graphemes(true).collect();
    let Some((unit, digits)) = clusters.split_last() else { return failure() };
    let multiplier = match *unit {
        "m" => 60.0,
        "h" => 3_600.0,
        "d" => 86_400.0,
        "w" => 604_800.0,
        _ => return failure(),
    };
    match parse_swift_int(&digits.concat()) {
        Some(amount) if amount > 0 => RuleDuration::new(amount as f64 * multiplier).or_else(|_| failure()),
        _ => failure(),
    }
}

/// Swift `Int(String)`: optional sign, then one or more ASCII digits, no other characters.
fn parse_swift_int(text: &str) -> Option<i64> {
    let (negative, digits) = match text.as_bytes().first()? {
        b'+' => (false, &text[1..]),
        b'-' => (true, &text[1..]),
        _ => (false, text),
    };
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let magnitude: i128 = digits.parse().ok()?;
    i64::try_from(if negative { -magnitude } else { magnitude }).ok()
}

fn parse_rule(node: &Node) -> Result<RuleSpec, ConfigError> {
    let Node::Map(entries, _) = node else { return error(node.line(), "Each rule must be a mapping.") };
    let rule = fields(entries, &["action", "expiry", "match", "name"], &["expiry", "match", "name"], "rule", Some(node.line()))?;

    let name_node = rule["name"].value;
    let (name, name_line) = match name_node {
        Node::Scalar(name, line) if !name.is_empty() => (name.clone(), *line),
        _ => return error(name_node.line(), "Rule name must be a non-empty string."),
    };
    if let Some(action) = rule.get("action") {
        if !matches!(action.value, Node::Scalar(value, _) if value == "trash") {
            return error(action.value.line(), "action must be 'trash'.");
        }
    }

    let Node::Map(match_entries, match_line) = rule["match"].value else {
        return error(rule["match"].value.line(), "match must be a mapping.");
    };
    let matched = fields(match_entries, &["directories", "files", "globs", "names"], &[], "match", Some(*match_line))?;
    if matched.contains_key("directories") && matched.contains_key("files") {
        return error(matched["files"].key_line, "match cannot list both directories and files; use names for either.");
    }
    let mut names: Vec<String> = Vec::new();
    for key in ["directories", "files", "names"] {
        let Some(entry) = matched.get(key) else { continue };
        for (value, line) in strings(entry.value, key)? {
            if value.contains('/') {
                return error(line, format!("{key} entries are bare names and cannot contain '/'; use globs for paths."));
            }
            names.push(value);
        }
    }
    let mut globs: Vec<String> = Vec::new();
    if let Some(entry) = matched.get("globs") {
        for (value, line) in strings(entry.value, "globs")? {
            if has_prefix(&value, "/") {
                return error(line, "globs are relative to the root and cannot start with '/'.");
            }
            globs.push(value);
        }
    }
    if names.is_empty() && globs.is_empty() {
        return error(*match_line, "match needs at least one of directories, files, names, or globs.");
    }
    let kind = if matched.contains_key("directories") {
        ItemKind::Directory
    } else if matched.contains_key("files") {
        ItemKind::File
    } else {
        ItemKind::FileOrDirectory
    };

    let Node::Map(expiry_entries, expiry_line) = rule["expiry"].value else {
        return error(rule["expiry"].value.line(), "expiry must be a mapping.");
    };
    let expiry = fields(expiry_entries, &["after", "grace", "since"], &["after", "since"], "expiry", Some(*expiry_line))?;
    let lifetime = duration(expiry["after"].value, "after")?;
    let grace = expiry.get("grace").map(|field| duration(field.value, "grace")).transpose()?;
    let basis = match expiry["since"].value {
        Node::Scalar(text, _) => basis_named(text),
        _ => None,
    };
    let Some(basis) = basis else {
        let names: Vec<&str> = BASIS_NAMES.iter().map(|(name, _)| *name).collect();
        return error(expiry["since"].value.line(), format!("since must be one of {}.", names.join(", ")));
    };

    Ok(RuleSpec {
        name,
        item_kind: kind,
        exact_names: sorted_unique(&names),
        glob_patterns: sorted_unique(&globs),
        basis,
        lifetime,
        grace,
        line: name_line,
    })
}

/// `Array(Set(values)).sorted()` with Swift string semantics.
fn sorted_unique(values: &[String]) -> Vec<String> {
    let mut unique = dedup_canonical(values);
    unique.sort_by(|a, b| swift_cmp(a, b));
    unique
}

fn parse_exception(node: &Node, home: &str) -> Result<Exception, ConfigError> {
    let Node::Map(entries, _) = node else { return error(node.line(), "Each exception must be a mapping.") };
    let item = fields(entries, &["path", "protect"], &["path", "protect"], "exception", Some(node.line()))?;
    let Node::Scalar(raw, line) = item["path"].value else {
        return error(item["path"].value.line(), "path must be a string.");
    };
    let protect = match item["protect"].value {
        Node::Scalar(value, _) if value == "descendants" || value == "item" => value.as_str(),
        other => return error(other.line(), "protect must be 'descendants' or 'item'."),
    };
    Ok(Exception { path: expand(raw, home, *line)?, protect_descendants: protect == "descendants", line: *line })
}

// MARK: Rendering

#[derive(Clone, PartialEq)]
struct Definition {
    name: String,
    kind: ItemKind,
    names: Vec<String>,
    globs: Vec<String>,
    basis: ExpiryBasis,
    lifetime: RuleDuration,
    grace: Option<RuleDuration>,
}

fn sorted(values: &[String]) -> Vec<String> {
    let mut copy = values.to_vec();
    copy.sort_by(|a, b| swift_cmp(a, b));
    copy
}

fn same_set(a: &[String], b: &[String]) -> bool {
    a.iter().all(|x| b.iter().any(|y| canonical_eq(x, y))) && b.iter().all(|y| a.iter().any(|x| canonical_eq(x, y)))
}

/// Exports the policy in config format. Rules the format cannot express are listed in trailing comments.
pub fn render(rules: &[LifetimeRule], roots: &[String], overrides: &[crate::resolve::ItemPolicyOverride]) -> String {
    let root_paths = sorted(roots);
    let mut skipped: Vec<String> = Vec::new();

    let mut order: Vec<Definition> = Vec::new();
    let mut scopes: Vec<Vec<String>> = Vec::new();
    for rule in rules {
        if let Some(reason) = unexpressible(rule) {
            skipped.push(format!("rule '{}' ({}): {reason}", rule.name, rule.scope.path));
            continue;
        }
        let definition = Definition {
            name: rule.name.clone(),
            kind: rule.matcher.item_kind,
            names: sorted(&rule.matcher.exact_names),
            globs: sorted(&rule.matcher.glob_patterns),
            basis: rule.expiry_basis,
            lifetime: rule.lifetime,
            grace: rule.grace_period,
        };
        let position = order.iter().position(|existing| *existing == definition);
        let index = position.unwrap_or_else(|| {
            order.push(definition);
            scopes.push(Vec::new());
            order.len() - 1
        });
        if !scopes[index].iter().any(|scope| canonical_eq(scope, &rule.scope.path)) {
            scopes[index].push(rule.scope.path.clone());
        }
    }

    let mut lines: Vec<String> = vec!["version: 1".into(), String::new(), "roots:".into()];
    lines.extend(root_paths.iter().map(|path| format!("  - {}", scalar(path))));
    let mut rendered: Vec<String> = Vec::new();
    let mut rule_lines: Vec<String> = Vec::new();
    for (definition, scope_set) in order.iter().zip(&scopes) {
        if !same_set(scope_set, &root_paths) {
            skipped.push(format!("rule '{}': applies to {}, not to every root", definition.name, sorted(scope_set).join(", ")));
            continue;
        }
        if rendered.iter().any(|name| canonical_eq(name, &definition.name)) {
            skipped.push(format!("rule '{}': another rule already uses this name", definition.name));
            continue;
        }
        rendered.push(definition.name.clone());
        rule_lines.push(format!("  - name: {}", scalar(&definition.name)));
        rule_lines.push("    match:".into());
        let kind_key = match definition.kind {
            ItemKind::Directory => "directories",
            ItemKind::File => "files",
            ItemKind::FileOrDirectory => "names",
        };
        if !definition.names.is_empty() {
            rule_lines.push(format!("      {kind_key}:"));
            rule_lines.extend(definition.names.iter().map(|name| format!("        - {}", scalar(name))));
        }
        if !definition.globs.is_empty() {
            rule_lines.push("      globs:".into());
            rule_lines.extend(definition.globs.iter().map(|glob| format!("        - {}", scalar(glob))));
        }
        rule_lines.push("    expiry:".into());
        rule_lines.push(format!("      after: {}", duration_text(definition.lifetime).unwrap()));
        rule_lines.push(format!("      since: {}", name_of(definition.basis).unwrap()));
        if let Some(grace) = definition.grace {
            rule_lines.push(format!("      grace: {}", duration_text(grace).unwrap()));
        }
        rule_lines.push("    action: trash".into());
        rule_lines.push(String::new());
    }
    if !rule_lines.is_empty() {
        rule_lines.pop();
        lines.push(String::new());
        lines.push("rules:".into());
        lines.extend(rule_lines);
    }

    let mut exception_lines: Vec<String> = Vec::new();
    let mut ordered: Vec<&crate::resolve::ItemPolicyOverride> = overrides.iter().collect();
    ordered.sort_by(|a, b| swift_cmp(&a.path, &b.path));
    for item in ordered {
        let crate::resolve::ItemOverridePolicy::Keep { protect_descendants } = item.policy else {
            skipped.push(format!("override {}: only Keep overrides can be expressed", item.path));
            continue;
        };
        if !root_paths.iter().any(|root| has_prefix(&item.path, &format!("{root}/"))) {
            skipped.push(format!("override {}: not inside a managed root", item.path));
            continue;
        }
        exception_lines.push(format!("  - path: {}", scalar(&item.path)));
        exception_lines.push(format!("    protect: {}", if protect_descendants { "descendants" } else { "item" }));
    }
    if !exception_lines.is_empty() {
        lines.push(String::new());
        lines.push("exceptions:".into());
        lines.extend(exception_lines);
    }
    if !skipped.is_empty() {
        lines.push(String::new());
        lines.push("# Not exported (cannot be expressed in this format):".into());
        lines.extend(skipped.iter().map(|entry| format!("# - {}", entry.replace('\n', " "))));
    }
    lines.join("\n") + "\n"
}

fn unexpressible(rule: &LifetimeRule) -> Option<String> {
    if rule.match_mode != RuleMatchMode::Scoped {
        return Some("not a scoped rule".into());
    }
    if !rule.scope.recursive {
        return Some("not recursive".into());
    }
    if rule.action != FolderAction::TrashItem {
        return Some("action is not trash".into());
    }
    if name_of(rule.expiry_basis).is_none() {
        return Some(format!("expiry basis {}", rule.expiry_basis.as_str()));
    }
    if duration_text(rule.lifetime).is_none() || rule.grace_period.is_some_and(|grace| duration_text(grace).is_none()) {
        return Some("duration is not a whole number of minutes".into());
    }
    let matcher = &rule.matcher;
    if matcher.exact_names.is_empty() && matcher.glob_patterns.is_empty() {
        return Some("matches every item".into());
    }
    if matcher.exact_names.iter().any(|name| name.contains('/')) {
        return Some("name contains '/'".into());
    }
    if matcher.glob_patterns.iter().any(|glob| has_prefix(glob, "/")) {
        return Some("absolute glob".into());
    }
    if matcher.item_kind != ItemKind::FileOrDirectory && matcher.exact_names.is_empty() {
        return Some(format!("{}-only glob rule", matcher.item_kind.as_str()));
    }
    None
}

fn duration_text(duration: RuleDuration) -> Option<String> {
    let seconds = duration.0;
    if seconds != seconds.round() {
        return None;
    }
    [("w", 604_800.0), ("d", 86_400.0), ("h", 3_600.0), ("m", 60.0)]
        .iter()
        .find(|(_, unit)| seconds % unit == 0.0)
        .map(|(suffix, unit)| format!("{}{suffix}", (seconds / unit) as i64))
}

/// A value is written bare only when it is plain ASCII word-ish text (ICU `$` also tolerates one trailing line
/// terminator, which is reproduced); anything else is double-quoted with `\\` and `\"` escapes.
fn scalar(value: &str) -> String {
    let body = ["\r\n", "\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"]
        .iter()
        .find_map(|terminator| value.strip_suffix(terminator))
        .unwrap_or(value);
    let mut characters = body.chars();
    let first_ok = characters.next().is_some_and(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '/'));
    let rest_ok = characters.all(|c| c.is_ascii_alphanumeric() || matches!(c, ' ' | '_' | '.' | '/' | '+' | '@' | '(' | ')' | '-'));
    let plain = first_ok && rest_ok && !value.ends_with(' ') && !has_prefix(value, "~");
    if plain {
        return value.to_string();
    }
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

// MARK: Restricted YAML syntax

#[derive(Debug, Clone)]
pub(crate) struct Entry {
    key: String,
    value: Node,
    line: usize,
}

#[derive(Debug, Clone)]
pub(crate) enum Node {
    Scalar(String, usize),
    List(Vec<Node>, usize),
    Map(Vec<Entry>, usize),
}

impl Node {
    fn line(&self) -> usize {
        match self {
            Node::Scalar(_, line) | Node::List(_, line) | Node::Map(_, line) => *line,
        }
    }
}

mod syntax {
    use super::*;

    struct Line {
        number: usize,
        indent: usize,
        text: String,
    }

    fn clusters(text: &str) -> Vec<&str> {
        text.graphemes(true).collect()
    }

    /// `CharacterSet.whitespaces`: Unicode Zs plus tab.
    fn is_space(c: char) -> bool {
        c == '\t' || matches!(c, '\u{20}' | '\u{A0}' | '\u{1680}' | '\u{2000}'..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}')
    }

    fn trim(text: &str) -> &str {
        text.trim_matches(is_space)
    }

    pub fn parse(text: &str) -> Result<Node, ConfigError> {
        let mut parser = Parser { lines: tokenize(text)?, position: 0 };
        if parser.lines.is_empty() {
            return error(None, "The file is empty.");
        }
        let indent = parser.lines[0].indent;
        let node = parser.block(indent)?;
        if parser.position < parser.lines.len() {
            return error(parser.lines[parser.position].number, "Unexpected indentation.");
        }
        Ok(node)
    }

    fn tokenize(text: &str) -> Result<Vec<Line>, ConfigError> {
        let mut result = Vec::new();
        for (index, raw) in text.replace("\r\n", "\n").split('\n').enumerate() {
            let number = index + 1;
            let stripped = strip_comment(raw);
            let trimmed = trim(&stripped);
            if trimmed.is_empty() {
                continue;
            }
            let leading: Vec<&str> = clusters(&stripped).into_iter().take_while(|c| *c == " " || *c == "\t").collect();
            if leading.contains(&"\t") {
                return error(number, "Tabs are not allowed for indentation.");
            }
            if trimmed == "---" || trimmed == "..." {
                return error(number, "Document markers are not supported.");
            }
            result.push(Line { number, indent: leading.len(), text: trimmed.to_string() });
        }
        Ok(result)
    }

    fn strip_comment(line: &str) -> String {
        let characters = clusters(line);
        let mut quote: Option<&str> = None;
        let mut previous = " ";
        let mut escaped = false;
        for (offset, character) in characters.iter().copied().enumerate() {
            if let Some(open) = quote {
                if open == "\"" && character == "\\" && !escaped {
                    escaped = true;
                    continue;
                }
                if character == open && !escaped {
                    quote = None;
                }
                escaped = false;
            } else if (character == "\"" || character == "'") && (matches!(previous, " " | "[" | "," | ":") || offset == 0) {
                quote = Some(character);
            } else if character == "#" && (previous == " " || offset == 0) {
                return characters[..offset].concat();
            }
            previous = character;
        }
        line.to_string()
    }

    struct Parser {
        lines: Vec<Line>,
        position: usize,
    }

    fn is_dash(text: &str) -> bool {
        text == "-" || has_prefix(text, "- ")
    }

    impl Parser {
        fn block(&mut self, indent: usize) -> Result<Node, ConfigError> {
            let line = &self.lines[self.position];
            if line.indent != indent {
                return error(line.number, "Unexpected indentation.");
            }
            if is_dash(&line.text) { self.list(indent) } else { self.map(indent) }
        }

        fn list(&mut self, indent: usize) -> Result<Node, ConfigError> {
            let first = self.lines[self.position].number;
            let mut items = Vec::new();
            while self.position < self.lines.len() && self.lines[self.position].indent == indent {
                let (number, text) = (self.lines[self.position].number, self.lines[self.position].text.clone());
                if !is_dash(&text) {
                    return error(number, "Expected a list item starting with '-'.");
                }
                let after_dash: Vec<&str> = clusters(&text).into_iter().skip(1).collect();
                let rest_clusters: Vec<&str> = after_dash.iter().copied().skip_while(|c| *c == " ").collect();
                let rest = rest_clusters.concat();
                let dash_width = clusters(&text).len() - rest_clusters.len();
                if rest.is_empty() {
                    self.position += 1;
                    if !(self.position < self.lines.len() && self.lines[self.position].indent > indent) {
                        return error(number, "Empty list item.");
                    }
                    let child_indent = self.lines[self.position].indent;
                    items.push(self.block(child_indent)?);
                } else if split_key(&rest).is_some() {
                    self.lines[self.position] = Line { number, indent: indent + dash_width, text: rest };
                    items.push(self.map(indent + dash_width)?);
                } else {
                    self.position += 1;
                    items.push(value(&rest, number)?);
                }
            }
            self.finish(indent)?;
            Ok(Node::List(items, first))
        }

        fn map(&mut self, indent: usize) -> Result<Node, ConfigError> {
            let first = self.lines[self.position].number;
            let mut entries: Vec<Entry> = Vec::new();
            while self.position < self.lines.len() && self.lines[self.position].indent == indent {
                let (number, text) = (self.lines[self.position].number, self.lines[self.position].text.clone());
                if is_dash(&text) {
                    return error(number, "Unexpected list item; expected 'key: value'.");
                }
                let Some((key, rest)) = split_key(&text) else {
                    return error(number, "Expected 'key: value'.");
                };
                if entries.iter().any(|entry| canonical_eq(&entry.key, &key)) {
                    return error(number, format!("Duplicate key '{key}'."));
                }
                self.position += 1;
                let node = if !rest.is_empty() {
                    value(&rest, number)?
                } else if self.position < self.lines.len() && self.lines[self.position].indent > indent {
                    let child_indent = self.lines[self.position].indent;
                    self.block(child_indent)?
                } else if self.position < self.lines.len() && self.lines[self.position].indent == indent && is_dash(&self.lines[self.position].text) {
                    self.list(indent)?
                } else {
                    return error(number, format!("Key '{key}' has no value."));
                };
                entries.push(Entry { key, value: node, line: number });
            }
            self.finish(indent)?;
            Ok(Node::Map(entries, first))
        }

        fn finish(&self, indent: usize) -> Result<(), ConfigError> {
            if self.position < self.lines.len() && self.lines[self.position].indent > indent {
                return error(self.lines[self.position].number, "Unexpected indentation.");
            }
            Ok(())
        }
    }

    /// Splits `key: rest` at the first colon outside quotes that is followed by a space or end of line.
    fn split_key(text: &str) -> Option<(String, String)> {
        let characters = clusters(text);
        let mut quote: Option<&str> = None;
        let mut index = 0;
        while index < characters.len() {
            let character = characters[index];
            if let Some(open) = quote {
                if open == "\"" && character == "\\" {
                    index += 2;
                    continue;
                }
                if character == open {
                    quote = None;
                }
            } else if (character == "\"" || character == "'") && index == 0 {
                quote = Some(character);
            } else if character == ":" && (index + 1 == characters.len() || characters[index + 1] == " ") {
                let key = trim(&characters[..index].concat()).to_string();
                let rest = trim(&characters[index + 1..].concat()).to_string();
                if key.is_empty() {
                    return None;
                }
                return scalar_text(&key, 0).ok().map(|unquoted| (unquoted, rest));
            } else if character == "[" || character == "{" {
                return None;
            }
            index += 1;
        }
        None
    }

    fn value(text: &str, line: usize) -> Result<Node, ConfigError> {
        if has_prefix(text, "{") {
            return error(line, "Inline mappings are not supported; use an indented block.");
        }
        if !has_prefix(text, "[") {
            return Ok(Node::Scalar(scalar_text(text, line)?, line));
        }
        let characters = clusters(text);
        if characters.last() != Some(&"]") {
            return error(line, "Unterminated inline list.");
        }
        let inner = &characters[1..characters.len() - 1];
        let mut items = Vec::new();
        let mut current = String::new();
        let mut quote: Option<&str> = None;
        let mut escaped = false;
        for character in inner.iter().copied() {
            if let Some(open) = quote {
                current.push_str(character);
                if open == "\"" && character == "\\" && !escaped {
                    escaped = true;
                    continue;
                }
                if character == open && !escaped {
                    quote = None;
                }
                escaped = false;
            } else if (character == "\"" || character == "'") && trim(&current).is_empty() {
                quote = Some(character);
                current.push_str(character);
            } else if character == "," {
                items.push(Node::Scalar(scalar_text(trim(&current), line)?, line));
                current.clear();
            } else {
                current.push_str(character);
            }
        }
        let last = trim(&current);
        if !last.is_empty() {
            items.push(Node::Scalar(scalar_text(last, line)?, line));
        }
        Ok(Node::List(items, line))
    }

    fn scalar_text(text: &str, line: usize) -> Result<String, ConfigError> {
        let characters = clusters(text);
        let Some(first) = characters.first().copied() else { return error(line, "Empty value.") };
        if first == "\"" {
            if characters.len() < 2 || characters.last() != Some(&"\"") {
                return error(line, "Unterminated quoted string.");
            }
            let mut result = String::new();
            let mut iterator = characters[1..characters.len() - 1].iter().copied();
            while let Some(character) = iterator.next() {
                if character == "\\" {
                    match iterator.next() {
                        Some(next) if next == "\"" || next == "\\" => result.push_str(next),
                        _ => return error(line, "Only \\\" and \\\\ escapes are supported."),
                    }
                } else if character == "\"" {
                    return error(line, "Unescaped quote inside quoted string.");
                } else {
                    result.push_str(character);
                }
            }
            return Ok(result);
        }
        if first == "'" {
            if characters.len() < 2 || characters.last() != Some(&"'") {
                return error(line, "Unterminated quoted string.");
            }
            return Ok(characters[1..characters.len() - 1].concat().replace("''", "'"));
        }
        if first.chars().count() == 1 && "&*!|>%@`".contains(first) {
            return error(line, format!("Unquoted values cannot start with '{first}'; wrap the value in quotes."));
        }
        Ok(text.to_string())
    }
}
