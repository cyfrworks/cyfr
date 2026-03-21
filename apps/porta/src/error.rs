use std::fmt;

#[derive(Debug)]
pub enum Error {
    DockerNotFound(String),
    DockerNotRunning(String),
    Container(String),
    Config(String),
    Gateway(String),
    Backend(String),
    Network(reqwest::Error),
    Io(std::io::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::DockerNotFound(msg) => write!(f, "Docker not found: {}", msg),
            Error::DockerNotRunning(msg) => write!(f, "Docker not running: {}", msg),
            Error::Container(msg) => write!(f, "Container error: {}", msg),
            Error::Config(msg) => write!(f, "Config error: {}", msg),
            Error::Gateway(msg) => write!(f, "Gateway error: {}", msg),
            Error::Backend(msg) => write!(f, "Backend error: {}", msg),
            Error::Network(e) => write!(f, "Network error: {}", e),
            Error::Io(e) => write!(f, "IO error: {}", e),
        }
    }
}

impl std::error::Error for Error {}

impl From<reqwest::Error> for Error {
    fn from(e: reqwest::Error) -> Self {
        Error::Network(e)
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

/// Convert to String for Tauri IPC command compatibility
impl From<Error> for String {
    fn from(e: Error) -> String {
        e.to_string()
    }
}
