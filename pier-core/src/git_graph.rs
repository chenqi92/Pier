//! Git Graph — direct `.git` access via libgit2 for high-performance graph data.
//!
//! Replaces process-spawned `git log`, `git branch`, etc. with in-process reads.

use git2::{BranchType, Repository, Sort, Time};
use serde::Serialize;
use std::collections::HashSet;
use std::path::Path;

// ═══════════════════════════════════════════════════════════
// Data types
// ═══════════════════════════════════════════════════════════

/// Filter options for graph log queries.
pub struct GraphFilter {
    pub branch: Option<String>,
    pub author: Option<String>,
    pub search_text: Option<String>,
    pub after_timestamp: i64, // 0 = no filter
    pub topo_order: bool,
    pub first_parent_only: bool,
    pub no_merges: bool,
    pub paths: Vec<String>,
}

#[derive(Serialize)]
pub struct CommitEntry {
    pub hash: String,
    pub parents: String,
    pub short_hash: String,
    pub refs: String,
    pub message: String,
    pub author: String,
    pub date_relative: String,
}

// ═══════════════════════════════════════════════════════════
// Helper: relative date formatting
// ═══════════════════════════════════════════════════════════

fn format_relative_time(commit_time: &Time) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let diff = now - commit_time.seconds();
    if diff < 0 {
        return "in the future".to_string();
    }
    let diff = diff as u64;
    if diff < 60 {
        return format!("{} seconds ago", diff);
    }
    let minutes = diff / 60;
    if minutes < 60 {
        return format!("{} minute{} ago", minutes, if minutes == 1 { "" } else { "s" });
    }
    let hours = diff / 3600;
    if hours < 24 {
        return format!("{} hour{} ago", hours, if hours == 1 { "" } else { "s" });
    }
    let days = diff / 86400;
    if days < 7 {
        return format!("{} day{} ago", days, if days == 1 { "" } else { "s" });
    }
    let weeks = days / 7;
    if weeks < 5 {
        return format!("{} week{} ago", weeks, if weeks == 1 { "" } else { "s" });
    }
    let months = days / 30;
    if months < 12 {
        return format!("{} month{} ago", months, if months == 1 { "" } else { "s" });
    }
    let years = days / 365;
    format!("{} year{} ago", years, if years == 1 { "" } else { "s" })
}

// ═══════════════════════════════════════════════════════════
// Helper: build ref decoration string for a commit
// ═══════════════════════════════════════════════════════════

fn build_ref_decoration(repo: &Repository, commit_id: git2::Oid) -> String {
    let mut decorations = Vec::new();

    // Check HEAD
    if let Ok(head) = repo.head() {
        if let Some(target) = head.target() {
            if target == commit_id {
                if head.is_branch() {
                    if let Some(name) = head.shorthand() {
                        decorations.push(format!("HEAD -> {}", name));
                    } else {
                        decorations.push("HEAD".to_string());
                    }
                } else {
                    decorations.push("HEAD".to_string());
                }
            }
        }
    }

    // Check branches
    if let Ok(branches) = repo.branches(None) {
        for branch_result in branches {
            if let Ok((branch, _btype)) = branch_result {
                if let Ok(Some(reference)) = branch.get().resolve().map(|r| r.target()) {
                    if reference == commit_id {
                        if let Ok(Some(name)) = branch.name() {
                            // Skip if already added as HEAD ->
                            if !decorations.iter().any(|d| d.contains(name)) {
                                decorations.push(name.to_string());
                            }
                        }
                    }
                }
            }
        }
    }

    // Check tags
    if let Ok(tags) = repo.tag_names(None) {
        for tag_name in tags.iter().flatten() {
            if let Ok(reference) = repo.find_reference(&format!("refs/tags/{}", tag_name)) {
                let target = if let Ok(tag) = reference.peel_to_commit() {
                    tag.id()
                } else if let Some(t) = reference.target() {
                    t
                } else {
                    continue;
                };
                if target == commit_id {
                    decorations.push(format!("tag: {}", tag_name));
                }
            }
        }
    }

    if decorations.is_empty() {
        String::new()
    } else {
        format!(" ({})", decorations.join(", "))
    }
}

// ═══════════════════════════════════════════════════════════
// Core functions
// ═══════════════════════════════════════════════════════════

