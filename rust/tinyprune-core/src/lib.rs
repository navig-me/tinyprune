//! Platform-neutral TinyPrune decision logic.
//!
//! The Swift `TinyPruneDomain` is the reference; `Fixtures/golden` is the contract (ADR 0010). Nothing here
//! touches the filesystem, the clock, or the network.

pub mod glob;
pub mod path;
pub mod resolve;
pub mod rule;
pub mod trash;
pub mod config;
pub mod swiftstr;
pub mod uuid;
pub mod config_plan;
pub mod roots;
pub mod templates;
pub mod scheduler;
