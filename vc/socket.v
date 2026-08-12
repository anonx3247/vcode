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
		mut buffer := []u8{len: 1024 * 1024}
		read := connection.read(mut buffer) or {
			connection.close() or {}
			continue
		}
		for line in buffer[..read].bytestr().split_into_lines() {
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
	mut buffer := []u8{len: 1024 * 1024}
	read := connection.read(mut buffer)!
	return buffer[..read].bytestr().trim_space()
}

pub fn start_session_worker(id string) ! {
	if os.exists(socket_path(id)) { return }
	mut process := os.new_process(os.executable())
	process.set_args(['--worker', id])
	process.set_redirect_stdio()
	process.run()
	for _ in 0 .. 100 {
		if os.exists(socket_path(id)) { return }
		time.sleep(10 * time.millisecond)
	}
	return error('worker did not create its socket')
}