/// Load commit graph data with filters. Returns a list of CommitEntry.
pub fn graph_log(
    repo_path: &str,
    limit: usize,
    skip: usize,
    filter: &GraphFilter,
) -> Result<Vec<CommitEntry>, String> {
    let repo = Repository::open(repo_path).map_err(|e| format!("Failed to open repo: {}", e))?;

    let mut revwalk = repo.revwalk().map_err(|e| format!("Failed to create revwalk: {}", e))?;

    // Sort order
    if filter.topo_order {
        revwalk.set_sorting(Sort::TOPOLOGICAL | Sort::TIME).ok();
    } else {
        revwalk.set_sorting(Sort::TIME).ok();
    }

    // First-parent only
    if filter.first_parent_only {
        revwalk.simplify_first_parent().ok();
    }

    // Push starting points
    if let Some(ref branch_name) = filter.branch {
        // Specific branch
        if let Ok(reference) = repo.find_reference(&format!("refs/heads/{}", branch_name))
            .or_else(|_| repo.find_reference(&format!("refs/remotes/{}", branch_name)))
            .or_else(|_| repo.find_reference(branch_name))
        {
            if let Some(target) = reference.target() {
                revwalk.push(target).ok();
            } else if let Ok(resolved) = reference.resolve() {
                if let Some(target) = resolved.target() {
                    revwalk.push(target).ok();
                }
            }
        } else if let Ok(oid) = git2::Oid::from_str(branch_name) {
            revwalk.push(oid).ok();
        }
    } else {
        // All branches
        revwalk.push_glob("refs/heads/*").ok();
        revwalk.push_glob("refs/remotes/*").ok();
        // Also push tags
        revwalk.push_glob("refs/tags/*").ok();
    }

    // Path filter: if paths are specified, we need to check diff for each commit
    let has_path_filter = !filter.paths.is_empty();

    let mut results = Vec::with_capacity(limit);
    let mut skipped = 0;

    for oid_result in revwalk {
        let oid = match oid_result {
            Ok(o) => o,
            Err(_) => continue,
        };

        let commit = match repo.find_commit(oid) {
            Ok(c) => c,
            Err(_) => continue,
        };

        // Filter: no merges
        if filter.no_merges && commit.parent_count() > 1 {
            continue;
        }

        // Filter: author
        if let Some(ref author_filter) = filter.author {
            let commit_author = commit.author().name().unwrap_or("").to_lowercase();
            if !commit_author.contains(&author_filter.to_lowercase()) {
                continue;
            }
        }

        // Filter: after date
        if filter.after_timestamp > 0 {
            if commit.time().seconds() < filter.after_timestamp {
                continue;
            }
        }

        // Filter: search text (grep message or match hash)
        if let Some(ref search) = filter.search_text {
            let search_lower = search.to_lowercase();
            let msg = commit.message().unwrap_or("").to_lowercase();
            let hash_str = oid.to_string().to_lowercase();
            if !msg.contains(&search_lower) && !hash_str.starts_with(&search_lower) {
                continue;
            }
        }

        // Filter: paths — check if commit touches any filtered path
        if has_path_filter {
            let touches_path = commit_touches_paths(&repo, &commit, &filter.paths);
            if !touches_path {
                continue;
            }
        }

        // Skip N commits
        if skipped < skip {
            skipped += 1;
            continue;
        }

        // Build entry
        let hash = oid.to_string();
        let short_hash = hash[..7.min(hash.len())].to_string();
        let parents = (0..commit.parent_count())
            .filter_map(|i| commit.parent_id(i).ok())
            .map(|pid| pid.to_string())
            .collect::<Vec<_>>()
            .join(" ");
        let refs_str = build_ref_decoration(&repo, oid);
        let message = commit.summary().unwrap_or("").to_string();
        let author = commit.author().name().unwrap_or("").to_string();
        let date_relative = format_relative_time(&commit.time());

        results.push(CommitEntry {
            hash,
            parents,
            short_hash,
            refs: refs_str,
            message,
            author,
            date_relative,
        });

        if results.len() >= limit {
            break;
        }
    }

    Ok(results)
}

/// Check if a commit touches any of the specified paths.
fn commit_touches_paths(repo: &Repository, commit: &git2::Commit, paths: &[String]) -> bool {
    let tree = match commit.tree() {
        Ok(t) => t,
        Err(_) => return false,
    };

    if commit.parent_count() == 0 {
        // Root commit: check if any path exists in the tree
        for path in paths {
            if tree.get_path(Path::new(path)).is_ok() {
                return true;
            }
        }
        return false;
    }

    // Compare with first parent
    let parent_tree = match commit.parent(0).and_then(|p| p.tree()) {
        Ok(t) => t,
        Err(_) => return false,
    };

    let diff = match repo.diff_tree_to_tree(Some(&parent_tree), Some(&tree), None) {
        Ok(d) => d,
        Err(_) => return false,
    };

    for delta in diff.deltas() {
        let old_path = delta.old_file().path().and_then(|p| p.to_str()).unwrap_or("");
        let new_path = delta.new_file().path().and_then(|p| p.to_str()).unwrap_or("");
        for filter_path in paths {
            if old_path.starts_with(filter_path.as_str()) || new_path.starts_with(filter_path.as_str()) {
                return true;
            }
        }
    }
    false
}

