//! Static capability gate for the desktop host.
//!
//! Declaration is not authorization: node specs declare what they may need,
//! this policy rejects undeclared capability strings, and every network,
//! process, filesystem and tool target is separately approved by the runtime
//! permission manager before use. Credentials are resolved from the OS store
//! or an environment reference, never from workflow JSON.

use lingxi_runtime::{error_codes, CapabilityPolicy, CapabilityRequest, NodeError};
use lingxi_spec::node::capabilities;

pub struct DeclaredCapabilityPolicy;

impl CapabilityPolicy for DeclaredCapabilityPolicy {
    fn authorize(&self, request: &CapabilityRequest) -> Result<(), NodeError> {
        match request.capability {
            capabilities::INTERACTION
            | capabilities::NETWORK
            | capabilities::FILESYSTEM
            | capabilities::PROCESS
            | "credential"
            | "mcp" => Ok(()),
            other => Err(NodeError::new(
                error_codes::CAPABILITY_UNSUPPORTED,
                format!(
                    "node {} requested unsupported capability {other:?}",
                    request.node_id
                ),
            )),
        }
    }
}
