
#[macro_use]
extern crate emacs;
extern crate git2;
extern crate libc;

use emacs::ToLisp;
use emacs::FromLisp;
use emacs::HandleFunc;
use emacs::{Env, Result, Value};
use git2::Repository;
use std::collections::HashMap;

emacs_plugin_is_GPL_compatible!();
emacs_module_init!(init);

#[derive(Hash, Eq, PartialEq, Clone, Debug)]
struct File {
    path: String
}

impl<'a> From<git2::DiffFile<'a>> for File {
    fn from(h: git2::DiffFile<'a>) -> File {
        File {
            path: h.path().and_then(|p| p.to_str())
                          .and_then(|s| Some(s.to_owned()))
                          .unwrap_or_default()
        }
    }
}

#[derive(Hash, Eq, PartialEq, Clone, Debug)]
struct Hunk {
    header: String,
    new_start: u32,
    old_start: u32,
    new_lines: u32,
}

impl<'a> From<git2::DiffHunk<'a>> for Hunk {
    fn from(h: git2::DiffHunk<'a>) -> Hunk {

        let header = std::str::from_utf8(h.header())
            .and_then(|s| Ok(s.to_owned()))
            .unwrap_or_default();

        Hunk {
            header,
            new_start: h.new_start(),
            old_start: h.old_start(),
            new_lines: h.new_lines(),
        }
    }
}

impl ToLisp for Hunk {
    fn to_lisp(&self, env: &Env) -> Result<Value> {
        env.call("list", &[
            env.intern(":header")?,
            self.header.to_lisp(env)?,
            env.intern(":start")?,
            env.clone_to_lisp(self.new_start as i64)?,
            env.intern(":lines")?,
            env.clone_to_lisp(self.new_lines as i64)?
        ])
    }
}

#[derive(Eq, PartialEq, Clone, Debug)]
struct Line {
    content: String,
    kind: LineKind,
    line: Option<u32>,
}

#[derive(Eq, PartialEq, Clone, Debug)]
#[allow(non_camel_case_types)]
enum LineKind {
    addition,
    deletion,
    unused
}

impl<'a> From<git2::DiffLine<'a>> for Line {
    fn from(l: git2::DiffLine<'a>) -> Line {
        Line {
            content: std::str::from_utf8(l.content()).unwrap_or("").to_string(),
            kind: match l.origin() {
                '+' => LineKind::addition,
                '-' => LineKind::deletion,
                _ => LineKind::unused
            },
            line: l.new_lineno()
        }
    }
}

impl ToLisp for Line {
    fn to_lisp(&self, env: &Env) -> Result<Value> {
        env.call("list", &[
            env.intern(":content")?,
            self.content.to_lisp(env)?,
            env.intern(":kind")?,
            env.intern(&format!("{:?}", self.kind))?,
            env.intern(":line")?,
            if let Some(line) = self.line {
                env.clone_to_lisp(line as i64)?
            } else {
                env.intern("nil")?
            }
        ])
    }
}

struct Locale {
    save: *mut i8
}

impl Locale {
    fn init() -> Locale {
        unsafe {
            let save = libc::setlocale(libc::LC_ALL, std::ptr::null());
            libc::setlocale(libc::LC_ALL, b"C\0".as_ptr() as * const i8);
            Locale { save }
        }
    }
}

impl Drop for Locale {
    fn drop(&mut self) {
        unsafe {
            libc::setlocale(libc::LC_ALL, self.save);
        }
    }
}

fn get_diff(env: &mut Env, args: &[Value], _data: *mut libc::c_void) -> Result<Value> {

    let _locale = Locale::init();

    let mut filename: String = match args.first() {
        Some(filename) => filename.to_owned(env)?,
        _ => String::from_lisp(env, env.call("symbol-value", &[env.intern("buffer-file-name")?])?)?
    };

    let repo = match Repository::discover(&filename) {
        Ok(repo) => repo,
        _ => return env.intern("nil")
    };

    let mut options = git2::DiffOptions::new();
    options.context_lines(0);

    let workdir = repo.workdir().and_then(|wd| wd.to_str());
    if let Some(workdir) = workdir {
        filename = filename.trim_left_matches(workdir).to_string();
        options.pathspec(&filename);
    };

    let diff = match repo.diff_index_to_workdir(None, Some(&mut options)) {
        Ok(diff) => diff,
        _ => return env.intern("nil")
    };

    let mut hash = HashMap::new();

    let _ = diff.foreach(&mut |_, _| {
        true
    }, None, None, Some(&mut (|delta, hunk, line| {
        if let Some(hunk) = hunk {
            let file = File::from(delta.new_file());
            let file_entry = hash.entry(file).or_insert_with(HashMap::new);
            let hunk = Hunk::from(hunk);
            let hunk_entry = file_entry.entry(hunk).or_insert_with(Vec::new);
            hunk_entry.push(Line::from(line));
        };
        true
    })));

    let found = match hash.get(&File { path: filename }) {
        Some(map) => map,
        _ => return env.intern("nil")
    };

    let mut final_list = vec![];

    for (hunk, lines) in found.iter() {

        let mut list_line = vec![];
        for line in lines {
            list_line.push(line.to_lisp(env)?);
        }

        let hunk = env.call("cons", &[
            hunk.to_lisp(env)?,
            env.call("list", list_line.as_slice())?
        ])?;

        final_list.push(hunk);
    }

    env.call("list", final_list.as_slice())
}

pub fn init(env: &mut Env) -> Result<Value> {

    emacs_subrs!{
        get_diff -> _get_diff;
    }

    env.register(
        "git-tube-diff",
        _get_diff,
        0..1,
        "Return git diff of the file ARG1.\n
If ARG1 is nil, `buffer-file-name' is used.",
        std::ptr::null_mut(),
    )?;

    env.provide("git-tube-module")
}