/// Get the first-parent chain hashes for a given ref.
pub fn first_parent_chain(
    repo_path: &str,
    ref_name: &str,
    limit: usize,
) -> Result<Vec<String>, String> {
    let repo = Repository::open(repo_path).map_err(|e| format!("Failed to open repo: {}", e))?;

    let mut revwalk = repo.revwalk().map_err(|e| format!("Failed to create revwalk: {}", e))?;
    revwalk.set_sorting(Sort::TOPOLOGICAL | Sort::TIME).ok();
    revwalk.simplify_first_parent().ok();

    // Push the ref
    if let Ok(reference) = repo.find_reference(&format!("refs/heads/{}", ref_name))
        .or_else(|_| repo.find_reference(&format!("refs/remotes/{}", ref_name)))
        .or_else(|_| repo.find_reference(ref_name))
    {
        if let Some(target) = reference.target() {
            revwalk.push(target).ok();
        } else if let Ok(resolved) = reference.resolve() {
            if let Some(target) = resolved.target() {
                revwalk.push(target).ok();
            }
        }
    } else if ref_name == "HEAD" {
        revwalk.push_head().ok();
    } else if let Ok(oid) = git2::Oid::from_str(ref_name) {
        revwalk.push(oid).ok();
    }

    let mut hashes = Vec::with_capacity(limit);
    for oid_result in revwalk {
        if let Ok(oid) = oid_result {
            hashes.push(oid.to_string());
            if hashes.len() >= limit {
                break;
            }
        }
    }
    Ok(hashes)
}

/// List all branch names (local + remote).
pub fn list_branches(repo_path: &str) -> Result<Vec<String>, String> {
    let repo = Repository::open(repo_path).map_err(|e| format!("Failed to open repo: {}", e))?;

    let mut names = Vec::new();
    if let Ok(branches) = repo.branches(Some(BranchType::Local)) {
        for b in branches.flatten() {
            if let Ok(Some(name)) = b.0.name() {
                names.push(name.to_string());
            }
        }
    }
    if let Ok(branches) = repo.branches(Some(BranchType::Remote)) {
        for b in branches.flatten() {
            if let Ok(Some(name)) = b.0.name() {
                names.push(name.to_string());
            }
        }
    }
    names.sort();
    Ok(names)
}

/// List unique commit authors.
pub fn list_authors(repo_path: &str, limit: usize) -> Result<Vec<String>, String> {
    let repo = Repository::open(repo_path).map_err(|e| format!("Failed to open repo: {}", e))?;

    let mut revwalk = repo.revwalk().map_err(|e| format!("Revwalk error: {}", e))?;
    revwalk.set_sorting(Sort::TIME).ok();
    revwalk.push_glob("refs/heads/*").ok();
    revwalk.push_glob("refs/remotes/*").ok();

    let mut authors = HashSet::new();
    let mut count = 0;
    for oid_result in revwalk {
        if count >= limit { break; }
        if let Ok(oid) = oid_result {
            if let Ok(commit) = repo.find_commit(oid) {
                if let Some(name) = commit.author().name() {
                    authors.insert(name.to_string());
                }
                count += 1;
            }
        }
    }
    let mut result: Vec<_> = authors.into_iter().collect();
    result.sort();
    Ok(result)
}

/// List all tracked files (equivalent to `git ls-files`).
pub fn list_tracked_files(repo_path: &str) -> Result<Vec<String>, String> {
    let repo = Repository::open(repo_path).map_err(|e| format!("Failed to open repo: {}", e))?;

    // Read the HEAD tree recursively
    let head = repo.head().map_err(|e| format!("No HEAD: {}", e))?;
    let tree = head.peel_to_tree().map_err(|e| format!("No tree: {}", e))?;

    let mut files = Vec::new();
    tree.walk(git2::TreeWalkMode::PreOrder, |dir, entry| {
        if entry.kind() == Some(git2::ObjectType::Blob) {
            let path = if dir.is_empty() {
                entry.name().unwrap_or("").to_string()
            } else {
                format!("{}{}", dir, entry.name().unwrap_or(""))
            };
            files.push(path);
        }
        git2::TreeWalkResult::Ok
    }).ok();

    Ok(files)
}

/// Detect the default branch (main/master).
pub fn detect_default_branch(repo_path: &str) -> Result<String, String> {
    let repo = Repository::open(repo_path).map_err(|e| format!("Failed to open repo: {}", e))?;

    // Strategy 1: Check origin/HEAD symbolic ref
    if let Ok(reference) = repo.find_reference("refs/remotes/origin/HEAD") {
        if let Ok(resolved) = reference.resolve() {
            if let Some(name) = resolved.shorthand() {
                return Ok(name.to_string());
            }
        }
        // Try symbolic target
        if let Some(target) = reference.symbolic_target() {
            // refs/remotes/origin/master → origin/master
            if target.starts_with("refs/remotes/") {
                return Ok(target.trim_start_matches("refs/remotes/").to_string());
            }
        }
    }

    // Strategy 2: Try common remote tracking branches
    for name in &["origin/master", "origin/main"] {
        if repo.find_reference(&format!("refs/remotes/{}", name)).is_ok() {
            return Ok(name.to_string());
        }
    }

    // Strategy 3: Try local branches
    for name in &["master", "main"] {
        if repo.find_branch(name, BranchType::Local).is_ok() {
            return Ok(name.to_string());
        }
    }

    // Fallback
    Ok("HEAD".to_string())
}
