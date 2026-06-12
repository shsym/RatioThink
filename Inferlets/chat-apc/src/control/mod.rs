//! Control-plane handlers.
//!
//! Only touches `inferlet::runtime` (models, version, instance-id). No
//! chat-templating, sampling, or generator surface lives here — those belong
//! under [`crate::chat`]. (#469: the dead `/v1/models/load` pre-warm endpoint
//! was removed — pie binds its model at boot; `GET /v1/models` is the
//! served-model source of truth.)

pub mod health;
pub mod models;
