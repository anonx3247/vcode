module vc

import net.unix
import os
import time

pub fn socket_path(id string) string {
	return os.join_path(session_dir(id), 'worker.sock')
}

pub fn serve_session(id string) ! {
	meta := load_session_meta(id)!
	mut worker := new_session_worker(meta)!
	path := socket_path(id)
	os.rm(path) or {}
	mut listener := unix.listen_stream(path)!
	defer { listener.close() or {} }
	for !worker.shutdown {
		mut connection := listener.accept() or { continue }
		payload := read_socket_line(mut connection, 2 * 1024 * 1024) or {
			connection.close() or {}
			continue
		}
		for line in payload.split_into_lines() {
			if line.trim_space() == '' { continue
			 }
			connection.write_string(worker.handle_rpc(line) + '\n') or { break }
		}
		connection.close() or {}
	}
}

pub fn socket_rpc(id string, request string) !string {
	mut connection := unix.connect_stream(socket_path(id))!
	defer { connection.close() or {} }
	connection.write_string(request + '\n')!
	return read_socket_line(mut connection, 2 * 1024 * 1024)!.trim_space()
}

fn read_socket_line(mut connection unix.StreamConn, max_bytes int) !string {
	mut result := ''
	mut buffer := []u8{len: 64 * 1024}
	for result.len <= max_bytes {
		read := connection.read(mut buffer)!
		if read <= 0 { break
		 }
		result += buffer[..read].bytestr()
		if result.contains('\n') { return result.all_before('\n') }
	}
	if result.len > max_bytes { return error('session RPC message exceeds ${max_bytes} bytes') }
	return result
}

pub fn start_session_worker(id string) ! {
	path := socket_path(id)
	if os.exists(path) {
		response := socket_rpc(id, '{"jsonrpc":"2.0","id":1,"method":"session.attach","params":{}}') or {
			''
		}
		if response.contains('"result"') { return }
		os.rm(path) or {}
	}
	mut process := os.new_process(os.executable())
	process.set_args(['--worker', id])
	$if windows {
		process.create_no_window = true
	} $else {
		process.use_pgroup = true
		process.set_stdin_path('/dev/null')
	}
	process.run()
	for _ in 0 .. 100 {
		if os.exists(path) { return }
		time.sleep(10 * time.millisecond)
	}
	return error('worker did not create its socket')
}

pub fn session_rpc(id string, request string) !string {
	start_session_worker(id)!
	response := socket_rpc(id, request) or {
		path := socket_path(id)
		os.rm(path) or {}
		start_session_worker(id)!
		socket_rpc(id, request)!
	}
	if response.contains('"error"') {
		message := json_field(response, 'message')
		return error(if message == '' { 'session worker request failed' } else { message })
	}
	return response
}
