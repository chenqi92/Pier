use ignore::WalkBuilder;
use serde::{Serialize, Deserialize};
use std::path::Path;

/// A search result entry.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SearchResult {
    pub path: String,
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
}

/// Search for files/directories matching a pattern.
/// Uses the `ignore` crate (same engine as ripgrep) for respecting .gitignore.
pub fn search_files(
    root: &str,
    pattern: &str,
    max_results: usize,
) -> Vec<SearchResult> {
    let root_path = Path::new(root);
    if !root_path.exists() {
        return Vec::new();
    }

    let pattern_lower = pattern.to_lowercase();
    let mut results = Vec::new();

    let walker = WalkBuilder::new(root_path)
        .hidden(false)
        .git_ignore(true)
        .git_global(true)
        .max_depth(Some(10))
        .build();

    for entry in walker.flatten() {
        if results.len() >= max_results {
            break;
        }

        let path = entry.path();
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");

        if name.to_lowercase().contains(&pattern_lower) {
            let metadata = entry.metadata().ok();
            let is_dir = entry.file_type().map(|ft| ft.is_dir()).unwrap_or(false);
            let size = metadata.as_ref().map(|m| m.len()).unwrap_or(0);

            results.push(SearchResult {
                path: path.to_string_lossy().to_string(),
                name: name.to_string(),
                is_dir,
                size,
            });
        }
    }

    results
}

/// List directory contents (non-recursive).
pub fn list_directory(path: &str) -> Result<Vec<SearchResult>, std::io::Error> {
    let dir_path = Path::new(path);
    let mut entries = Vec::new();

    for entry in std::fs::read_dir(dir_path)? {
        let entry = entry?;
        let metadata = entry.metadata()?;
        let name = entry
            .file_name()
            .to_string_lossy()
            .to_string();

        entries.push(SearchResult {
            path: entry.path().to_string_lossy().to_string(),
            name,
            is_dir: metadata.is_dir(),
            size: metadata.len(),
        });
    }

    // Sort: directories first, then alphabetically
    entries.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_list_directory() {
        let result = list_directory("/tmp");
        assert!(result.is_ok());
    }

    #[test]
    fn test_search_nonexistent() {
        let results = search_files("/nonexistent_path_xyz", "test", 10);
        assert!(results.is_empty());
    }
}
