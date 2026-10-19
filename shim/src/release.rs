//! The release this executable belongs to.
//!
//! The shim ships as `<root>/bin/pharos` inside an assembled Erlang
//! release (`<root>/erts-*/`, `<root>/lib/`, `<root>/releases/`), so it
//! finds the release from its own resolved path and works unchanged in
//! an npm package and in the versioned install layout.
//! `PHAROS_RELEASE_ROOT` overrides that, for development against
//! `_build/prod/rel/pharos`.

use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub struct Release {
    pub root: PathBuf,
    pub erts_version: String,
    pub version: String,
    /// `<root>/BUILD_ID`: the first 16 hex digits of a SHA-256 over the
    /// release tree and this executable, written at packaging time
    /// (ADR-034). Keys the daemon socket, so a rebuilt release never
    /// joins a daemon running different code.
    pub build_id: String,
}

impl Release {
    pub fn locate() -> io::Result<Release> {
        let root = match env::var_os("PHAROS_RELEASE_ROOT") {
            Some(root) if !root.is_empty() => PathBuf::from(root),
            _ => {
                let exe = env::current_exe()?.canonicalize()?;
                exe.parent()
                    .and_then(Path::parent)
                    .map(Path::to_path_buf)
                    .ok_or_else(|| other("cannot find the release next to this executable"))?
            }
        };
        Release::at(root)
    }

    pub fn at(root: PathBuf) -> io::Result<Release> {
        let start = root.join("releases").join("start_erl.data");
        let data = fs::read_to_string(&start)
            .map_err(|e| other(&format!("{}: {}", start.display(), e)))?;
        let mut fields = data.split_whitespace();
        let (erts_version, version) = match (fields.next(), fields.next()) {
            (Some(erts), Some(vsn)) => (erts.to_string(), vsn.to_string()),
            _ => {
                return Err(other(&format!(
                    "{}: expected \"<erts> <version>\"",
                    start.display()
                )))
            }
        };
        let id_path = root.join("BUILD_ID");
        let build_id = fs::read_to_string(&id_path)
            .map_err(|e| other(&format!("{}: {}", id_path.display(), e)))?
            .trim()
            .to_string();
        if build_id.is_empty() || !build_id.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Err(other(&format!("{}: not a build id", id_path.display())));
        }
        Ok(Release {
            root,
            erts_version,
            version,
            build_id,
        })
    }

    pub fn erts_bin(&self) -> PathBuf {
        self.root
            .join(format!("erts-{}", self.erts_version))
            .join("bin")
    }

    pub fn version_dir(&self) -> PathBuf {
        self.root.join("releases").join(&self.version)
    }
}

pub fn other(message: &str) -> io::Error {
    io::Error::other(message.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_release(build_id: &str) -> PathBuf {
        let root = env::temp_dir().join(format!(
            "pharos-shim-release-{}-{}",
            std::process::id(),
            build_id.len()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("releases")).unwrap();
        fs::write(root.join("releases/start_erl.data"), "16.1 0.2.0+abc").unwrap();
        fs::write(root.join("BUILD_ID"), build_id).unwrap();
        root
    }

    #[test]
    fn reads_versions_and_build_id() {
        let root = fake_release("0123456789abcdef\n");
        let release = Release::at(root.clone()).unwrap();
        assert_eq!(release.erts_version, "16.1");
        assert_eq!(release.version, "0.2.0+abc");
        assert_eq!(release.build_id, "0123456789abcdef");
        assert_eq!(release.erts_bin(), root.join("erts-16.1/bin"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn refuses_a_build_id_that_could_escape_a_file_name() {
        let root = fake_release("../x");
        assert!(Release::at(root.clone()).is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
