//! Gitignore-style glob matching, equivalent to the Swift `GlobPattern` (an anchored `NSRegularExpression`).
//!
//! `*` any run of scalars except `/`, `?` exactly one scalar except `/`, `**/` zero or more directories,
//! a `**` not followed by `/` anything. No character classes, braces, negation, escapes, or normalization:
//! matching runs over raw Unicode scalars, case-sensitively. Matching is a memoized DP, so adversarial patterns
//! cannot go exponential.

use crate::swiftstr::{contains_slash, drop_first, has_prefix};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Debug, Clone, PartialEq, Eq)]
enum Token {
    Literal(Vec<char>),
    Star,
    Question,
    /// `**/`
    AnyDirs,
    /// `**` not followed by `/`
    AnyRun,
}

#[derive(Debug, Clone)]
pub struct Glob {
    pub pattern: String,
    /// True when the pattern has no `/`, so it matches by basename at any depth.
    pub matches_basename: bool,
    tokens: Vec<Token>,
}

impl Glob {
    pub fn new(pattern: &str) -> Glob {
        let anchored = if has_prefix(pattern, "/") { drop_first(pattern, 1) } else { pattern.to_string() };
        Glob {
            pattern: pattern.to_string(),
            matches_basename: !contains_slash(pattern),
            tokens: compile(&anchored),
        }
    }

    /// Match the whole `value` against the pattern.
    pub fn matches(&self, value: &str) -> bool {
        let subject: Vec<char> = value.chars().collect();
        let width = subject.len() + 1;
        let mut memo: Vec<Option<bool>> = vec![None; (self.tokens.len() + 1) * width];
        search(&self.tokens, 0, &subject, 0, width, &mut memo)
    }

    /// Item-level match: basename patterns test `name`; patterns containing `/` test `relative_path`.
    pub fn matches_item(&self, name: &str, relative_path: &str) -> bool {
        self.matches(if self.matches_basename { name } else { relative_path })
    }
}

fn compile(pattern: &str) -> Vec<Token> {
    let clusters: Vec<&str> = pattern.graphemes(true).collect();
    let mut tokens: Vec<Token> = Vec::new();
    let mut index = 0;
    while index < clusters.len() {
        match clusters[index] {
            "*" => {
                if clusters.get(index + 1) == Some(&"*") {
                    if clusters.get(index + 2) == Some(&"/") {
                        tokens.push(Token::AnyDirs);
                        index += 3;
                    } else {
                        tokens.push(Token::AnyRun);
                        index += 2;
                    }
                } else {
                    tokens.push(Token::Star);
                    index += 1;
                }
            }
            "?" => {
                tokens.push(Token::Question);
                index += 1;
            }
            other => {
                match tokens.last_mut() {
                    Some(Token::Literal(run)) => run.extend(other.chars()),
                    _ => tokens.push(Token::Literal(other.chars().collect())),
                }
                index += 1;
            }
        }
    }
    tokens
}

fn search(tokens: &[Token], ti: usize, subject: &[char], si: usize, width: usize, memo: &mut Vec<Option<bool>>) -> bool {
    if let Some(cached) = memo[ti * width + si] {
        return cached;
    }
    let result = if ti == tokens.len() {
        si == subject.len()
    } else {
        match &tokens[ti] {
            Token::Literal(run) => {
                subject[si..].starts_with(run) && search(tokens, ti + 1, subject, si + run.len(), width, memo)
            }
            Token::Question => {
                si < subject.len() && subject[si] != '/' && search(tokens, ti + 1, subject, si + 1, width, memo)
            }
            Token::Star => {
                let mut end = si;
                loop {
                    if search(tokens, ti + 1, subject, end, width, memo) {
                        break true;
                    }
                    if end < subject.len() && subject[end] != '/' {
                        end += 1;
                    } else {
                        break false;
                    }
                }
            }
            Token::AnyRun => (si..=subject.len()).any(|end| search(tokens, ti + 1, subject, end, width, memo)),
            Token::AnyDirs => {
                search(tokens, ti + 1, subject, si, width, memo)
                    || (si..subject.len()).any(|end| subject[end] == '/' && search(tokens, ti + 1, subject, end + 1, width, memo))
            }
        }
    };
    memo[ti * width + si] = Some(result);
    result
}
