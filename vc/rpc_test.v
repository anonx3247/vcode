module vc

import os

fn test_rpc_message_and_move() {
	old_state := os.getenv('XDG_STATE_HOME')
	tmp := os.join_path(os.temp_dir(), 'vc-rpc-${os.getpid()}')
	os.setenv('XDG_STATE_HOME', tmp, true)
	defer {
		os.setenv('XDG_STATE_HOME', old_state, true)
		os.rmdir_all(tmp) or {}
	}
	meta := new_session_meta('openai:test', 'low', os.temp_dir())
	save_session_meta(meta) or { panic(err) }
	mut worker := new_session_worker(meta) or { panic(err) }
	response :=
		worker.handle_rpc('{"jsonrpc":"2.0","id":1,"method":"session.message","params":{"message":"hello"}}')
	assert response.contains('"result"')
	assert worker.events.items.len == 1
	recap_response :=
		worker.handle_rpc('{"jsonrpc":"2.0","id":3,"method":"session.recap","params":{"recap":"Worked on history replay."}}')
	assert recap_response.contains('Worked on history replay.')
	assert worker.meta.recap == 'Worked on history replay.'
	assert worker.meta.recap_ms > 0
	mut restarted := new_session_worker(worker.meta) or { panic(err) }
	_ =
		restarted.handle_rpc('{"jsonrpc":"2.0","id":4,"method":"session.message","params":{"message":"again"}}')
	assert restarted.events.items[0].seq == 2
	worker.fingerprints['x'] = 'stale'
	moved :=
		worker.handle_rpc('{"jsonrpc":"2.0","id":2,"method":"session.move","params":{"cwd":"${json_escape(tmp)}"}}')
	assert moved.contains(tmp)
	assert worker.fingerprints.len == 0
}

fn test_rpc_parser_accepts_string_ids() {
	request := decode_rpc_request('{"jsonrpc":"2.0","id":"abc","method":"session.attach","params":{}}') or {
		panic(err)
	}
	assert request.id == '"abc"'
}
