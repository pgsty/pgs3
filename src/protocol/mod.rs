//! PostgreSQL-independent S3 wire-protocol primitives.
//!
//! This module deliberately has no `pgrx` imports.  HTTP workers can use it at
//! the network boundary, while ordinary Rust unit tests exercise the dangerous
//! parsing and authentication paths without starting PostgreSQL.

pub mod chunked;
pub mod headers;
pub mod http;
pub mod sigv4;
pub mod xml;
