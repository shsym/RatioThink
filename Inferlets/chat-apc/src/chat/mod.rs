//! Data-plane (chat) handlers.
//!
//! Owns every user of `instruct::chat`, `instruct::tool-use`,
//! `instruct::reasoning`, and `mcp::client`. The control-plane
//! ([`crate::control`]) must not import any of those — keeping them
//! corralled here is what makes the eventual split into a separate
//! wasm tractable.

pub mod apc;
pub mod completions;
pub mod dispatch;
pub mod generate;
pub mod prefix_cache;
pub mod spec;
