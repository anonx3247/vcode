module vc

import json
import os
import time

pub struct SessionMeta {
pub mut:
	id         string
	model      string
	effort     string
	cwd        string
	recap      string
	created_ms i64
	updated_ms i64
}

pub fn state_dir() string {
	base := os.getenv_opt('XDG_STATE_HOME') or { os.join_path(os.home_dir(), '.local', 'state') }
	return os.join_path(base, 'vc')
}

pub fn new_session_meta(model string, effort string, cwd string) SessionMeta {
	now := time.now().unix_milli()
	return SessionMeta{
		id:         '${now:x}-${os.getpid():x}'
		model:      model
		effort:     effort
		cwd:        os.real_path(cwd)
		created_ms: now
		updated_ms: now
	}
}

pub fn session_dir(id string) string {
	return os.join_path(state_dir(), 'sessions', id)
}

pub fn save_session_meta(meta SessionMeta) ! {
	dir := session_dir(meta.id)
	os.mkdir_all(dir)!
	path := os.join_path(dir, 'session.json')
	tmp := '${path}.tmp'
	os.write_file(tmp, json.encode_pretty(meta))!
	os.mv(tmp, path)!
}

pub fn load_session_meta(id string) !SessionMeta {
	return json.decode(SessionMeta, os.read_file(os.join_path(session_dir(id), 'session.json'))!)!
}

pub fn list_sessions() ![]SessionMeta {
	root := os.join_path(state_dir(), 'sessions')
	if !os.exists(root) {
		return []
	}
	mut sessions := []SessionMeta{}
	for name in os.ls(root)! {
		meta := load_session_meta(name) or { continue }
		sessions << meta
	}
	sessions.sort(a.updated_ms > b.updated_ms)
	return sessions
}
