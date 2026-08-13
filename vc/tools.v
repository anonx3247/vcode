module vc

import crypto.sha256
import net.http
import os

pub struct ReadResult {
pub:
	path        string
	content     string
	fingerprint string
	truncated   bool
	start       int
	end         int
	total_lines int
}

pub fn read_tool(path string, max_bytes int) !ReadResult {
	return read_tool_range(path, 1, 3000, max_bytes)
}

pub fn read_tool_range(path string, requested_start int, requested_end int, max_bytes int) !ReadResult {
	real := os.real_path(path)
	content := os.read_file(real)!
	start := if requested_start > 0 { requested_start } else { 1 }
	end := if requested_end > 0 { requested_end } else { start + 2999 }
	if end < start { return error('Read end must be greater than or equal to start') }
	lines := content.split_into_lines()
	from := min_int(start - 1, lines.len)
	to := min_int(end, lines.len)
	selected := if from < to { lines[from..to].join('\n') } else { '' }
	limit := if max_bytes > 0 { max_bytes } else { 1024 * 1024 }
	shown := safe_text_prefix(selected, limit)
	return ReadResult{
		path:        real
		content:     shown
		fingerprint: sha256.hexhash(content)
		truncated:   start > 1 || to < lines.len || shown.len < selected.len
		start:       start
		end:         to
		total_lines: lines.len
	}
}

pub fn edit_tool(path string, old string, replacement string, fingerprint string) !string {
	if !os.exists(path) {
		if old != '' { return error('new file creation requires empty old text') }
		if fingerprint !in ['', '0'] {
			return error('new file creation does not accept a Read fingerprint')
		}
		tmp := '${path}.vc.create.${os.getpid()}'
		defer { os.rm(tmp) or {} }
		os.write_file(tmp, replacement)!
		os.link(tmp, path) or { return error('could not create new file: ${err.msg()}') }
		return sha256.hexhash(replacement)
	}
	if old == '' { return error('old text cannot be empty') }
	current := os.read_file(path)!
	if sha256.hexhash(current) != fingerprint { return error('file changed since Read') }
	if current.count(old) != 1 { return error('old text must occur exactly once') }
	updated := current.replace_once(old, replacement)
	tmp := '${path}.vc.tmp'
	os.write_file(tmp, updated)!
	os.mv(tmp, path)!
	return sha256.hexhash(updated)
}

pub fn brave_web_search(query string, api_key string, max_bytes int) !string {
	if api_key == '' { return error('BRAVE_API_KEY is not configured') }
	url := 'https://api.search.brave.com/res/v1/web/search?q=${query.replace(' ', '%20')}'
	mut request := http.new_request(.get, url, '')
	request.add_custom_header('X-Subscription-Token', api_key)!
	response := request.do()!
	if response.status_code < 200 || response.status_code >= 300 {
		return error('Brave returned HTTP ${response.status_code}')
	}
	limit := if max_bytes > 0 { max_bytes } else { 256 * 1024 }
	return if response.body.len > limit { response.body[..limit] } else { response.body }
}
