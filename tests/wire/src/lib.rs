//! PostgreSQL-independent unit-test harness.
//!
//! A pgrx extension cannot always link as a host test executable because
//! PostgreSQL provides symbols only when the shared library is loaded by the
//! postmaster.  This crate references the production wire modules directly;
//! there is no copied implementation and no PostgreSQL symbol dependency.

#![allow(dead_code)]

#[path = "../../../src/protocol/mod.rs"]
pub mod protocol;

pub mod s3;
