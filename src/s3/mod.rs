//! S3 request routing, authentication, and semantic-SQL translation.
//!
//! The socket worker owns HTTP framing.  This module accepts a parsed request
//! head and decoded HTTP entity bytes, and never retains PostgreSQL-owned
//! memory across a call.  All PostgreSQL access remains on the worker's main
//! thread through [`PgDatabase`].

#![allow(dead_code)]

mod db;
mod route;
mod service;
mod types;
mod xml;

#[allow(unused_imports)]
pub(crate) use db::PgDatabase;
pub(crate) use route::classify;
#[allow(unused_imports)]
pub(crate) use service::{BodySession, HeadOutcome, PgS3Service, ServiceConfig};
#[allow(unused_imports)]
pub(crate) use types::ServiceResponse;
