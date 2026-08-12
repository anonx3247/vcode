module vc

pub struct SseMessage {
pub:
	event string
	data  string
	id    string
}

pub struct SseParser {
pub:
	max_event_bytes int = 1024 * 1024
pub mut:
	buffer string
}

pub fn new_sse_parser(max_event_bytes int) SseParser {
	return SseParser{
		max_event_bytes: if max_event_bytes > 0 { max_event_bytes } else { 1024 * 1024 }
	}
}

pub fn (mut parser SseParser) feed(fragment string) ![]SseMessage {
	parser.buffer = (parser.buffer + fragment).replace('\r\n', '\n')
	if parser.buffer.len > parser.max_event_bytes {
		return error('SSE event exceeds ${parser.max_event_bytes} bytes')
	}
	mut events := []SseMessage{}
	for parser.buffer.contains('\n\n') {
		index := parser.buffer.index('\n\n') or { break }
		block := parser.buffer[..index]
		parser.buffer = parser.buffer[index + 2..]
		mut kind := 'message'
		mut id := ''
		mut data := []string{}
		for line in block.split('\n') {
			if line.starts_with(':') { continue
			 }
			field := line.all_before(':')
			value := if line.contains(':') { line.all_after(':').trim_left(' ') } else { '' }
			match field {
				'event' { kind = value }
				'data' { data << value }
				'id' { id = value }
				else {}
			}
		}
		if data.len > 0 {
			events << SseMessage{
				event: kind
				data:  data.join('\n')
				id:    id
			}
		}
	}
	return events
}

pub fn (parser &SseParser) finish() ! {
	if parser.buffer.trim_space() != '' {
		return error('incomplete SSE event')
	}
}
