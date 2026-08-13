module vc

import json2
import os
import time

pub struct SessionMeta {
pub mut:
	id              string
	name            string
	model           string
	effort          string
	cwd             string
	recap           string
	recap_ms        i64
	context_percent int
	tools           []string
	created_ms      i64
	updated_ms      i64
}

pub fn resolve_session_meta(reference string) !SessionMeta {
	if reference == '' { return error('session id or name is required') }
	if os.exists(os.join_path(session_dir(reference), 'session.json')) {
		return load_session_meta(reference)
	}
	for session in list_sessions()! {
		if session.name == reference { return session }
	}
	return error('unknown session: ${reference}')
}

pub fn validate_session_name(name string, except_id string) !string {
	clean := name.trim_space()
	if clean == '' { return error('session name cannot be empty') }
	if clean.len > 64 { return error('session name cannot exceed 64 bytes') }
	for character in clean.bytes() {
		if !(character.is_alnum() || character in [`-`, `_`, `.`]) {
			return error('session name may contain only letters, numbers, ., _, and -')
		}
	}
	for session in list_sessions()! {
		if session.id != except_id && (session.name == clean || session.id == clean) {
			return error('session name is already in use: ${clean}')
		}
	}
	return clean
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
	os.write_file(tmp, json2.encode(meta, prettify: true, escape_unicode: true))!
	os.mv(tmp, path)!
}

pub fn load_session_meta(id string) !SessionMeta {
	return json2.decode[SessionMeta](os.read_file(os.join_path(session_dir(id), 'session.json'))!)!
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
