module vc

import json2
import os
import time

pub struct RpcRequest {
pub:
	jsonrpc string
	id      string
	method  string
	params  string
}

pub struct RpcResponse {
pub:
	jsonrpc string = '2.0'
	id      string
	result  string
	error   string
}

pub struct SessionWorker {
pub mut:
	meta         SessionMeta
	events       EventRing
	journal      Journal
	cancelled    bool
	shutdown     bool
	instructions InstructionSet
	fingerprints map[string]string
}

pub fn new_session_worker(meta SessionMeta) !SessionWorker {
	dir := session_dir(meta.id)
	os.mkdir_all(dir)!
	journal := open_journal(os.join_path(dir, 'transcript.jsonl'))!
	mut events := new_event_ring(2048)
	for record in journal.read_recent(1024 * 1024)! {
		if record.seq >= events.next_seq { events.next_seq = record.seq + 1 }
	}
	return SessionWorker{
		meta:         meta
		events:       events
		journal:      journal
		instructions: load_instructions(meta.cwd)!
		fingerprints: map[string]string{}
	}
}

pub fn (mut worker SessionWorker) handle_rpc(line string) string {
	request := decode_rpc_request(line) or { return encode_rpc_error('', -32700, err.msg()) }
	result := worker.dispatch(request.method, request.params) or {
		return encode_rpc_error(request.id, -32000, err.msg())
	}
	return '{"jsonrpc":"2.0","id":${rpc_id(request.id)},"result":${result}}'
}

fn (mut worker SessionWorker) dispatch(method string, params string) !string {
	match method {
		'session.start' {
			model := json_field(params, 'model')
			cwd := json_field(params, 'cwd')
			meta := new_session_meta(if model == '' { worker.meta.model } else { model },
				worker.meta.effort, if cwd == '' { worker.meta.cwd } else { cwd })
			save_session_meta(meta)!
			return json2.encode(meta, escape_unicode: true)
		}
		'session.list' {
			return json2.encode(list_sessions()!, escape_unicode: true)
		}
		'session.attach' {
			return json2.encode(worker.meta, escape_unicode: true)
		}
		'session.message' {
			message := json_field(params, 'message')
			event := worker.events.push('user', message)
			worker.journal.append(event.seq, event.kind, event.data)!
			worker.meta.updated_ms = time.now().unix_milli()
			save_session_meta(worker.meta)!
			return json2.encode(event, escape_unicode: true)
		}
		'session.append' {
			kind := json_field(params, 'kind')
			data := json_field(params, 'data')
			if kind == '' { return error('kind is required') }
			event := worker.events.push(kind, data)
			worker.journal.append(event.seq, event.kind, event.data)!
			return json2.encode(event, escape_unicode: true)
		}
		'session.model' {
			model := json_field(params, 'model')
			parse_model_ref(model)!
			worker.meta.model = model
			worker.meta.updated_ms = time.now().unix_milli()
			save_session_meta(worker.meta)!
			return json2.encode(worker.meta, escape_unicode: true)
		}
		'session.recap' {
			recap :=
				sanitize_terminal(json_field(params, 'recap')).replace('\n', ' ').replace('\t', ' ').trim_space()
			if recap == '' { return error('recap is required') }
			worker.meta.recap = recap
			worker.meta.recap_ms = time.now().unix_milli()
			save_session_meta(worker.meta)!
			return json2.encode(worker.meta, escape_unicode: true)
		}
		'session.subscribe' {
			cursor := json_int_field(params, 'cursor')
			return json2.encode(worker.events.after(u64(cursor)), escape_unicode: true)
		}
		'session.read' {
			path := json_field(params, 'path')
			read := read_tool_range(path, json_int_field(params, 'start'), json_int_field(params,
				'end'), 1024 * 1024)!
			worker.fingerprints[read.path] = read.fingerprint
			return json2.encode(read, escape_unicode: true)
		}
		'session.cancel' {
			worker.cancelled = true
			return 'true'
		}
		'session.move' {
			path := os.real_path(json_field(params, 'cwd'))
			if !os.is_dir(path) { return error('target directory does not exist') }
			old := worker.meta.cwd
			worker.meta.cwd = path
			worker.meta.updated_ms = time.now().unix_milli()
			worker.instructions = load_instructions(path)!
			worker.fingerprints.clear()
			event := worker.events.push('system',
				'Session moved from ${old} to ${path}; local instructions were reloaded and Read fingerprints invalidated.')
			worker.journal.append(event.seq, event.kind, event.data)!
			save_session_meta(worker.meta)!
			return json2.encode(worker.meta, escape_unicode: true)
		}
		'session.shutdown' {
			worker.shutdown = true
			return 'true'
		}
		else {
			return error('unknown method: ${method}')
		}
	}
}

pub fn decode_rpc_request(line string) !RpcRequest {
	method := json_field(line, 'method')
	if method == '' { return error('missing method') }
	id := json_raw_field(line, 'id')
	params := json_object_field(line, 'params')
	return RpcRequest{
		jsonrpc: '2.0'
		id:      id
		method:  method
		params:  params
	}
}

fn rpc_id(raw string) string {
	if raw == '' { return 'null' }
	return raw
}

fn encode_rpc_error(id string, code int, message string) string {
	return '{"jsonrpc":"2.0","id":${rpc_id(id)},"error":{"code":${code},"message":"${json_escape(message)}"}}'
}

fn json_int_field(source string, name string) int {
	return json_field(source, name).int()
}

fn json_raw_field(source string, name string) string {
	needle := '"${name}"'
	start := source.index(needle) or { return '' }
	rest := source[start + needle.len..].trim_left(' \t\r\n:')
	if rest.starts_with('"') {
		value := json_field(source, name)
		return '"${json_escape(value)}"'
	}
	mut end := rest.len
	for separator in [',', '}'] {
		if index := rest.index(separator) {
			if index < end { end = index }
		}
	}
	return rest[..end].trim_space()
}

fn json_object_field(source string, name string) string {
	needle := '"${name}"'
	start := source.index(needle) or { return '{}' }
	rest := source[start + needle.len..].trim_left(' \t\r\n:')
	if !rest.starts_with('{') { return '{}' }
	mut depth := 0
	mut quoted := false
	mut escaped := false
	for index, character in rest.runes() {
		if escaped {
			escaped = false
			continue
		}
		if character == `\\` && quoted {
			escaped = true
			continue
		}
		if character == `"` {
			quoted = !quoted
			continue
		}
		if quoted { continue
		 }
		if character == `{` { depth++ }
		if character == `}` {
			depth--
			if depth == 0 { return rest[..index + 1] }
		}
	}
	return '{}'
}
