use thiserror::Error;

#[derive(Error, Debug)]
pub enum CodegenError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("operation has no name at {path}:{line}: only named operations are supported")]
    UnnamedOperation { path: String, line: usize },

    #[error("unsupported feature: {0}")]
    Unsupported(String),
}
